// SupplementaryViews.swift — the floating supplementary panes and the
// camera selector panel, both living inside a focused tile.

import AppKit
import AVFoundation
import CoreMedia

/// One floating pane: a small video view that can be dragged anywhere,
/// resized from any edge or corner, closed with ✕, and promoted to the
/// main view by double-click. Frames come from outside via enqueue() — the
/// live substream tap or a synced PlaybackStream, the pane doesn't care.
final class SupplementaryTile: NSView {
    let camera: Camera
    var onClose: (() -> Void)?
    var onPromote: (() -> Void)?
    /// Every frame change during a drag/resize — the manager re-captures the
    /// normalized rect immediately so a layout pass can't snap the pane back.
    var onFrameChanged: (() -> Void)?
    /// Drag/resize finished — persist.
    var onUserLayoutChange: (() -> Void)?
    var bottomInset: CGFloat = 0          // keep clear of the playback bar

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let placeholderLayer = CALayer()
    private let nameLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    private let feedQueue = DispatchQueue(label: "supp.feed")
    private var waitingForSync = true
    private var startedVideo = false      // feedQueue
    private var videoOnScreen = false     // main thread
    /// Whether a real frame has rendered (main thread) — the keyframe nudge
    /// loop stops retrying once this flips.
    var hasVideo: Bool { videoOnScreen }
    /// Fired once, on main, when the first frame renders — used to freeze a
    /// pane added while playback is paused right on the paused frame.
    var onFirstFrame: (() -> Void)?

    /// Which edges a resize drag moves — corners carry two.
    private struct ResizeEdges: OptionSet {
        let rawValue: Int
        static let n = ResizeEdges(rawValue: 1)   // top
        static let s = ResizeEdges(rawValue: 2)   // bottom
        static let e = ResizeEdges(rawValue: 4)   // right
        static let w = ResizeEdges(rawValue: 8)   // left
    }

    private enum DragMode: Equatable { case none, move, resize(ResizeEdges) }
    private var dragMode = DragMode.none
    private var dragStartPoint = NSPoint.zero
    private var dragStartFrame = NSRect.zero

