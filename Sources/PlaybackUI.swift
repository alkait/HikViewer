// PlaybackUI.swift — the playback bar overlaid on a focused tile: a calendar
// popover (recorded days only), a 24-hour timeline of recorded segments, a
// loading spinner, the time readout, and the speed button.

import AppKit

/// Zoomable timeline strip: shows a window [winStart, winStart+winDuration]
/// of the day — the full 24 h by default. Time labels along the top, recorded
/// segments as a teal band, a red "now" marker, and a white cursor for the
/// playback position. Tick/label density adapts to the zoom level, and lines
/// are drawn light over the dark background and dark over the teal band so
/// they read everywhere. Click or drag anywhere to seek (fires on mouse-up so
/// scrubbing doesn't restart the pipe per pixel); scroll or pinch to zoom
/// through the presets, two-finger horizontal scroll to pan when zoomed.
final class TimelineStrip: NSView {
    var winStart = Date() { didSet { needsDisplay = true } }
    var winDuration: TimeInterval = 86400 { didSet { needsDisplay = true } }
    var timeZone = TimeZone.current {
        didSet {
            hourFmt.timeZone = timeZone
            minuteFmt.timeZone = timeZone
            needsDisplay = true
        }
    }
    var segments: [RecordingSegment] = [] { didSet { needsDisplay = true } }
    var motion: [RecordingSegment] = [] { didSet { needsDisplay = true } }
    var cursor: Date? { didSet { needsDisplay = true } }
    var onSeek: ((Date) -> Void)?

    static let motionColor = NSColor(calibratedRed: 0.92, green: 0.2, blue: 0.19, alpha: 1)
    var onZoomStep: ((Int, Date) -> Void)?   // +1 zoom in / -1 out, centered on a date
    var onPan: ((TimeInterval) -> Void)?     // seconds to shift the window

