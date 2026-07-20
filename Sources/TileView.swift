// TileView.swift — one camera tile: hardware-decoded video + status overlay.

import AppKit
import AVFoundation
import CoreMedia

final class TileView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let label = NSTextField(labelWithString: "")
    private let title: String
    private var statusText = ""
    var onDoubleClick: (() -> Void)?

    private let placeholderLayer = CALayer()
    private let cachedBadge = NSTextField(labelWithString: "cached")
    private let recBadge = NSTextField(labelWithString: "")
    private var videoOnScreen = false  // main thread

    /// Fires after each layout pass — the supplementary manager rescales its
    /// floating panes off this.
    var onLayoutChange: (() -> Void)?
    /// Back to the view this one was promoted from (supplementary flow).
    var onBack: (() -> Void)?
    private let backButton = NSButton(title: "", target: nil, action: nil)

    // Long-press drag-to-reorder. onLongPress returns whether a drag actually
    // began (it doesn't while a tile is focused); drag events are only
    // forwarded after that.
    var onLongPress: (() -> Bool)?
    var onDrag: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private var pressTimer: DispatchWorkItem?
    private var pressStart = NSPoint.zero
    private var reordering = false

    // Digital zoom (focused view only — the app delegate arms it on focus).
    // Pure display-layer geometry: the layer is sized bounds×scale and offset,
    // so it costs nothing and works for live and playback alike.
    var zoomEnabled = false
    private(set) var zoomScale: CGFloat = 1        // 1…8
    private var zoomNorm = CGPoint(x: 0.5, y: 0.5) // layer point at the view center
    private var videoDims = CGSize.zero            // real frame size, for pan clamping
    private var lastDims = CGSize.zero             // feedQueue
    private let zoomBadge = NSButton(title: "", target: nil, action: nil)
    private var panning = false
    private var lastDragPoint = NSPoint.zero

    var isZoomed: Bool { zoomScale > 1.001 }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.zPosition = -1
        layer?.addSublayer(displayLayer)
        placeholderLayer.contentsGravity = .resizeAspect
        placeholderLayer.zPosition = -0.5
        layer?.addSublayer(placeholderLayer)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        addSubview(label)

        cachedBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        cachedBadge.textColor = NSColor.white.withAlphaComponent(0.9)
        cachedBadge.drawsBackground = true
        cachedBadge.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        cachedBadge.stringValue = " cached "
        cachedBadge.sizeToFit()
        cachedBadge.isHidden = true
        addSubview(cachedBadge)

        recBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        recBadge.drawsBackground = true
        recBadge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        recBadge.isHidden = true
        addSubview(recBadge)

        zoomBadge.isBordered = false
        zoomBadge.wantsLayer = true
        zoomBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        zoomBadge.layer?.cornerRadius = 3
        zoomBadge.target = self
        zoomBadge.action = #selector(zoomBadgeTapped)
        zoomBadge.isHidden = true
        addSubview(zoomBadge)

        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "arrow.backward.circle.fill",
                                   accessibilityDescription: "Back")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .semibold))
        backButton.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.isHidden = true
        addSubview(backButton)

        setStatus("connecting…")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// JPEG shown until the first live frame replaces it. A `cached` frame is
    /// last-known (possibly stale) — dimmed and badged so it's never mistaken
    /// for live; a fresh snapshot clears the badge.
    func setPlaceholder(_ image: NSImage, cached: Bool) {
        guard !videoOnScreen else { return }
        var rect = NSRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            placeholderLayer.contents = cg
        }
        placeholderLayer.opacity = cached ? 0.75 : 1.0
        cachedBadge.isHidden = !cached
    }

    /// Clip-recording badge ("0:42"); nil hides it.
    func setRecording(_ elapsed: String?) {
        guard let elapsed else { recBadge.isHidden = true; return }
        let s = NSMutableAttributedString(string: " ● ", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        ])
        s.append(NSAttributedString(string: "REC \(elapsed) ", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
        ]))
        recBadge.attributedStringValue = s
        recBadge.sizeToFit()
        recBadge.isHidden = false
        needsLayout = true
    }

    /// Camera-shutter flash for snapshots.
    func flash() {
        guard let layer else { return }
        let f = CALayer()
        f.backgroundColor = NSColor.white.cgColor
        f.frame = bounds
        f.zPosition = 10
        f.opacity = 0
        layer.addSublayer(f)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.7
        anim.toValue = 0
        anim.duration = 0.35
        CATransaction.begin()
        CATransaction.setCompletionBlock { f.removeFromSuperlayer() }
        f.add(anim, forKey: "flash")
        CATransaction.commit()
    }

    private func noteVideoStarted() {
        videoOnScreen = true
        placeholderLayer.isHidden = true
        cachedBadge.isHidden = true
    }

    func setStatus(_ s: String) {
        statusText = s
        label.stringValue = statusText.isEmpty ? " \(title) " : " \(title) · \(statusText) "
        label.sizeToFit()
        needsLayout = true
    }

    enum Feed { case sub, main, playback }
    private let feedQueue = DispatchQueue(label: "tile.feed")
    private var activeFeed: Feed = .sub
    private var waitingForSync = false

    /// Switch which feed this tile displays. No-op if already active.
    /// After a switch, frames are dropped until the new feed's next keyframe.
    func setFeed(_ f: Feed) {
        feedQueue.async {
            guard f != self.activeFeed else { return }
            self.activeFeed = f
            self.waitingForSync = true
            self.flushLayer()
        }
    }

    /// Re-arm the keyframe wait and flush without changing feeds — used when
    /// the *source* behind the active feed changes (a playback seek spawns a
    /// new pipe that keeps feeding the same .playback slot).
    func resyncFeed() {
        feedQueue.async {
            self.waitingForSync = true
            self.flushLayer()
        }
    }

    func enqueue(_ sb: CMSampleBuffer, isSync: Bool, from feed: Feed) {
        feedQueue.async {
            guard feed == self.activeFeed else { return }
            if self.waitingForSync {
                guard isSync else { return }
                self.waitingForSync = false
            }
            self.doEnqueue(sb)
        }
    }

    private func flushLayer() {
        if #available(macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.flush()
        } else {
            displayLayer.flush()
        }
    }

    private var startedVideo = false  // feedQueue

    private func doEnqueue(_ sb: CMSampleBuffer) {
        if !startedVideo {
            startedVideo = true
            DispatchQueue.main.async { self.noteVideoStarted() }
        }
        // Track the frame size so pan clamping follows the video's real
        // aspect rect, not the letterboxed layer.
        if let fmt = CMSampleBufferGetFormatDescription(sb) {
            let d = CMVideoFormatDescriptionGetDimensions(fmt)
            let size = CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
            if size != lastDims {
                lastDims = size
                DispatchQueue.main.async {
                    self.videoDims = size
                    self.needsLayout = true
                }
            }
        }
        if #available(macOS 14.0, *) {
            let r = displayLayer.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sb)
        } else {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sb)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lw = bounds.width * zoomScale, lh = bounds.height * zoomScale
        if lw > 0, lh > 0 {
            var origin = NSPoint(x: bounds.midX - zoomNorm.x * lw, y: bounds.midY - zoomNorm.y * lh)
            origin = clampZoomOrigin(origin)
            zoomNorm = NSPoint(x: (bounds.midX - origin.x) / lw, y: (bounds.midY - origin.y) / lh)
            displayLayer.frame = NSRect(x: origin.x, y: origin.y, width: lw, height: lh)
        } else {
            displayLayer.frame = bounds
        }
        placeholderLayer.frame = bounds
        CATransaction.commit()
        backButton.frame = NSRect(x: 6, y: bounds.height - 34, width: 28, height: 28)
        label.frame.origin = NSPoint(x: backButton.isHidden ? 6 : 40,
                                     y: bounds.height - label.frame.height - 6)
        cachedBadge.frame.origin = NSPoint(x: bounds.width - cachedBadge.frame.width - 6, y: 6)
        zoomBadge.frame.origin = NSPoint(x: bounds.width - zoomBadge.frame.width - 6,
                                         y: bounds.height - zoomBadge.frame.height - 6)
        // REC sits top-right, sliding left of the zoom badge when it's shown.
        var recX = bounds.width - recBadge.frame.width - 6
        if !zoomBadge.isHidden { recX -= zoomBadge.frame.width + 6 }
        recBadge.frame.origin = NSPoint(x: recX, y: bounds.height - recBadge.frame.height - 6)
        onLayoutChange?()
    }

    func setBackVisible(_ visible: Bool) {
        backButton.isHidden = !visible
        needsLayout = true
    }

    @objc private func backTapped() { onBack?() }

    // MARK: digital zoom

    /// Keep the video's fitted rect covering the view: no edge may pan into
    /// view, and an axis whose (scaled) video is smaller than the view stays
    /// centered. At 1× this collapses to origin zero.
    private func clampZoomOrigin(_ o: NSPoint) -> NSPoint {
        let lw = bounds.width * zoomScale, lh = bounds.height * zoomScale
        var vw = lw, vh = lh                     // fitted video rect within the layer
        if videoDims.width > 0, videoDims.height > 0 {
            let aspect = videoDims.width / videoDims.height
            if lw / lh > aspect { vw = lh * aspect } else { vh = lw / aspect }
        }
        let vx = (lw - vw) / 2, vy = (lh - vh) / 2
        var x = o.x, y = o.y
        if vw >= bounds.width {
            x = min(-vx, max(bounds.width - vx - vw, x))
        } else {
            x = (bounds.width - lw) / 2
        }
        if vh >= bounds.height {
            y = min(-vy, max(bounds.height - vy - vh, y))
        } else {
            y = (bounds.height - lh) / 2
        }
        return NSPoint(x: x, y: y)
    }

    /// Zoom toward `viewPoint` (nil = view center): the video point under it
    /// stays put while the scale changes.
    func setZoom(_ target: CGFloat, at viewPoint: NSPoint?) {
        let new = min(8, max(1, target))
        guard bounds.width > 0, bounds.height > 0 else { return }
        let p = viewPoint ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let f = displayLayer.frame
        let lpx = f.width > 0 ? (p.x - f.origin.x) / f.width : 0.5
        let lpy = f.height > 0 ? (p.y - f.origin.y) / f.height : 0.5
        zoomScale = new
        let lw = bounds.width * new, lh = bounds.height * new
        let origin = NSPoint(x: p.x - lpx * lw, y: p.y - lpy * lh)
        zoomNorm = NSPoint(x: (bounds.midX - origin.x) / lw, y: (bounds.midY - origin.y) / lh)
        needsLayout = true
        updateZoomBadge()
        onZoomChange?()
    }

    /// Fires on any zoom level change (the back arrow's visibility rides on it).
    var onZoomChange: (() -> Void)?

    func panZoom(dx: CGFloat, dy: CGFloat) {
        guard isZoomed else { return }
        let lw = bounds.width * zoomScale, lh = bounds.height * zoomScale
        guard lw > 0, lh > 0 else { return }
        zoomNorm = NSPoint(x: zoomNorm.x - dx / lw, y: zoomNorm.y - dy / lh)
        needsLayout = true
    }

    func resetZoom() {
        zoomScale = 1
        zoomNorm = NSPoint(x: 0.5, y: 0.5)
        needsLayout = true
        updateZoomBadge()
        onZoomChange?()
    }

    private func updateZoomBadge() {
        zoomBadge.isHidden = !isZoomed
        guard isZoomed else { return }
        zoomBadge.attributedTitle = NSAttributedString(
            string: String(format: " %.1f× ✕ ", zoomScale),
            attributes: [.foregroundColor: NSColor.white,
                         .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)])
        zoomBadge.sizeToFit()
        needsLayout = true
    }

    @objc private func zoomBadgeTapped() { resetZoom() }

    override func magnify(with event: NSEvent) {
        guard zoomEnabled else { return }
        setZoom(zoomScale * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoomEnabled, isZoomed else { super.scrollWheel(with: event); return }
        panZoom(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
    }

    /// Red keyboard-cursor border (arrow-key navigation in the grid).
    /// Turning it off fades the border out rather than snapping.
    func setKeyCursor(_ on: Bool) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "keyCursorFade")
        if on {
            layer.borderColor = NSColor.systemRed.cgColor
            layer.borderWidth = 3
        } else if layer.borderWidth > 0 {
            let fade = CABasicAnimation(keyPath: "borderColor")
            fade.fromValue = layer.borderColor
            fade.toValue = NSColor.systemRed.withAlphaComponent(0).cgColor
            fade.duration = 0.5
            layer.add(fade, forKey: "keyCursorFade")
            layer.borderColor = NSColor.systemRed.withAlphaComponent(0).cgColor
        }
    }

    /// While lifted (being drag-reordered) the tile floats above its siblings
    /// with a shadow and an accent border.
    func setLifted(_ lifted: Bool) {
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: -6)
        layer.shadowRadius = 14
        layer.shadowOpacity = lifted ? 0.6 : 0
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.borderWidth = lifted ? 2 : 0
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Focused view: double-click toggles 2× zoom at the click point.
            // In the grid it still focuses (via the app delegate's handler).
            if zoomEnabled {
                if isZoomed { resetZoom() }
                else { setZoom(2, at: convert(event.locationInWindow, from: nil)) }
            } else {
                onDoubleClick?()
            }
            return
        }
        pressStart = event.locationInWindow
        lastDragPoint = event.locationInWindow
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pressTimer = nil
            self.reordering = self.onLongPress?() ?? false
        }
        pressTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        if reordering { onDrag?(event); return }
        // Zoomed in, dragging pans the image (grab-hand).
        if zoomEnabled, isZoomed {
            pressTimer?.cancel()
            pressTimer = nil
            if !panning {
                panning = true
                NSCursor.closedHand.set()
            }
            let p = event.locationInWindow
            panZoom(dx: p.x - lastDragPoint.x, dy: p.y - lastDragPoint.y)
            lastDragPoint = p
            return
        }
        // Moving away before the long-press fires is a stray drag, not a hold.
        if hypot(event.locationInWindow.x - pressStart.x,
                 event.locationInWindow.y - pressStart.y) > 6 {
            pressTimer?.cancel()
            pressTimer = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        pressTimer?.cancel()
        pressTimer = nil
        if panning {
            panning = false
            NSCursor.arrow.set()
        }
        if reordering {
            reordering = false
            onDragEnd?()
        }
    }
}
