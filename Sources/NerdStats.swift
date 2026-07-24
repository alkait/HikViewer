// NerdStats.swift — per-stream diagnostics ("I" to toggle): a draggable
// panel showing stream, network, smoothing-buffer, and system stats for the
// selected grid tile or the focused camera.
//
// Collection is always-on but costs only a few counter updates per frame on
// the stream's own queue (no locks on the video path beyond one uncontended
// unfair lock). All aggregation, system probes, and text layout run only
// while the panel is visible, twice a second.

import AppKit
import CoreMedia
import CoreWLAN
import Darwin
import VideoToolbox

/// One time base for every stat: host-clock seconds, matching the parser's
/// frame timestamps (CFAbsoluteTime has a different epoch — don't mix).
func statsNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

// MARK: - per-stream collector

/// Counters and recent samples for one stream. Writers (parser / pipe reader)
/// call the note* methods from the stream queue; the panel takes a snapshot
/// from the main thread. One unfair lock guards everything — held for
/// nanoseconds per frame.
final class StreamStats {
    struct Sample {
        let t: Double          // arrival, host-clock seconds
        let gap: Double        // seconds since previous frame (0 for first)
        let lead: Double       // scheduled headroom; -1 = smoothing off
        let late: Bool
    }

    struct Snapshot {
        var width: Int32 = 0, height: Int32 = 0
        var startTime = 0.0
        var framesTotal = 0
        var bytesTotal: Int64 = 0
        var lateTotal = 0
        var reanchorsDrained = 0
        var reanchorsOverfull = 0
        var stalls = 0
        var reconnects = 0
        var lastReconnectAt: Double?
        var gopFrames = 0
        var iSize = 0.0, pSize = 0.0     // EWMA bytes
        var samples: [Sample] = []       // oldest → newest
        var pid: pid_t?
        var reanchorsTotal: Int { reanchorsDrained + reanchorsOverfull }
    }

    private var lock = os_unfair_lock_s()
    private var snap = Snapshot()
    private var ring = [Sample]()
    private var ringHead = 0
    private let ringCap = 512
    private var framesSinceKey = 0

    init() {
        snap.startTime = statsNow()
        ring.reserveCapacity(ringCap)
    }

    var pid: pid_t? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return snap.pid
    }

    func setPid(_ p: pid_t?) {
        os_unfair_lock_lock(&lock); snap.pid = p; os_unfair_lock_unlock(&lock)
    }

    func noteBytes(_ n: Int) {
        os_unfair_lock_lock(&lock); snap.bytesTotal += Int64(n); os_unfair_lock_unlock(&lock)
    }

    func noteFormat(width: Int32, height: Int32) {
        os_unfair_lock_lock(&lock)
        snap.width = width; snap.height = height
        os_unfair_lock_unlock(&lock)
    }

    func noteFrame(t: Double, gap: Double, lead: Double, late: Bool, size: Int, isKey: Bool) {
        os_unfair_lock_lock(&lock)
        snap.framesTotal += 1
        if late { snap.lateTotal += 1 }
        if isKey {
            if framesSinceKey > 0 { snap.gopFrames = framesSinceKey }
            framesSinceKey = 0
            snap.iSize = snap.iSize == 0 ? Double(size) : snap.iSize * 0.8 + Double(size) * 0.2
        } else {
            snap.pSize = snap.pSize == 0 ? Double(size) : snap.pSize * 0.95 + Double(size) * 0.05
        }
        framesSinceKey += 1
        let s = Sample(t: t, gap: min(gap, 2.0), lead: lead, late: late)
        if ring.count < ringCap { ring.append(s) }
        else { ring[ringHead] = s; ringHead = (ringHead + 1) % ringCap }
        os_unfair_lock_unlock(&lock)
    }

    func noteReanchor(drained: Bool) {
        os_unfair_lock_lock(&lock)
        if drained { snap.reanchorsDrained += 1 } else { snap.reanchorsOverfull += 1 }
        os_unfair_lock_unlock(&lock)
    }

    func noteStall() {
        os_unfair_lock_lock(&lock); snap.stalls += 1; os_unfair_lock_unlock(&lock)
    }

    func noteReconnect() {
        os_unfair_lock_lock(&lock)
        snap.reconnects += 1
        snap.lastReconnectAt = statsNow()
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var out = snap
        out.samples = ring.count < ringCap
            ? ring
            : Array(ring[ringHead...] + ring[..<ringHead])
        return out
    }
}