    private let hourFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "ha"                  // "3AM"
        return f
    }()
    private let minuteFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm"                // "8:10" — am/pm is on the clock readout
        return f
    }()
    private var scrollAcc: CGFloat = 0
    private var magnifyAcc: CGFloat = 0

    private func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(winStart) / winDuration) * bounds.width
    }

    private func date(at p: NSPoint) -> Date {
        let frac = min(max(p.x / max(1, bounds.width), 0), 1)
        return winStart.addingTimeInterval(TimeInterval(frac) * winDuration)
    }

    /// Tick spacing, label spacing, and label style per zoom level.
    private func tickPlan() -> (tick: Int, label: Int, fmt: DateFormatter) {
        if winDuration >= 86000 { return (3600, 10800, hourFmt) }   // 24h: 1h / 3h
        if winDuration >= 21000 { return (1800, 3600, hourFmt) }    // 6h: 30m / 1h
        if winDuration >= 3500 { return (300, 600, minuteFmt) }     // 1h: 5m / 10m
        return (60, 120, minuteFmt)                                 // 10m: 1m / 2m
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()

        let labelH: CGFloat = 12                    // labels above, band below
        let bandTop = bounds.height - labelH
        let bandY: CGFloat = 2
        let bandH = bandTop - 3
        let winEnd = winStart.addingTimeInterval(winDuration)

        // Recorded segments (same teal as the app icon).
        var segRects: [NSRect] = []
        NSColor(calibratedRed: 0.16, green: 0.74, blue: 0.80, alpha: 1).setFill()
        for s in segments {
            let x0 = max(0, x(for: s.start)), x1 = min(bounds.width, x(for: s.end))
            guard x1 > 0, x0 < bounds.width else { continue }
            let r = NSRect(x: x0, y: bandY, width: max(1, x1 - x0), height: bandH)
            segRects.append(r)
            r.fill()
        }

        // Motion highlights (red) over the recorded band — generic motion or
        // the human/vehicle filtered set, whatever the bar's toggles selected.
        Self.motionColor.setFill()
        for m in motion {
            let x0 = max(0, x(for: m.start)), x1 = min(bounds.width, x(for: m.end))
            guard x1 > 0, x0 < bounds.width else { continue }
            NSRect(x: x0, y: bandY, width: max(1, x1 - x0), height: bandH).fill()
        }

        // Tick times aligned to wall-clock boundaries in the NVR's timezone.
        let plan = tickPlan()
        let tzOff = TimeInterval(timeZone.secondsFromGMT(for: winStart))
        let startWall = Int((winStart.timeIntervalSince1970 + tzOff).rounded())
        let endWall = Int((winEnd.timeIntervalSince1970 + tzOff).rounded())
        let firstTick = (startWall + plan.tick - 1) / plan.tick * plan.tick
        var tickXs: [(x: CGFloat, isLabel: Bool, date: Date)] = []
        // `through` includes the window's end boundary — at 24h that puts
        // 12AM at both edges of the strip.
        for wall in stride(from: firstTick, through: endWall, by: plan.tick) {
            let date = Date(timeIntervalSince1970: TimeInterval(wall) - tzOff)
            tickXs.append((x(for: date), wall % plan.label == 0, date))
        }
        let interior = tickXs.filter { $0.x > 1 && $0.x < bounds.width - 1 }

        // Tick lines: light on the dark background…
        for t in interior {
            NSColor(white: 1, alpha: t.isLabel ? 0.38 : 0.18).setFill()
            NSRect(x: t.x - 0.5, y: bandY, width: 1, height: bandH).fill()
        }
        // …and re-drawn dark where they cross the teal band.
        if !segRects.isEmpty {
            NSGraphicsContext.current?.saveGraphicsState()
            let clip = NSBezierPath()
            segRects.forEach { clip.appendRect($0) }
            clip.addClip()
            for t in interior {
                NSColor(white: 0, alpha: t.isLabel ? 0.55 : 0.3).setFill()
                NSRect(x: t.x - 0.5, y: bandY, width: 1, height: bandH).fill()
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Labels on the labelled ticks; edge labels clamp inward instead of
        // vanishing, so the window's boundary times are always readable.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor(white: 0.9, alpha: 1),
        ]
        for t in tickXs where t.isLabel {
            let s = NSString(string: plan.fmt.string(from: t.date))
            let sz = s.size(withAttributes: attrs)
            let lx = min(max(t.x - sz.width / 2, 1), bounds.width - sz.width - 1)
            s.draw(at: NSPoint(x: lx, y: bounds.height - sz.height - 0.5), withAttributes: attrs)
        }

        // "Now" marker (red, like the icon's live dot) when it's in view.
        let now = Date()
        if now >= winStart, now < winEnd {
            NSColor(calibratedRed: 0.95, green: 0.27, blue: 0.25, alpha: 1).setFill()
            NSRect(x: x(for: now) - 0.75, y: bandY, width: 1.5, height: bandH).fill()
        }

        if let c = cursor, c >= winStart, c <= winEnd {
            NSColor.white.setFill()
            let cx = min(max(1, x(for: c)), bounds.width - 1)
            NSRect(x: cx - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        }
    }

    override func mouseDown(with e: NSEvent) { cursor = date(at: convert(e.locationInWindow, from: nil)) }
    override func mouseDragged(with e: NSEvent) { cursor = date(at: convert(e.locationInWindow, from: nil)) }
    override func mouseUp(with e: NSEvent) { onSeek?(date(at: convert(e.locationInWindow, from: nil))) }

    override func scrollWheel(with e: NSEvent) {
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if abs(dy) > abs(dx) {
            scrollAcc += dy
            if abs(scrollAcc) > 25 {
                let dir = scrollAcc > 0 ? 1 : -1     // scroll up = zoom in
                scrollAcc = 0
                onZoomStep?(dir, date(at: convert(e.locationInWindow, from: nil)))
            }
        } else if dx != 0 {
            onPan?(-TimeInterval(dx / max(1, bounds.width)) * winDuration)
        }
    }

    override func magnify(with e: NSEvent) {
        magnifyAcc += e.magnification
        if abs(magnifyAcc) > 0.15 {
            let dir = magnifyAcc > 0 ? 1 : -1
            magnifyAcc = 0
            onZoomStep?(dir, date(at: convert(e.locationInWindow, from: nil)))
        }
    }
}

/// Minimal month calendar for the popover: only days with recordings are
/// clickable, everything else (no recording / future) is dimmed.
final class MonthCalendarView: NSView {
    var onPickDay: ((Int) -> Void)?
    var onMonthStep: ((Int) -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let daysGrid = NSStackView()
    private static let cellW: CGFloat = 28, cellH: CGFloat = 22

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.alignment = .center
        title.setContentHuggingPriority(.init(1), for: .horizontal)

        let prev = NSButton(title: "◀", target: self, action: #selector(prevMonth))
        let next = NSButton(title: "▶", target: self, action: #selector(nextMonth))
        for b in [prev, next] { b.isBordered = false; b.font = .systemFont(ofSize: 11) }
        let header = NSStackView(views: [prev, title, next])
        header.spacing = 4

        let weekdays = NSStackView(views: "SMTWTFS".map { ch in
            let l = NSTextField(labelWithString: String(ch))
            l.font = .systemFont(ofSize: 10, weight: .medium)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            l.widthAnchor.constraint(equalToConstant: Self.cellW).isActive = true
            return l
        })
        weekdays.spacing = 2

        daysGrid.orientation = .vertical
        daysGrid.alignment = .leading
        daysGrid.spacing = 2

        let root = NSStackView(views: [header, weekdays, daysGrid])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show(monthTitle: String, leadingBlanks: Int, daysInMonth: Int, enabled: Set<Int>, selected: Int?) {
        title.stringValue = monthTitle
        daysGrid.arrangedSubviews.forEach { daysGrid.removeArrangedSubview($0); $0.removeFromSuperview() }
        var day = 1 - leadingBlanks
        while day <= daysInMonth {
            let row = NSStackView()
            row.spacing = 2
            for _ in 0..<7 {
                row.addArrangedSubview(cell(day, daysInMonth: daysInMonth, enabled: enabled, selected: selected))
                day += 1
            }
            daysGrid.addArrangedSubview(row)
        }
    }

    private func cell(_ day: Int, daysInMonth: Int, enabled: Set<Int>, selected: Int?) -> NSView {
        let size = { (v: NSView) in
            v.widthAnchor.constraint(equalToConstant: Self.cellW).isActive = true
            v.heightAnchor.constraint(equalToConstant: Self.cellH).isActive = true
        }
        guard day >= 1, day <= daysInMonth else {
            let v = NSView(); size(v); return v
        }
        let b = NSButton(title: "", target: self, action: #selector(pick(_:)))
        b.tag = day
        b.isBordered = false
        b.wantsLayer = true
        size(b)
        let isOn = enabled.contains(day)
        b.isEnabled = isOn
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        b.attributedTitle = NSAttributedString(string: "\(day)", attributes: [
            .foregroundColor: isOn ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: day == selected ? .bold : .medium),
            .paragraphStyle: para,
        ])
        // Recorded days get a teal chip so they're obvious at a glance; the
        // selected day a stronger one.
        if isOn {
            let teal = NSColor(calibratedRed: 0.16, green: 0.74, blue: 0.80, alpha: 1)
            b.layer?.backgroundColor = teal.withAlphaComponent(day == selected ? 0.55 : 0.22).cgColor
            b.layer?.cornerRadius = 5
            if day == selected {
                b.layer?.borderColor = teal.cgColor
                b.layer?.borderWidth = 1.5
            }
        }
        return b
    }

    @objc private func pick(_ sender: NSButton) { onPickDay?(sender.tag) }
    @objc private func prevMonth() { onMonthStep?(-1) }
    @objc private func nextMonth() { onMonthStep?(1) }
}

final class PlaybackBarView: NSView {
    var onSeek: ((Date) -> Void)? {
        get { strip.onSeek }
        set { strip.onSeek = newValue }
    }
    /// Popover is about to open — push fresh month data via updateCalendar.
    var onCalendarOpen: (() -> Void)?
    var onMonthStep: ((Int) -> Void)? {
        get { calendar.onMonthStep }
        set { calendar.onMonthStep = newValue }
    }
    var onPickDay: ((Int) -> Void)?
    var onSpeedTap: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onZoomTap: (() -> Void)?
    var onHumanTap: (() -> Void)?
    var onVehicleTap: (() -> Void)?
    var onZoomStep: ((Int, Date) -> Void)? {
        get { strip.onZoomStep }
        set { strip.onZoomStep = newValue }
    }
    var onPan: ((TimeInterval) -> Void)? {
        get { strip.onPan }
        set { strip.onPan = newValue }
    }

    private let strip = TimelineStrip()
    private let calendar = MonthCalendarView()
    private let popover = NSPopover()
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let dateButton = NSButton(title: "", target: nil, action: nil)
    private let zoomButton = NSButton(title: "", target: nil, action: nil)
    private let speedButton = NSButton(title: "", target: nil, action: nil)
    private let humanButton = NSButton(title: "", target: nil, action: nil)
    private let vehicleButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var showsPaused = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor

        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(playPauseTapped)
        playButton.contentTintColor = .white
        playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")

        dateButton.isBordered = false
        dateButton.target = self
        dateButton.action = #selector(showCalendar)

        speedButton.isBordered = false
        speedButton.target = self
        speedButton.action = #selector(speedTapped)
        setSpeed("1×")

        zoomButton.isBordered = false
        zoomButton.target = self
        zoomButton.action = #selector(zoomTapped)
        setZoomLabel("24h")

        // Motion-filter toggles, mirroring the NVR's Human/Vehicle checkboxes:
        // neither on = all motion; either/both on = only classified motion.
        humanButton.isBordered = false
        humanButton.target = self
        humanButton.action = #selector(humanTapped)
        humanButton.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "Human motion")
        vehicleButton.isBordered = false
        vehicleButton.target = self
        vehicleButton.action = #selector(vehicleTapped)
        vehicleButton.image = NSImage(systemSymbolName: "car.fill", accessibilityDescription: "Vehicle motion")
        setMotionFilter(human: false, vehicle: false)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.appearance = NSAppearance(named: .darkAqua)   // white spinner on the dark bar

        let vc = NSViewController()
        vc.view = calendar
        popover.contentViewController = vc
        popover.behavior = .transient
        calendar.onPickDay = { [weak self] d in
            self?.popover.performClose(nil)
            self?.onPickDay?(d)
        }

        let stack = NSStackView(views: [playButton, dateButton, strip, humanButton, vehicleButton,
                                        spinner, timeLabel, zoomButton, speedButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        strip.setContentHuggingPriority(.init(1), for: .horizontal)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setDay(_ label: String) {
        dateButton.attributedTitle = Self.barTitle(label + "  ▾")
    }

    func setSpeed(_ label: String) {
        speedButton.attributedTitle = Self.barTitle(label)
    }

    func setZoomLabel(_ label: String) {
        zoomButton.attributedTitle = Self.barTitle(label)
    }

    func setTimeZone(_ tz: TimeZone) { strip.timeZone = tz }

    func setWindow(start: Date, duration: TimeInterval) {
        strip.winStart = start
        strip.winDuration = duration
    }

    func setSegments(_ segments: [RecordingSegment]) {
        strip.segments = segments
    }

    func setMotion(_ spans: [RecordingSegment]) {
        strip.motion = spans
    }

    func setMotionFilter(human: Bool, vehicle: Bool) {
        humanButton.contentTintColor = human ? TimelineStrip.motionColor : NSColor(white: 1, alpha: 0.35)
        vehicleButton.contentTintColor = vehicle ? TimelineStrip.motionColor : NSColor(white: 1, alpha: 0.35)
    }

    func setCursor(_ date: Date?, paused: Bool, label: String) {
        strip.cursor = date
        timeLabel.stringValue = (paused ? "⏸ " : "") + label
        if paused != showsPaused {
            showsPaused = paused
            playButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                       accessibilityDescription: paused ? "Play" : "Pause")
        }
    }

    /// Loading feedback while a seek/pipe spins up — lives in the bar, no
    /// overlay on the video.
    func setLoading(_ loading: Bool) {
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func updateCalendar(monthTitle: String, leadingBlanks: Int, daysInMonth: Int,
                        enabled: Set<Int>, selected: Int?) {
        calendar.show(monthTitle: monthTitle, leadingBlanks: leadingBlanks,
                      daysInMonth: daysInMonth, enabled: enabled, selected: selected)
    }

    @objc private func showCalendar() {
        onCalendarOpen?()
        popover.show(relativeTo: dateButton.bounds, of: dateButton, preferredEdge: .maxY)
    }

    /// Keyboard shortcut entry: open the calendar, or close it if it's up.
    func toggleCalendar() {
        if popover.isShown { popover.performClose(nil) } else { showCalendar() }
    }

    @objc private func speedTapped() { onSpeedTap?() }

    @objc private func zoomTapped() { onZoomTap?() }

    @objc private func playPauseTapped() { onPlayPause?() }

    @objc private func humanTapped() { onHumanTap?() }

    @objc private func vehicleTapped() { onVehicleTap?() }

    private static func barTitle(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        ])
    }
}