    init(camera: Camera) {
        self.camera = camera
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Chrome frame: a clearly visible boundary that doubles as the grab
        // target for moving/resizing.
        layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.zPosition = -1
        layer?.addSublayer(displayLayer)
        placeholderLayer.contentsGravity = .resizeAspect
        placeholderLayer.zPosition = -0.5
        layer?.addSublayer(placeholderLayer)

        nameLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        addSubview(nameLabel)
        setNote(nil)

        closeButton.isBordered = false
        closeButton.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        ])
        // Dark disc behind the glyph — a bare white ✕ vanishes over
        // white-ish video (sky, walls). Same backing tint as the name label.
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        closeButton.layer?.cornerRadius = 8   // circular at the 16×16 frame
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setNote(_ note: String?) {
        nameLabel.stringValue = note == nil ? " \(camera.name) " : " \(camera.name) · \(note!) "
        nameLabel.sizeToFit()
        needsLayout = true
    }

    /// JPEG shown until the first live frame replaces it. A `cached` frame is
    /// last-known (possibly stale) — dimmed so it's never mistaken for live.
    func setPlaceholder(_ image: NSImage, cached: Bool) {
        guard !videoOnScreen else { return }
        var rect = NSRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            placeholderLayer.contents = cg
        }
        placeholderLayer.opacity = cached ? 0.75 : 1.0
    }

    /// Drop frames until the next keyframe — call whenever the source behind
    /// this pane changes (live<->playback, seeks).
    func resync() {
        feedQueue.async {
            self.waitingForSync = true
            if #available(macOS 14.0, *) {
                self.displayLayer.sampleBufferRenderer.flush()
            } else {
                self.displayLayer.flush()
            }
        }
    }

    func enqueue(_ sb: CMSampleBuffer, isSync: Bool) {
        feedQueue.async {
            if self.waitingForSync {
                guard isSync else { return }
                self.waitingForSync = false
            }
            if !self.startedVideo {
                self.startedVideo = true
                DispatchQueue.main.async {
                    self.videoOnScreen = true
                    self.placeholderLayer.isHidden = true
                    self.onFirstFrame?()
                    self.onFirstFrame = nil
                }
            }
            if #available(macOS 14.0, *) {
                let r = self.displayLayer.sampleBufferRenderer
                if r.status == .failed { r.flush() }
                r.enqueue(sb)
            } else {
                if self.displayLayer.status == .failed { self.displayLayer.flush() }
                self.displayLayer.enqueue(sb)
            }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        placeholderLayer.frame = bounds
        CATransaction.commit()
        nameLabel.frame.origin = NSPoint(x: 4, y: bounds.height - nameLabel.frame.height - 4)
        closeButton.frame = NSRect(x: bounds.width - 20, y: bounds.height - 20, width: 16, height: 16)
        window?.invalidateCursorRects(for: self)   // zones track the new size
    }

    // Resize hit zones: a thin band along each edge, widened at the corners
    // so the diagonal grabs have a fatter target.
    private static let edgeBand: CGFloat = 10
    private static let cornerReach: CGFloat = 18

    // Real window-style resize cursors arrived as API in macOS 15
    // (NSCursor.frameResize); older systems fall back to the closest
    // public cursors.
    private static let cursorNS: NSCursor = {
        if #available(macOS 15.0, *) { return .frameResize(position: .top, directions: .all) }
        return .resizeUpDown
    }()
    private static let cursorEW: NSCursor = {
        if #available(macOS 15.0, *) { return .frameResize(position: .left, directions: .all) }
        return .resizeLeftRight
    }()
    private static let cursorNWSE: NSCursor = {   // "\" diagonal: top-left / bottom-right
        if #available(macOS 15.0, *) { return .frameResize(position: .topLeft, directions: .all) }
        return .crosshair
    }()
    private static let cursorNESW: NSCursor = {   // "/" diagonal: top-right / bottom-left
        if #available(macOS 15.0, *) { return .frameResize(position: .topRight, directions: .all) }
        return .crosshair
    }()

    /// Which resize zone (if any) a point falls in. Empty = interior = move.
    private func resizeEdges(at p: NSPoint) -> ResizeEdges {
        // The ✕ button owns the top-right corner — never offer resize where a
        // click would actually close the pane.
        if closeButton.frame.insetBy(dx: -4, dy: -4).contains(p) { return [] }
        let t = Self.edgeBand, c = Self.cornerReach
        var e = ResizeEdges()
        if p.x < t { e.insert(.w) }
        if p.x > bounds.width - t { e.insert(.e) }
        if p.y < t { e.insert(.s) }
        if p.y > bounds.height - t { e.insert(.n) }
        // Corner reach: within c of two edges counts as that corner even
        // when outside the thin band on one axis.
        if p.x < c && p.y < c { e = [.w, .s] }
        if p.x > bounds.width - c && p.y < c { e = [.e, .s] }
        if p.x < c && p.y > bounds.height - c { e = [.w, .n] }
        if p.x > bounds.width - c && p.y > bounds.height - c { e = [.e, .n] }
        return e
    }

    override func resetCursorRects() {
        let b = bounds
        let t = Self.edgeBand, c = Self.cornerReach
        addCursorRect(b, cursor: .openHand)
        // Edges, between the corner squares.
        addCursorRect(NSRect(x: c, y: b.height - t, width: max(0, b.width - 2 * c), height: t), cursor: Self.cursorNS)
        addCursorRect(NSRect(x: c, y: 0, width: max(0, b.width - 2 * c), height: t), cursor: Self.cursorNS)
        addCursorRect(NSRect(x: 0, y: c, width: t, height: max(0, b.height - 2 * c)), cursor: Self.cursorEW)
        addCursorRect(NSRect(x: b.width - t, y: c, width: t, height: max(0, b.height - 2 * c)), cursor: Self.cursorEW)
        // Corners. The top-right square is skipped: the ✕ button sits there
        // and a resize cursor over a close control would mislead.
        addCursorRect(NSRect(x: 0, y: b.height - c, width: c, height: c), cursor: Self.cursorNWSE)
        addCursorRect(NSRect(x: b.width - c, y: 0, width: c, height: c), cursor: Self.cursorNWSE)
        addCursorRect(NSRect(x: 0, y: 0, width: c, height: c), cursor: Self.cursorNESW)
    }

    /// Min/max pane size within a superview — shared by clamped() and the
    /// resize drag (which must clamp size before anchoring fixed edges).
    private func clampSize(_ s: NSSize, in sup: NSView) -> NSSize {
        var s = s
        let minW = max(120, sup.bounds.width * 0.15)
        s.width = min(max(s.width, minW), sup.bounds.width * 0.5)
        s.height = min(max(s.height, 70), sup.bounds.height * 0.6)
        return s
    }

    /// Clamp a frame into the superview, respecting the bar inset and
    /// sane min/max sizes.
    func clamped(_ f: NSRect) -> NSRect {
        guard let sup = superview else { return f }
        var r = f
        r.size = clampSize(r.size, in: sup)
        r.origin.x = min(max(2, r.origin.x), max(2, sup.bounds.width - r.width - 2))
        r.origin.y = min(max(bottomInset + 2, r.origin.y), max(bottomInset + 2, sup.bounds.height - r.height - 2))
        return r
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onPromote?(); return }
        // Raise visually only — re-adding the view here would cancel AppKit's
        // mouse tracking and kill the drag; the real reorder happens on mouseUp.
        layer?.zPosition = 50
        dragStartPoint = event.locationInWindow
        dragStartFrame = frame
        let edges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        dragMode = edges.isEmpty ? .move : .resize(edges)
        if dragMode == .move { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStartPoint.x
        let dy = event.locationInWindow.y - dragStartPoint.y
        switch dragMode {
        case .move:
            frame = clamped(dragStartFrame.offsetBy(dx: dx, dy: dy))
        case .resize(let edges):
            var r = dragStartFrame
            if edges.contains(.e) { r.size.width += dx }
            if edges.contains(.w) { r.size.width -= dx }
            if edges.contains(.n) { r.size.height += dy }
            if edges.contains(.s) { r.size.height -= dy }
            // Clamp size first, then re-anchor: dragging one edge must keep
            // the opposite edge fixed even when the min/max clamp kicks in.
            if let sup = superview { r.size = clampSize(r.size, in: sup) }
            if edges.contains(.w) { r.origin.x = dragStartFrame.maxX - r.width }
            if edges.contains(.s) { r.origin.y = dragStartFrame.maxY - r.height }
            frame = clamped(r)
        case .none:
            return
        }
        onFrameChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        layer?.zPosition = 0
        superview?.addSubview(self, positioned: .above, relativeTo: nil)   // real raise
        if dragMode != .none {
            dragMode = .none
            NSCursor.arrow.set()
            onUserLayoutChange?()
        }
    }

    @objc private func closeTapped() { onClose?() }
}