// MARK: - system probes (panel-open only, except the cached decode caps)

enum SystemProbes {
    /// Machine capability per codec, queried once — the "can this Mac decode
    /// this in silicon" fact that separates the M2 from a 2015 Intel.
    static let hwHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    static let hwH264 = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)

    private static let machTimebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Seconds of CPU time this pid has consumed (user + system).
    static func cpuSeconds(pid: pid_t) -> Double? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard ok == 0 else { return nil }
        return Double(info.ri_user_time &+ info.ri_system_time) * machTimebase / 1e9
    }

    struct WiFi { var rssi = 0; var rate = 0.0; var channel = 0; var widthMHz = 0 }

    /// nil when not associated to Wi-Fi (wired / Wi-Fi off).
    static func wifi() -> WiFi? {
        guard let i = CWWiFiClient.shared().interface(), i.rssiValue() != 0 else { return nil }
        var w = WiFi()
        w.rssi = i.rssiValue()
        w.rate = i.transmitRate()
        if let ch = i.wlanChannel() {
            w.channel = ch.channelNumber
            switch ch.channelWidth {
            case .width20MHz: w.widthMHz = 20
            case .width40MHz: w.widthMHz = 40
            case .width80MHz: w.widthMHz = 80
            case .width160MHz: w.widthMHz = 160
            default: w.widthMHz = 0
            }
        }
        return w
    }
}

// MARK: - the panel

final class NerdStatsPanel: NSView {
    /// Resolved every tick: the camera + stream whose stats to show
    /// (selected grid tile, or the focused camera's active live stream).
    var targetProvider: () -> (camera: Camera, stream: CameraStream)? = { nil }
    /// All live ffmpeg pids (grid substreams + focused main stream).
    var pidsProvider: () -> [pid_t] = { [] }

    private var timer: Timer?
    private let titleField = NSTextField(labelWithString: "NERD STATS")
    private var values: [String: NSTextField] = [:]
    private var rows: [String: NSView] = [:]

