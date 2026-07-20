// HelpOverlay.swift — the "?" keyboard-shortcut cheat sheet: a translucent
// panel over the whole window showing the shortcuts for where the user is
// right now (grid, live camera view, or playback). Any key or click closes.

import AppKit

enum HelpContext {
    case grid, camera, playback

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .camera: return "Camera view"
        case .playback: return "Playback"
        }
    }

    var rows: [(key: String, desc: String)] {
        switch self {
        case .grid: return [
            ("← ↑ ↓ →", "select a tile"),
            ("Return", "open the selected camera"),
            ("2×click", "open a camera"),
            ("hold+drag", "reorder the grid"),
            ("⌘,", "settings"),
            ("Esc", "cancel selection / reorder"),
        ]
        case .camera: return [
            ("P", "recorded playback"),
            ("+", "add a supplementary pane"),
            ("S", "snapshot → Desktop"),
            ("R", "record clip → Desktop"),
            ("2×click", "quick 2× zoom"),
            ("pinch", "zoom · scroll or drag pans"),
            ("2×click pane", "open that camera"),
            ("Esc", "zoom out · back · grid"),
        ]
        case .playback: return [
            ("Space", "pause / resume"),
            ("← →", "seek 10 s · ⇧ 60 s · ⌘ 15 min"),
            ("0–9", "jump within visible footage"),
            ("X", "speed 1× → 2× → 4×"),
            ("N / ⇧N", "next / previous motion"),
            ("C", "calendar"),
            ("S", "snapshot at this position"),
            ("R", "record clip from here"),
            ("+", "add a supplementary pane"),
            ("scroll", "timeline zoom · pan"),
            ("P / Esc", "back to live"),
        ]
        }
    }
}

final class ShortcutHelpView: NSView {
    var onClose: (() -> Void)?

    private let panel = NSView()

    override var acceptsFirstResponder: Bool { true }

    init(context: HelpContext) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 10
        addSubview(panel)

        let title = NSTextField(labelWithString: "Shortcuts — \(context.title)")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white

        let grid = NSGridView(views: context.rows.map { row in
            let key = NSTextField(labelWithString: row.key)
            key.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            key.textColor = .white
            key.alignment = .right
            let desc = NSTextField(labelWithString: row.desc)
            desc.font = .systemFont(ofSize: 12)
            desc.textColor = NSColor(white: 0.78, alpha: 1)
            return [key, desc]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let hint = NSTextField(labelWithString: "any key or click closes")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor(white: 0.55, alpha: 1)

        let root = NSStackView(views: [title, grid, hint])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 12, right: 22)
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
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func mouseDown(with event: NSEvent) { onClose?() }

    override func keyDown(with event: NSEvent) { onClose?() }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}