/// The `+` selector: a translucent panel over the focused view with a
/// thumbnail grid of the other cameras. Type to filter, Return picks the top
/// match, Esc clears the filter then closes, click outside closes. When no
/// panes are active and a saved layout exists, a restore row offers it back.
final class SupplementarySelector: NSView {
    struct Entry {
        let camera: Camera
        let enabled: Bool
        let note: String?
    }

    var onPick: ((Camera) -> Void)?
    var onRestore: (() -> Void)?
    var onClose: (() -> Void)?

    private let entries: [Entry]
    private let restoreNames: [String]?
    private var filter = ""
    private let panel = NSView()
    private let filterLabel = NSTextField(labelWithString: "")
    private let grid = NSStackView()
    private var entryByTag: [Int: Entry] = [:]
    private var cellButtons: [NSButton] = []   // in visible order
    private var selIndex: Int?                 // arrow-key cursor (red border)

    override var acceptsFirstResponder: Bool { true }

    init(entries: [Entry], restoreNames: [String]?) {
        self.entries = entries
        self.restoreNames = restoreNames
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 10
        addSubview(panel)

        filterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        filterLabel.textColor = NSColor(white: 0.7, alpha: 1)
        filterLabel.alignment = .center

        grid.orientation = .vertical
        grid.alignment = .centerX
        grid.spacing = 8

        let root = NSStackView(views: [filterLabel, grid])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(root)
        panel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            root.topAnchor.constraint(equalTo: panel.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private var visibleEntries: [Entry] {
        filter.isEmpty ? entries
            : entries.filter { $0.camera.name.lowercased().contains(filter) }
    }

    private func rebuild() {
        filterLabel.stringValue = filter.isEmpty ? "type to filter · Esc closes" : "filter: \(filter)"
        grid.arrangedSubviews.forEach { grid.removeArrangedSubview($0); $0.removeFromSuperview() }
        entryByTag.removeAll()
        cellButtons.removeAll()

        if filter.isEmpty, let names = restoreNames, !names.isEmpty {
            let b = NSButton(title: "", target: self, action: #selector(restoreTapped))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: "↺ Restore last: \(names.joined(separator: ", "))",
                attributes: [.foregroundColor: NSColor(calibratedRed: 0.16, green: 0.74, blue: 0.80, alpha: 1),
                             .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            grid.addArrangedSubview(b)
        }

        let visible = visibleEntries
        var row: NSStackView?
        for (i, entry) in visible.enumerated() {
            if i % 4 == 0 {
                row = NSStackView()
                row!.spacing = 8
                grid.addArrangedSubview(row!)
            }
            let cell = makeCell(entry, tag: i)
            entryByTag[i] = entry
            cellButtons.append(cell)
            row!.addArrangedSubview(cell)
        }
        if visible.isEmpty {
            let l = NSTextField(labelWithString: "no match")
            l.textColor = .secondaryLabelColor
            grid.addArrangedSubview(l)
        }
        updateSelection()
    }

    /// Arrow-key cursor: a red border on the selected cell, grid-cursor style.
    private func updateSelection() {
        for (i, b) in cellButtons.enumerated() {
            b.layer?.borderColor = NSColor.systemRed.cgColor
            b.layer?.borderWidth = (i == selIndex) ? 2 : 0
            b.layer?.cornerRadius = 6
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !cellButtons.isEmpty else { return }
        let next = (selIndex ?? (delta > 0 ? -delta : 0)) + delta
        selIndex = min(max(0, next), cellButtons.count - 1)
        updateSelection()
    }

    private func makeCell(_ entry: Entry, tag: Int) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(cellTapped(_:)))
        b.tag = tag
        b.isBordered = false
        b.wantsLayer = true
        b.imagePosition = .imageAbove
        b.image = Self.thumbnail(for: entry.camera.host, size: NSSize(width: 108, height: 60))
        var title = entry.camera.name
        if let note = entry.note { title += " · \(note)" }
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ])
        b.isEnabled = entry.enabled
        b.alphaValue = entry.enabled ? 1 : 0.35
        b.widthAnchor.constraint(equalToConstant: 116).isActive = true
        return b
    }

    private static func thumbnail(for host: String, size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.14, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            if let snap = SnapshotCache.load(host: host), snap.size.width > 0, snap.size.height > 0 {
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                let s = snap.size
                let scale = max(rect.width / s.width, rect.height / s.height)
                let w = s.width * scale, h = s.height * scale
                snap.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            }
            return true
        }
    }

