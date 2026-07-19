// SupplementaryViews.swift — the floating supplementary panes and the
// camera selector panel, both living inside a focused tile.

import AppKit
import AVFoundation
import CoreMedia

/// One floating pane: a small video view that can be dragged anywhere,
/// resized from its bottom-right corner, closed with ✕, and promoted to the
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
    private let nameLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "", target: nil, action: nil)

    private let feedQueue = DispatchQueue(label: "supp.feed")
    private var waitingForSync = true

    private enum DragMode { case none, move, resize }
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
        layer?.addSublayer(displayLayer)

        nameLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        addSubview(nameLabel)
        setNote(nil)

        closeButton.isBordered = false
        closeButton.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        ])
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
        CATransaction.commit()
        nameLabel.frame.origin = NSPoint(x: 4, y: bounds.height - nameLabel.frame.height - 4)
        closeButton.frame = NSRect(x: bounds.width - 20, y: bounds.height - 20, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Resize grip: diagonal lines in the bottom-right corner.
        NSColor.white.withAlphaComponent(0.6).setStroke()
        for i in 1...4 {
            let inset = CGFloat(i) * 5
            let p = NSBezierPath()
            p.move(to: NSPoint(x: bounds.width - inset, y: 3))
            p.line(to: NSPoint(x: bounds.width - 3, y: inset))
            p.lineWidth = 1.5
            p.stroke()
        }
    }

    override func resetCursorRects() {
        let grip = NSRect(x: bounds.width - 24, y: 0, width: 24, height: 24)
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(grip, cursor: .crosshair)
    }

    /// Clamp a frame into the superview, respecting the bar inset and
    /// sane min/max sizes.
    func clamped(_ f: NSRect) -> NSRect {
        guard let sup = superview else { return f }
        var r = f
        let minW = max(120, sup.bounds.width * 0.15)
        let maxW = sup.bounds.width * 0.5
        r.size.width = min(max(r.width, minW), maxW)
        let maxH = sup.bounds.height * 0.6
        r.size.height = min(max(r.height, 70), maxH)
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
        let p = convert(event.locationInWindow, from: nil)
        dragMode = (p.x > bounds.width - 24 && p.y < 24) ? .resize : .move
        if dragMode == .move { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let dx = event.locationInWindow.x - dragStartPoint.x
        let dy = event.locationInWindow.y - dragStartPoint.y
        switch dragMode {
        case .move:
            frame = clamped(dragStartFrame.offsetBy(dx: dx, dy: dy))
        case .resize:
            let top = dragStartFrame.maxY
            var r = dragStartFrame
            r.size.width = dragStartFrame.width + dx
            r.size.height = dragStartFrame.height - dy
            r.origin.y = top - r.size.height
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
