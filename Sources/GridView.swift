// GridView.swift — tile grid layout, focus, and drag-to-reorder.

import AppKit

final class GridView: NSView {
    var tiles: [TileView] = []
    var onFocusChange: ((Int?) -> Void)?
    /// Mirror one drag-reorder step into the parallel streams array.
    var onMove: ((Int, Int) -> Void)?
    /// Drag finished with the order changed — persist it.
    var onReorderEnd: (() -> Void)?
    /// First shot at key presses (playback control etc.); return true to consume.
    var onKey: ((NSEvent) -> Bool)?
    /// First shot at Esc; return true to consume (e.g. leave playback but stay
    /// focused). Falls through to unfocus.
    var onEscape: (() -> Bool)?
    var focused: Int? {
        didSet {
            needsLayout = true
            if let f = focused {
                lastKeySel = f          // arrows resume from here after unfocus
                clearKeyCursor()
            }
            if oldValue != focused { onFocusChange?(focused) }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        if focused == nil, !isReordering, !tiles.isEmpty, handleGridKey(event) { return }
        super.keyDown(with: event)
    }

    // MARK: keyboard navigation (grid mode)
    // The first arrow press shows a red cursor on the first (or last-used)
    // tile; further arrows move it, Return focuses it, and 5 s of inactivity
    // fades it away.

    private var keySel: Int?
    private var lastKeySel = 0
    private var keySelFade: DispatchWorkItem?

    private func handleGridKey(_ e: NSEvent) -> Bool {
        switch e.specialKey {
        case .leftArrow?: moveKeyCursor(dc: -1, dr: 0)
        case .rightArrow?: moveKeyCursor(dc: 1, dr: 0)
        case .upArrow?: moveKeyCursor(dc: 0, dr: -1)
        case .downArrow?: moveKeyCursor(dc: 0, dr: 1)
        case .carriageReturn?, .enter?:
            guard let i = keySel else { return false }
            focused = i                 // didSet clears the cursor
        default: return false
        }
        return true
    }

    private func moveKeyCursor(dc: Int, dr: Int) {
        let n = tiles.count
        var i = min(lastKeySel, n - 1)
        if let cur = keySel {           // a visible cursor moves; the first press just shows it
            let g = gridGeometry()
            let rows = (n + g.cols - 1) / g.cols
            let c = min(max(0, cur % g.cols + dc), g.cols - 1)
            let r = min(max(0, cur / g.cols + dr), rows - 1)
            i = min(n - 1, r * g.cols + c)
            if i != cur, cur < tiles.count { tiles[cur].setKeyCursor(false) }
        }
        keySel = i
        lastKeySel = i
        tiles[i].setKeyCursor(true)
        keySelFade?.cancel()
        let fade = DispatchWorkItem { [weak self] in self?.clearKeyCursor() }
        keySelFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: fade)
    }

    func clearKeyCursor() {
        keySelFade?.cancel()
        keySelFade = nil
        guard let i = keySel else { return }
        keySel = nil
        if i < tiles.count { tiles[i].setKeyCursor(false) }
    }

    private func gridGeometry() -> (cols: Int, w: CGFloat, h: CGFloat, gap: CGFloat) {
        let n = max(1, tiles.count)
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let gap: CGFloat = 2
        let w = (bounds.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let h = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return (cols, w, h, gap)
    }

    private func slotFrame(_ i: Int) -> NSRect {
        let g = gridGeometry()
        let r = i / g.cols, c = i % g.cols
        return NSRect(x: CGFloat(c) * (g.w + g.gap),
                      y: bounds.height - CGFloat(r + 1) * g.h - CGFloat(r) * g.gap,
                      width: g.w, height: g.h)
    }

    private func slotIndex(at p: NSPoint) -> Int {
        let g = gridGeometry()
        let col = min(g.cols - 1, max(0, Int(p.x / (g.w + g.gap))))
        let row = max(0, Int((bounds.height - p.y) / (g.h + g.gap)))
        return min(tiles.count - 1, row * g.cols + col)
    }

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        if let f = focused, f < tiles.count {
            for (i, t) in tiles.enumerated() {
                t.isHidden = i != f
                if i == f { t.frame = bounds }
            }
            return
        }
        for (i, t) in tiles.enumerated() {
            t.isHidden = false
            if i == dragIndex { continue }  // the lifted tile follows the mouse
            t.frame = slotFrame(i)
        }
    }