    // MARK: input

    override func mouseDown(with event: NSEvent) {
        // A click on the dimmed backdrop (outside the panel) closes.
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) {
            onClose?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {                       // esc: clear filter, then close
            cancelOperation(nil)
            return
        }
        switch event.specialKey {
        case .leftArrow?: moveSelection(-1); return
        case .rightArrow?: moveSelection(1); return
        case .upArrow?: moveSelection(-4); return
        case .downArrow?: moveSelection(4); return
        default: break
        }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let c = chars.lowercased()
        if event.keyCode == 51 {                       // backspace
            if !filter.isEmpty { filter.removeLast(); selIndex = nil; rebuild() }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // return: selection, else top match
            let pool = visibleEntries
            if let s = selIndex, s < pool.count {
                if pool[s].enabled { onPick?(pool[s].camera) } else { NSSound.beep() }
            } else if let first = pool.first(where: { $0.enabled }) {
                onPick?(first.camera)
            }
            return
        }
        let scalar = c.unicodeScalars.first!
        if CharacterSet.alphanumerics.contains(scalar) || c == " " || c == "-" {
            filter += c
            selIndex = nil
            rebuild()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if !filter.isEmpty {
            filter = ""
            selIndex = nil
            rebuild()
        } else {
            onClose?()
        }
    }

    @objc private func cellTapped(_ sender: NSButton) {
        guard let entry = entryByTag[sender.tag], entry.enabled else { return }
        onPick?(entry.camera)
    }

    @objc private func restoreTapped() { onRestore?() }
}
