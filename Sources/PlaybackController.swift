// PlaybackController.swift — recorded-footage playback for one focused tile.
//
// The NVR paces playback RTSP (at `speed`×, via the Scale header through
// ScaleProxy for >1×), so frames flow through the exact same ffmpeg -> parser
// -> display-layer pipeline as live. Everything time-shaped happens here:
// seek = kill the pipe, relaunch at the new starttime; pause = kill the pipe,
// keep the last frame; position = starttime + wall-clock-since-first-frame ×
// speed. All on the main thread.

import AppKit

final class PlaybackController {
    private let camera: Camera
    private let track: Int
    private let client: NVRClient
    private weak var tile: TileView?
    private let bar = PlaybackBarView()
    private let cal: Calendar
    private let dayFmt: DateFormatter
    private let monthFmt: DateFormatter
    private let clockFmt: DateFormatter

    private var stream: PlaybackStream?
    private var speed = Settings.playbackSpeed      // 1 / 2 / 4 ×, shared across cameras
    private var lastStart = Date.distantPast        // guards a fail-retry loop

    // Timeline zoom: preset windows into the day; resets to 24h per day.
    private static let zoomLevels: [(duration: TimeInterval, title: String)] =
        [(86400, "24h"), (21600, "6h"), (3600, "1h"), (600, "10m")]
    private var zoomIndex = 0
    private var winStart = Date()
    private var winDuration: TimeInterval { Self.zoomLevels[zoomIndex].duration }
    private var winEnd: Date { winStart.addingTimeInterval(winDuration) }
    private var dayEnd: Date { cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400) }
    private var segments: [RecordingSegment] = []   // for the displayed day
    private var day = Date()                        // start of the displayed day (NVR tz)
    private var requestedStart = Date()
    private var anchorTime: Date?                   // media time of the current pipe's first frame
    private var anchorWall: Date?
    private var pausedAt: Date?
    private var timer: Timer?

    /// Transport changes (position, speed, paused) — the supplementary panes
    /// re-align their own streams off this. Fired on every play/seek/pause.
    var onTransport: ((_ position: Date, _ speed: Int, _ paused: Bool) -> Void)?
    var currentPosition: Date { position() }
    var currentSpeed: Int { speed }
    var isPaused: Bool { pausedAt != nil }

    // Calendar popover state.
    private var calAnchor = Date()                  // first of the displayed month
    private var monthCache: [String: Set<Int>] = [:]

    // Motion highlights: neither toggle on = all motion (alarm log); either
    // on = only AcuSense-classified human/vehicle motion.
    private var humanFilter = false
    private var vehicleFilter = false
    private var motionSpans: [RecordingSegment] = []   // what the timeline shows
    private var motionToken = 0                     // drops stale async results
    private var channel: Int { track / 100 }

    init(camera: Camera, track: Int, client: NVRClient, tile: TileView) {
        self.camera = camera
        self.track = track
        self.client = client
        self.tile = tile
        var c = Calendar(identifier: .gregorian)
        c.timeZone = client.timeZone
        c.firstWeekday = 1                          // Sunday, matches the calendar header
        self.cal = c
        self.dayFmt = client.formatter("EEE yyyy-MM-dd")
        self.monthFmt = client.formatter("LLLL yyyy")
        self.clockFmt = client.formatter("h:mm:ss a")
    }

    func begin(at start: Date) {
        guard let tile else { return }
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.frame = NSRect(x: 0, y: 0, width: tile.bounds.width, height: 38)
        tile.addSubview(bar)
        bar.onSeek = { [weak self] t in self?.seek(to: t) }
        bar.onCalendarOpen = { [weak self] in self?.calendarOpened() }
        bar.onMonthStep = { [weak self] d in self?.stepMonth(d) }
        bar.onPickDay = { [weak self] d in self?.pickDay(d) }
        bar.onSpeedTap = { [weak self] in self?.cycleSpeed() }
        bar.onPlayPause = { [weak self] in self?.togglePause() }
        bar.onZoomTap = { [weak self] in
            guard let self else { return }
            self.setZoom((self.zoomIndex + 1) % Self.zoomLevels.count, center: self.position())
        }
        bar.onZoomStep = { [weak self] dir, center in
            guard let self else { return }
            self.setZoom(self.zoomIndex + dir, center: center)
        }
        bar.onPan = { [weak self] delta in self?.pan(delta) }
        bar.onHumanTap = { [weak self] in self?.toggleMotionFilter(human: true) }
        bar.onVehicleTap = { [weak self] in self?.toggleMotionFilter(human: false) }
        bar.setTimeZone(client.timeZone)
        bar.setSpeed("\(speed)×")
        tile.setFeed(.playback)

        // The motion filter is one global choice shared across cameras (like
        // speed); with nothing saved it defaults to both ON (human+vehicle).
        let savedFilter = UserDefaults.standard.stringArray(forKey: filterDefaultsKey) ?? ["human", "vehicle"]
        humanFilter = savedFilter.contains("human")
        vehicleFilter = savedFilter.contains("vehicle")
        bar.setMotionFilter(human: humanFilter, vehicle: vehicleFilter)

        day = cal.startOfDay(for: start)
        requestedStart = start
        resetZoom()
        bar.setDay(dayFmt.string(from: day))
        refreshBookmarks()
        bar.setLoading(true)
        fetchSegments { [weak self] in self?.startPlayback(at: start) }

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func exit() {
        timer?.invalidate()
        timer = nil
        stopStream()
        bar.removeFromSuperview()
    }

    func seek(to t: Date) {
        pausedAt = nil
        if cal.startOfDay(for: t) != day {
            day = cal.startOfDay(for: t)
            resetZoom()
            bar.setDay(dayFmt.string(from: day))
            refreshBookmarks()
            fetchSegments { [weak self] in self?.startPlayback(at: t) }
        } else {
            startPlayback(at: t)
        }
    }

    func step(_ seconds: TimeInterval) { seek(to: position().addingTimeInterval(seconds)) }

    /// YouTube-style digit jump: 0–9 → that tenth of the recorded span the
    /// user is *looking at* — the recordings clipped to the visible window.
    /// Zoomed out that's the whole day's footage; zoomed in, just that slice.
    func jumpToFraction(_ f: Double) {
        let visible = segments.filter { $0.end > winStart && $0.start < winEnd }
        guard let first = visible.first, let last = visible.last else { return }
        let lo = max(winStart, first.start)
        let hi = min(winEnd, last.end)
        seek(to: lo.addingTimeInterval(f * hi.timeIntervalSince(lo)))
    }

    func toggleCalendar() { bar.toggleCalendar() }

    /// Amber pins on the timeline: this camera's bookmarks within the
    /// displayed day. Called on day changes and after adding a bookmark.
    func refreshBookmarks() {
        let start = day, end = dayEnd
        bar.setBookmarks(BookmarkStore.all
            .filter { $0.host == camera.host && $0.time >= start && $0.time < end }
            .map { $0.time })
    }

    func togglePause() {
        if let p = pausedAt {
            seek(to: p)                 // resume (seek clears pausedAt)
        } else {
            let p = position()
            pausedAt = p                // freeze: last frame stays on the layer
            stopStream()
            bar.setLoading(false)
            onTransport?(p, speed, true)
        }
    }

    /// 1× → 2× → 4× → 1× (NVR fast playback via the Scale header).
    func cycleSpeed() {
        let speeds = [1, 2, 4]
        speed = speeds[((speeds.firstIndex(of: speed) ?? 0) + 1) % speeds.count]
        Settings.playbackSpeed = speed
        bar.setSpeed("\(speed)×")
        if pausedAt == nil { startPlayback(at: position()) }
    }

    // MARK: timeline zoom

    private func resetZoom() {
        zoomIndex = 0
        winStart = day
        applyWindow()
    }

    private func setZoom(_ index: Int, center: Date) {
        zoomIndex = max(0, min(Self.zoomLevels.count - 1, index))
        recenter(on: center)
    }

    private func recenter(on center: Date) {
        let maxStart = dayEnd.addingTimeInterval(-winDuration)
        winStart = min(max(day, center.addingTimeInterval(-winDuration / 2)), maxStart)
        applyWindow()
    }

    private func pan(_ delta: TimeInterval) {
        guard zoomIndex > 0 else { return }
        let maxStart = dayEnd.addingTimeInterval(-winDuration)
        winStart = min(max(day, winStart.addingTimeInterval(delta)), maxStart)
        applyWindow()
    }

    private func applyWindow() {
        bar.setWindow(start: winStart, duration: winDuration)
        bar.setZoomLabel(Self.zoomLevels[zoomIndex].title)
    }

    /// Where playback is right now, in recording time.
    private func position() -> Date {
        if let p = pausedAt { return p }
        if let t = anchorTime, let w = anchorWall {
            return t.addingTimeInterval(Date().timeIntervalSince(w) * Double(speed))
        }
        return requestedStart
    }

    private func startPlayback(at t: Date, retried: Bool = false) {
        stopStream()
        // Snap into the recordings: the segment containing t, or the next one.
        guard let seg = segments.first(where: { t < $0.end }) else {
            if !retried {
                // The cached segment list ends at fetch time — resuming past
                // the old live edge (e.g. after a long pause) needs a refresh.
                fetchSegments { [weak self] in self?.startPlayback(at: t, retried: true) }
                return
            }
            tile?.setStatus("no recording here")
            bar.setLoading(false)
            pausedAt = t                // park the cursor where they clicked
            onTransport?(t, speed, true)
            return
        }
        let start = max(t, seg.start)
        // A zoomed window follows the seek target if it landed off-screen.
        if zoomIndex > 0, start < winStart || start > winEnd {
            recenter(on: start)
        }
        requestedStart = start
        lastStart = Date()
        anchorTime = nil
        anchorWall = nil
        guard let tile else { return }
        tile.resyncFeed()               // drop frames until the new pipe's first keyframe
        bar.setLoading(true)

        let (path, startClock) = client.playbackRequest(track: track, from: start, to: seg.end)
        let s = PlaybackStream(host: client.nvr.host, port: client.nvr.rtspPort,
                               user: client.nvr.user, password: client.nvr.password,
                               path: path, startClock: startClock, scale: speed, codec: camera.codec)
        s.onSample = { [weak self, weak tile] sb, sync in
            DispatchQueue.main.async {
                if let self, self.stream === s, self.anchorWall == nil {
                    self.anchorTime = start
                    self.anchorWall = Date()
                    self.bar.setLoading(false)
                }
            }
            tile?.enqueue(sb, isSync: sync, from: .playback)
        }
        s.onState = { [weak tile] st in tile?.setStatus(st) }
        s.onEnded = { [weak self] in self?.streamEnded() }
        stream = s
        s.start()
        onTransport?(start, speed, false)
    }

    private func stopStream() {
        stream?.stop()
        stream = nil
    }

    /// The pipe EOF'd: the segment played out, or we caught up with "now".
    /// Re-search (recordings grow), then continue past the gap — or stay
    /// paused at the end of what exists.
    private func streamEnded() {
        guard pausedAt == nil else { return }
        // A pipe that died young without a single frame is a failure, not a
        // played-out segment — pause instead of retry-looping against it.
        if anchorWall == nil, Date().timeIntervalSince(lastStart) < 3 {
            pausedAt = position()
            bar.setLoading(false)
            onTransport?(pausedAt!, speed, true)
            return
        }
        let pos = position()
        pausedAt = pos
        let fetchedDay = day
        fetchSegments { [weak self] in
            guard let self, self.day == fetchedDay, self.pausedAt != nil else { return }
            if let next = self.segments.first(where: { $0.start > pos.addingTimeInterval(1) }) {
                self.seek(to: next.start)
            } else if let last = self.segments.last, last.end.timeIntervalSince(pos) > 10 {
                self.seek(to: pos)      // recording grew while we played — keep going
            } else {
                self.bar.setLoading(false)   // live edge / end of recorded video
                self.onTransport?(pos, self.speed, true)
            }
        }
    }

    private func fetchSegments(completion: (() -> Void)?) {
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: day) else { return }
        let fetchedDay = day
        client.searchSegments(track: track, from: day, to: dayEnd) { [weak self] segs in
            guard let self, self.day == fetchedDay else { return }
            self.segments = segs
            self.bar.setSegments(segs)
            if segs.isEmpty { self.tile?.setStatus("no recordings this day") }
            completion?()
        }
        refreshMotion()
    }

    // MARK: motion highlights

    private let filterDefaultsKey = "motionFilter"

    private func toggleMotionFilter(human: Bool) {
        if human { humanFilter.toggle() } else { vehicleFilter.toggle() }
        var saved: [String] = []
        if humanFilter { saved.append("human") }
        if vehicleFilter { saved.append("vehicle") }
        UserDefaults.standard.set(saved, forKey: filterDefaultsKey)
        bar.setMotionFilter(human: humanFilter, vehicle: vehicleFilter)
        setMotionSpans([])
        refreshMotion()
    }

    private func setMotionSpans(_ spans: [RecordingSegment]) {
        motionSpans = spans
        bar.setMotion(spans)
    }

    /// N: jump to the next motion block after the current position — within
    /// the displayed day only; at the day's last block it does nothing.
    func jumpToNextMotion() {
        let pos = position()
        guard let next = motionSpans.first(where: { $0.start > pos.addingTimeInterval(1) }) else { return }
        seek(to: next.start)
    }

    /// Shift-N: back to the previous motion block (same day-bounded rules).
    func jumpToPreviousMotion() {
        let pos = position()
        guard let prev = motionSpans.last(where: { $0.start < pos.addingTimeInterval(-1) }) else { return }
        seek(to: prev.start)
    }

    private func refreshMotion() {
        motionToken += 1
        let token = motionToken
        let from = day, to = dayEnd
        if humanFilter || vehicleFilter {
            var types: [String] = []
            if humanFilter { types.append("human") }
            if vehicleFilter { types.append("vehicle") }
            var union: [RecordingSegment] = []
            var pending = types.count
            for type in types {
                client.classifiedSpans(channel: channel, from: from, to: to, type: type) { [weak self] spans in
                    guard let self, self.motionToken == token else { return }
                    union += spans
                    pending -= 1
                    if pending == 0 { self.setMotionSpans(NVRClient.merge(union)) }
                }
            }
        } else {
            client.motionLog(from: from, to: to) { [weak self] map in
                guard let self, self.motionToken == token else { return }
                self.setMotionSpans(map[self.channel] ?? [])
            }
        }
    }

    private func tick() {
        let pos = position()
        // A zoomed window slides forward to keep the playing cursor in view.
        if pausedAt == nil, zoomIndex > 0, pos > winStart.addingTimeInterval(winDuration * 0.9),
           pos < dayEnd {
            let maxStart = dayEnd.addingTimeInterval(-winDuration)
            winStart = min(max(day, pos.addingTimeInterval(-winDuration * 0.1)), maxStart)
            applyWindow()
        }
        let inDay = pos >= day && pos.timeIntervalSince(day) < 86400
        bar.setCursor(inDay ? pos : nil, paused: pausedAt != nil, label: clockFmt.string(from: pos))
    }

    // MARK: calendar (recorded days per month via dailyDistribution)

    private func calendarOpened() {
        calAnchor = firstOfMonth(day)
        pushMonth()
    }

    private func stepMonth(_ delta: Int) {
        guard let d = cal.date(byAdding: .month, value: delta, to: calAnchor) else { return }
        calAnchor = d
        pushMonth()
    }

    private func pickDay(_ dayOfMonth: Int) {
        guard let date = cal.date(byAdding: .day, value: dayOfMonth - 1, to: calAnchor) else { return }
        seek(to: date)                  // start of that day, snaps into its first recording
    }

    private func firstOfMonth(_ d: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
    }

    private func pushMonth() {
        let comps = cal.dateComponents([.year, .month], from: calAnchor)
        guard let year = comps.year, let month = comps.month else { return }
        let key = "\(year)-\(month)"
        updateCalendarUI(recorded: monthCache[key] ?? [])
        guard monthCache[key] == nil else { return }
        client.recordedDays(track: track, year: year, month: month) { [weak self] days in
            guard let self else { return }
            self.monthCache[key] = days
            let cur = self.cal.dateComponents([.year, .month], from: self.calAnchor)
            if cur.year == year, cur.month == month { self.updateCalendarUI(recorded: days) }
        }
    }

    private func updateCalendarUI(recorded: Set<Int>) {
        guard let range = cal.range(of: .day, in: .month, for: calAnchor) else { return }
        let daysInMonth = range.count
        let leading = (cal.component(.weekday, from: calAnchor) - cal.firstWeekday + 7) % 7
        // Future days can't have recordings even if the NVR claims otherwise.
        var enabled = recorded
        let today = cal.startOfDay(for: Date())
        for d in enabled where (cal.date(byAdding: .day, value: d - 1, to: calAnchor) ?? .distantFuture) > today {
            enabled.remove(d)
        }
        let sameMonth = cal.isDate(day, equalTo: calAnchor, toGranularity: .month)
        bar.updateCalendar(monthTitle: monthFmt.string(from: calAnchor),
                           leadingBlanks: leading, daysInMonth: daysInMonth,
                           enabled: enabled,
                           selected: sameMonth ? cal.component(.day, from: day) : nil)
    }
}