    private let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private let cWhite = NSColor.white.withAlphaComponent(0.94)
    private let cDim = NSColor.white.withAlphaComponent(0.55)
    private let cAmber = NSColor(calibratedRed: 1.0, green: 0.70, blue: 0.25, alpha: 1)
    private let cRed = NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.32, alpha: 1)

    // Windowed rates come from diffing snapshots of monotonic totals; reset
    // when the panel is retargeted to another stream.
    private struct Tick {
        let t: Double
        let bytes: Int64
        let frames: Int
        let late: Int
        let reanchors: Int
        let appCPU: Double
        let ffCPU: Double
    }
    private var history: [Tick] = []
    private var historyOf: ObjectIdentifier?
    private var peakFps = 0.0
    private var wifiCache: SystemProbes.WiFi?
    private var wifiIsStale = true
    private var lastCopyText = ""

    private var dragOffset = NSPoint.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.66).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor

        titleField.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        titleField.textColor = cDim
        titleField.lineBreakMode = .byTruncatingTail

        let copy = NSButton(title: "", target: self, action: #selector(copyStats))
        copy.isBordered = false
        copy.attributedTitle = NSAttributedString(string: "⧉ copy", attributes: [
            .foregroundColor: cDim, .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
        ])
        copy.toolTip = "Copy a plain-text snapshot of every stat (with extra detail) — for notes or bug reports."
        copy.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [titleField, copy])
        header.spacing = 6

        var views: [NSView] = [header]
        func addRow(_ id: String, _ key: String, _ tip: String) {
            let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle",
                                                  accessibilityDescription: "about \(key)") ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            icon.contentTintColor = cDim
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let k = NSTextField(labelWithString: key)
            k.font = mono
            k.textColor = cDim
            k.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let v = NSTextField(labelWithString: "—")
            v.font = mono
            v.textColor = cWhite
            v.lineBreakMode = .byTruncatingTail
            let row = NSStackView(views: [icon, k, v])
            row.spacing = 5
            row.toolTip = tip
            icon.toolTip = tip
            values[id] = v
            rows[id] = row
            views.append(row)
        }
        func addRule() {
            let box = NSBox()
            box.boxType = .separator
            views.append(box)
        }

        addRow("stream", "stream", """
            What you're receiving and how it travels: codec, frame size, RTSP channel \
            (101 = main stream, 102 = grid substream), transported over TCP through an \
            ffmpeg pipe. Confirms which stream is actually on screen — the focused view \
            should show the main stream's full resolution.
            """)
        addRow("decode", "decode", """
            Whether this Mac has dedicated silicon for each codec. "software" means the \
            CPU does the decompression — heavy for high-resolution HEVC and the usual \
            cause of stutter on pre-2017 Intel Macs. If the stream's own codec shows \
            software here, expect high CPU below; consider H.264 or the substream on \
            this machine.
            """)
        addRule()
        addRow("fps", "fps", """
            Frames actually arriving per second — not the camera's configured rate. \
            Steady fps with a stuttery picture → look at jitter and decode. Sagging \
            fps → the network or camera isn't delivering. Cameras also lower fps at \
            night on purpose (longer exposure), so a gentle dip after dark is normal.
            """)
        addRow("bitrate", "bitrate", """
            Data rate now (and the session average). Compare with your link: a few \
            Mbps is trivial for healthy Wi-Fi. Watch it surge when the scene moves — \
            those surges are what stress a weak link and line up with jitter spikes.
            """)
        addRow("gop", "GOP", """
            The camera sends a complete picture (keyframe, "I") only periodically; \
            everything between is differences ("P"). Shown: that cycle in frames and \
            seconds, plus typical I and P sizes. Keyframes are big bursts — if hiccups \
            repeat at this period, the bursts are beating your link. Also the \
            worst-case wait for video after a reconnect.
            """)
        addRule()
        addRow("jitter", "jitter", """
            How unevenly frames arrive (last 10 s). σ is the typical wobble — a few ms \
            on Ethernet, 10–30 on healthy Wi-Fi. max is the single worst gap: if it \
            exceeds the smoothing buffer (200 ms), that spike was visible. High σ = \
            constant congestion; low σ with occasional huge max = intermittent \
            interference (microwave, channel switch).
            """)
        addRow("stalls", "stalls", """
            Times this stream died outright and was restarted: stalls are sessions \
            that went silent (caught by the 12 s watchdog); reconnects count every \
            restart. One camera reconnecting alone → that camera, its cable, or PoE \
            port. All cameras together → shared network. A different disease than \
            jitter — no buffer absorbs a stall.
            """)
        addRule()
        addRow("buffer", "buffer", """
            Health of the smoothing buffer: how far ahead the next frame is scheduled \
            versus the 200 ms target, with the lowest value of the last 10 s. Steady \
            near target = coasting. Dips that recover = spikes being absorbed (the \
            feature working). Repeatedly scraping zero = delivery spikes nearly beat \
            the buffer — raise it or fix the link.
            """)
        addRow("reanchors", "re-anchors", """
            Moments smoothing gave up and restarted its schedule — each is one brief \
            visible hiccup. "Drained" = a delivery gap outlasted the whole buffer \
            (network's fault); "overfull" = the schedule drifted ahead (estimator's \
            fault). Zero means every spike was absorbed. The copy button includes the \
            drained/overfull split.
            """)
        addRow("late", "late", """
            Share of frames arriving with almost no headroom (<30 ms) before their \
            display slot — near-misses. A rising late % is the early warning that the \
            buffer is being squeezed, visible before re-anchors appear. On \
            software-decode machines it also rises when the CPU can't decode in time.
            """)
        addRule()
        addRow("cpu", "cpu", """
            Processor cost of viewing, in % of one core: the app (parsing, scheduling, \
            rendering, and decode when it's software) plus all its ffmpeg helpers \
            (network + demux — they stream-copy, so they should be nearly idle; a busy \
            ffmpeg is itself a red flag). High app CPU alongside "software" decode \
            above is the expected price of no hardware decoder.
            """)
        addRow("wifi", "wifi", """
            The radio under this stream: signal (−50 great, −70 marginal, −80 \
            desperate), the currently negotiated link rate, and the channel. If jitter \
            spikes line up with rate drops or RSSI sags here, the radio is the cause — \
            weak signal means distance/walls; strong signal with an unstable rate \
            means interference or congestion. Shows "no Wi-Fi" when wired.
            """)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 9, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 336),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])
        for r in rows.values {
            r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Add to `container`, restore the remembered position, start ticking.
    func place(in container: NSView) {
        layoutSubtreeIfNeeded()
        setFrameSize(fittingSize)
        let d = UserDefaults.standard
        let left = d.object(forKey: "nerdStatsLeft") as? CGFloat ?? 10
        let top = d.object(forKey: "nerdStatsTop") as? CGFloat ?? 40
        setFrameOrigin(NSPoint(x: left, y: container.bounds.height - top - frame.height))
        clampIntoSuperview()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        removeFromSuperview()
    }

    // MARK: dragging

    override func mouseDown(with event: NSEvent) {
        dragOffset = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sup = superview else { return }
        let p = sup.convert(event.locationInWindow, from: nil)
        setFrameOrigin(NSPoint(x: p.x - dragOffset.x, y: p.y - dragOffset.y))
        clampIntoSuperview()
    }

    override func mouseUp(with event: NSEvent) {
        guard let sup = superview else { return }
        let d = UserDefaults.standard
        d.set(frame.minX, forKey: "nerdStatsLeft")
        d.set(sup.bounds.height - frame.maxY, forKey: "nerdStatsTop")
    }

    private func clampIntoSuperview() {
        guard let sup = superview, sup.bounds.width > 0 else { return }
        var o = frame.origin
        o.x = max(0, min(sup.bounds.width - frame.width, o.x))
        o.y = max(0, min(sup.bounds.height - frame.height, o.y))
        if o != frame.origin { setFrameOrigin(o) }
    }

    // MARK: refresh

    private struct Seg { let text: String; let color: NSColor }

    private func set(_ id: String, _ segs: [Seg]) {
        guard let f = values[id] else { return }
        let s = NSMutableAttributedString()
        for seg in segs {
            s.append(NSAttributedString(string: seg.text,
                                        attributes: [.font: mono, .foregroundColor: seg.color]))
        }
        if s.string != f.attributedStringValue.string { f.attributedStringValue = s }
    }

    private func tick() {
        clampIntoSuperview()
        guard let target = targetProvider() else {
            titleField.stringValue = "NERD STATS"
            for id in values.keys { set(id, [Seg(text: "—", color: cDim)]) }
            return
        }
        let cam = target.camera
        let stream = target.stream
        let s = stream.stats.snapshot()
        let now = statsNow()

        if historyOf != ObjectIdentifier(stream.stats) {
            historyOf = ObjectIdentifier(stream.stats)
            history = []
            peakFps = 0
        }

        // System probes: CPU every tick (cheap syscalls), Wi-Fi every other
        // tick off-main (CoreWLAN does IPC).
        let appCPU = SystemProbes.cpuSeconds(pid: getpid()) ?? 0
        let ffCPU = pidsProvider().compactMap { SystemProbes.cpuSeconds(pid: $0) }.reduce(0, +)
        wifiIsStale.toggle()
        if wifiIsStale {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let w = SystemProbes.wifi()
                DispatchQueue.main.async { self?.wifiCache = w }
            }
        }

        history.append(Tick(t: now, bytes: s.bytesTotal, frames: s.framesTotal,
                            late: s.lateTotal, reanchors: s.reanchorsTotal,
                            appCPU: appCPU, ffCPU: ffCPU))
        if history.count > 150 { history.removeFirst(history.count - 150) }
        // Newest tick at least `seconds` old; short history falls back to the
        // oldest (windows then mean "since the panel opened").
        func tickBefore(_ seconds: Double) -> Tick? {
            guard let first = history.first else { return nil }
            return history.last { $0.t <= now - seconds } ?? first
        }

        titleField.stringValue = "NERD STATS — \(cam.name)"

        // stream
        if s.width > 0 {
            set("stream", [Seg(text: "\(cam.codec.display) \(s.width)×\(s.height)", color: cWhite),
                           Seg(text: " · ch \(stream.channelId) · TCP · ffmpeg", color: cDim)])
        } else {
            set("stream", [Seg(text: "\(cam.codec.display) ", color: cWhite),
                           Seg(text: "awaiting stream · ch \(stream.channelId)", color: cDim)])
        }

        // decode
        let hevcHW = SystemProbes.hwHEVC, h264HW = SystemProbes.hwH264
        var decodeSegs: [Seg] = []
        let hevcBad = !hevcHW && cam.codec == .hevc
        decodeSegs.append(Seg(text: "HEVC: \(hevcHW ? "hardware" : "software")\(hevcBad ? " ⚠" : "")",
                              color: hevcBad ? cAmber : (cam.codec == .hevc ? cWhite : cDim)))
        let h264Bad = !h264HW && cam.codec == .h264
        decodeSegs.append(Seg(text: " · H.264: \(h264HW ? "hardware" : "software")\(h264Bad ? " ⚠" : "")",
                              color: h264Bad ? cAmber : (cam.codec == .h264 ? cWhite : cDim)))
        set("decode", decodeSegs)

        // fps (5 s window of samples)
        let recent = s.samples.filter { $0.t >= now - 5 }
        var fps = 0.0
        if recent.count >= 2, let first = recent.first, let last = recent.last, last.t > first.t {
            fps = Double(recent.count - 1) / (last.t - first.t)
        }
        peakFps = max(fps, peakFps * 0.995)
        if fps > 0 {
            let c: NSColor = fps < peakFps * 0.6 ? cRed : (fps < peakFps * 0.85 ? cAmber : cWhite)
            set("fps", [Seg(text: String(format: "%.1f", fps), color: c)])
        } else {
            set("fps", [Seg(text: "—", color: cDim)])
        }

        // bitrate (≈2 s window + session average)
        if let base = tickBefore(2), now > base.t, s.bytesTotal > base.bytes {
            let mbps = Double(s.bytesTotal - base.bytes) * 8 / (now - base.t) / 1e6
            let avg = Double(s.bytesTotal) * 8 / max(1, now - s.startTime) / 1e6
            set("bitrate", [Seg(text: String(format: "%.1f Mbps", mbps), color: cWhite),
                            Seg(text: String(format: " (avg %.1f)", avg), color: cDim)])
        } else {
            set("bitrate", [Seg(text: "—", color: cDim)])
        }

        // GOP
        if s.gopFrames > 0, fps > 0 {
            var segs = [Seg(text: String(format: "%d · %.1f s", s.gopFrames, Double(s.gopFrames) / fps), color: cWhite)]
            if s.iSize > 0, s.pSize > 0 {
                segs.append(Seg(text: String(format: " · I %.0f KB · P %.0f KB", s.iSize / 1024, s.pSize / 1024), color: cDim))
            }
            set("gop", segs)
        } else {
            set("gop", [Seg(text: "—", color: cDim)])
        }

        // jitter (10 s window)
        let gaps = s.samples.filter { $0.t >= now - 10 && $0.gap > 0 }.map { $0.gap }
        if gaps.count >= 5 {
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            let variance = gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)
            let sigma = variance.squareRoot() * 1000
            let maxGap = (gaps.max() ?? 0) * 1000
            let mc: NSColor = maxGap > 200 ? cRed : (maxGap > 150 ? cAmber : cWhite)
            set("jitter", [Seg(text: String(format: "σ %.0f ms · ", sigma), color: cWhite),
                           Seg(text: String(format: "max %.0f ms", maxGap), color: mc)])
        } else {
            set("jitter", [Seg(text: "—", color: cDim)])
        }

        // stalls / reconnects
        var stallSegs = [Seg(text: "\(s.stalls) stalls · \(s.reconnects) reconnects", color: cWhite)]
        if let last = s.lastReconnectAt {
            let ago = now - last
            let c: NSColor = ago < 60 ? cRed : (ago < 3600 ? cAmber : cDim)
            stallSegs.append(Seg(text: " · last \(agoString(ago))", color: c))
        }
        set("stalls", stallSegs)

        // smoothing trio
        let targetMs = VideoStreamParser.smoothingDelay * 1000
        let leads = s.samples.filter { $0.t >= now - 10 && $0.lead >= 0 }
        if !Settings.smoothLive {
            for id in ["buffer", "reanchors", "late"] {
                set(id, [Seg(text: "smoothing off", color: cDim)])
            }
        } else if let lastLead = leads.last {
            let minLead = (leads.map { $0.lead }.min() ?? 0) * 1000
            let minC: NSColor = minLead < 30 ? cRed : (minLead < 80 ? cAmber : cDim)
            set("buffer", [Seg(text: String(format: "%.0f / %.0f ms", lastLead.lead * 1000, targetMs), color: cWhite),
                           Seg(text: String(format: " · min %.0f", minLead), color: minC)])

            let base60 = tickBefore(60)
            let re60 = s.reanchorsTotal - (base60?.reanchors ?? 0)
            let rc: NSColor = re60 > 2 ? cRed : (re60 > 0 ? cAmber : cWhite)
            set("reanchors", [Seg(text: "\(re60)", color: rc),
                              Seg(text: " (60 s) · \(s.reanchorsTotal) total", color: cDim)])

            let dFrames = s.framesTotal - (base60?.frames ?? 0)
            let dLate = s.lateTotal - (base60?.late ?? 0)
            if dFrames > 0 {
                let pct = Double(dLate) / Double(dFrames) * 100
                let lc: NSColor = pct > 5 ? cRed : (pct > 2 ? cAmber : cWhite)
                set("late", [Seg(text: String(format: pct < 1 ? "%.1f%%" : "%.0f%%", pct), color: lc),
                             Seg(text: " (60 s)", color: cDim)])
            } else {
                set("late", [Seg(text: "—", color: cDim)])
            }
        } else {
            for id in ["buffer", "reanchors", "late"] {
                set(id, [Seg(text: "—", color: cDim)])
            }
        }

        // cpu (% of one core, over ~2 s)
        if let base = tickBefore(2), now > base.t {
            let dt = now - base.t
            let app = max(0, appCPU - base.appCPU) / dt * 100
            let ff = max(0, ffCPU - base.ffCPU) / dt * 100
            let capacity = Double(ProcessInfo.processInfo.activeProcessorCount) * 100
            let total = app + ff
            let c: NSColor = total > capacity * 0.6 ? cRed : (total > capacity * 0.25 ? cAmber : cWhite)
            set("cpu", [Seg(text: String(format: "%.0f%% app", app), color: c),
                        Seg(text: String(format: " · %.0f%% ffmpeg", ff), color: cDim)])
        } else {
            set("cpu", [Seg(text: "—", color: cDim)])
        }

        // wifi
        if let w = wifiCache {
            let c: NSColor = w.rssi < -78 ? cRed : (w.rssi < -70 ? cAmber : cWhite)
            var segs = [Seg(text: "\(w.rssi) dBm", color: c),
                        Seg(text: String(format: " · %.0f Mbps", w.rate), color: cWhite)]
            if w.channel > 0 {
                let width = w.widthMHz > 0 ? " (\(w.widthMHz) MHz)" : ""
                segs.append(Seg(text: " · ch \(w.channel)\(width)", color: cDim))
            }
            set("wifi", segs)
        } else {
            set("wifi", [Seg(text: "no Wi-Fi (wired?)", color: cDim)])
        }

        // clipboard snapshot with the extra detail the panel omits
        lastCopyText = """
        HikViewer nerd stats — \(cam.name) (\(cam.host)) — \(Date())
        stream: \(values["stream"]?.attributedStringValue.string ?? "")
        decode: \(values["decode"]?.attributedStringValue.string ?? "")
        fps: \(values["fps"]?.attributedStringValue.string ?? "")
        bitrate: \(values["bitrate"]?.attributedStringValue.string ?? "")
        GOP: \(values["gop"]?.attributedStringValue.string ?? "")
        jitter: \(values["jitter"]?.attributedStringValue.string ?? "")
        stalls: \(values["stalls"]?.attributedStringValue.string ?? "")
        buffer: \(values["buffer"]?.attributedStringValue.string ?? "")
        re-anchors: \(values["reanchors"]?.attributedStringValue.string ?? "") \
        (drained \(s.reanchorsDrained) · overfull \(s.reanchorsOverfull))
        late: \(values["late"]?.attributedStringValue.string ?? "")
        cpu: \(values["cpu"]?.attributedStringValue.string ?? "")
        wifi: \(values["wifi"]?.attributedStringValue.string ?? "")
        totals: \(s.framesTotal) frames · \(s.bytesTotal) bytes · \(s.lateTotal) late
        """
    }

    private func agoString(_ s: Double) -> String {
        if s < 60 { return String(format: "%.0f s ago", s) }
        if s < 3600 { return String(format: "%.0f m ago", s / 60) }
        return String(format: "%.1f h ago", s / 3600)
    }

    @objc private func copyStats() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastCopyText, forType: .string)
        HUDView.flash("Stats copied", in: superview ?? self)
    }
}