    // MARK: drag-to-reorder (entered by long-pressing a tile)

    private var dragIndex: Int?
    private var dragOrigIndex = 0
    private var dragGrabOffset = NSPoint.zero

    var isReordering: Bool { dragIndex != nil }

    func beginDrag(_ tile: TileView) -> Bool {
        guard focused == nil, tiles.count > 1, dragIndex == nil,
              let i = tiles.firstIndex(where: { $0 === tile }) else { return false }
        clearKeyCursor()
        dragIndex = i
        dragOrigIndex = i
        let mouse = convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        dragGrabOffset = NSPoint(x: tile.frame.midX - mouse.x, y: tile.frame.midY - mouse.y)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        NSCursor.closedHand.set()
        tile.layer?.zPosition = 100
        tile.setLifted(true)
        let lifted = tile.frame.insetBy(dx: -tile.frame.width * 0.015,
                                        dy: -tile.frame.height * 0.015)
        animate(0.18, {
            tile.animator().frame = lifted
            for t in self.tiles where t !== tile { t.animator().alphaValue = 0.75 }
        })
        return true
    }

    func updateDrag(_ tile: TileView, with event: NSEvent) {
        guard let i = dragIndex, i < tiles.count, tiles[i] === tile else { return }
        let mouse = convert(event.locationInWindow, from: nil)
        var f = tile.frame
        f.origin.x = mouse.x + dragGrabOffset.x - f.width / 2
        f.origin.y = mouse.y + dragGrabOffset.y - f.height / 2
        tile.frame = f
        let target = slotIndex(at: NSPoint(x: f.midX, y: f.midY))
        guard target != i else { return }
        tiles.remove(at: i)
        tiles.insert(tile, at: target)
        dragIndex = target
        onMove?(i, target)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        animate(0.22, {
            for (j, t) in self.tiles.enumerated() where t !== tile {
                t.animator().frame = self.slotFrame(j)
            }
        })
    }

    func endDrag(_ tile: TileView) {
        guard let i = dragIndex, i < tiles.count, tiles[i] === tile else { return }
        settleDrag(tile, into: i)
        if i != dragOrigIndex { onReorderEnd?() }
    }

    /// Esc during a drag: put the tile back where it started.
    func cancelDrag() {
        guard let i = dragIndex, i < tiles.count else { return }
        let tile = tiles[i]
        if i != dragOrigIndex {
            tiles.remove(at: i)
            tiles.insert(tile, at: dragOrigIndex)
            onMove?(i, dragOrigIndex)
        }
        settleDrag(tile, into: dragOrigIndex)
    }

    private func settleDrag(_ tile: TileView, into slot: Int) {
        dragIndex = nil
        NSCursor.arrow.set()
        animate(0.3, {
            tile.animator().frame = self.slotFrame(slot)
            for (j, t) in self.tiles.enumerated() {
                t.animator().alphaValue = 1
                if t !== tile { t.animator().frame = self.slotFrame(j) }
            }
        }, completion: {
            tile.layer?.zPosition = 0
            tile.setLifted(false)
        })
    }

    private func animate(_ duration: TimeInterval, _ changes: () -> Void,
                         completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }

    override func cancelOperation(_ sender: Any?) {
        if isReordering { cancelDrag(); return }
        if keySel != nil { clearKeyCursor(); return }
        // Zoomed into the focused tile: first Esc zooms back out.
        if let f = focused, f < tiles.count, tiles[f].isZoomed {
            tiles[f].resetZoom()
            return
        }
        if onEscape?() == true { return }
        focused = nil
    }
}
