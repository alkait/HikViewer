// Bookmarks.swift — bookmarked playback moments: the on-disk store, the
// naming prompt shown when B is pressed in playback, and the Shift-B list
// pane (selector-style: type to filter, arrows + red cursor, Return jumps,
// delete removes with confirmation).

import AppKit

struct Bookmark: Codable, Equatable {
    var id: UUID
    var host: String
    var cameraName: String      // kept so rows stay readable if the camera is renamed/removed
    var time: Date              // playback position (absolute; shown in the NVR's timezone)
    var label: String
    var created: Date
}

/// Same shape as LayoutStore: UI state, no credentials, not part of
/// export/import.
enum BookmarkStore {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("hikviewer/bookmarks.json")
    }()

    private(set) static var all: [Bookmark] = load()

    private static func load() -> [Bookmark] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data) else { return [] }
        return list
    }

    static func add(_ b: Bookmark) {
        all.append(b)
        persist()
    }

    static func remove(id: UUID) {
        all.removeAll { $0.id == id }
        persist()
    }

    private static func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func rowFormatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE yyyy-MM-dd h:mm:ss a"
        f.timeZone = tz
        return f
    }
}

/// The B prompt: a small panel over the focused tile asking for an optional
/// bookmark name. Return saves (empty is fine — the camera + timestamp
/// identify the moment), Esc or a click outside cancels.
final class BookmarkNamePrompt: NSView, NSTextFieldDelegate {
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let panel = NSView()
    private let field = NSTextField(string: "")

    init(subtitle: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 10
        addSubview(panel)

        let title = NSTextField(labelWithString: "New Bookmark")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white

        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sub.textColor = NSColor(white: 0.7, alpha: 1)

        field.placeholderString = "name (optional)"
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let hint = NSTextField(labelWithString: "Return saves · Esc cancels")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor(white: 0.55, alpha: 1)

        let root = NSStackView(views: [title, sub, field, hint])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
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

    func focus(in window: NSWindow) { window.makeFirstResponder(field) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            onSave?(field.stringValue.trimmingCharacters(in: .whitespaces))
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onCancel?() }
    }
}

/// The Shift-B pane: all bookmarks, newest first, selector-style — type to
/// filter, ↑/↓ move a red-border cursor, Return/click jumps, backspace (with
/// an empty filter) or ⌦ deletes the selected bookmark after confirmation.
final class BookmarkListPane: NSView {
    var onPick: ((Bookmark) -> Void)?
    var onClose: (() -> Void)?
    /// A bookmark was deleted — e.g. refresh timeline pins behind the pane.
    var onChanged: (() -> Void)?

    private let timeZone: TimeZone
    private let fmt: DateFormatter
    private var filter = ""
    private var selIndex: Int?
    private let panel = NSView()
    private let filterLabel = NSTextField(labelWithString: "")
    private let list = NSStackView()
    private var rowButtons: [NSButton] = []      // in visible order
    private var visible: [Bookmark] = []
    private static let maxRows = 12

    override var acceptsFirstResponder: Bool { true }

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
        self.fmt = BookmarkStore.rowFormatter(timeZone)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 10
        addSubview(panel)

        let title = NSTextField(labelWithString: "Bookmarks")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white

        filterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        filterLabel.textColor = NSColor(white: 0.7, alpha: 1)
        filterLabel.alignment = .center

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4

        let root = NSStackView(views: [title, filterLabel, list])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
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

    private var matching: [Bookmark] {
        let sorted = BookmarkStore.all.sorted { $0.created > $1.created }
        guard !filter.isEmpty else { return sorted }
        return sorted.filter {
            "\($0.cameraName) \($0.label) \(fmt.string(from: $0.time))".lowercased().contains(filter)
        }
    }

    private func rebuild() {
        filterLabel.stringValue = filter.isEmpty
            ? "type to filter · Return jumps · ⌫ deletes · Esc closes"
            : "filter: \(filter)"
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        rowButtons = []

        let all = matching
        visible = Array(all.prefix(Self.maxRows))
        for (i, b) in visible.enumerated() {
            let btn = NSButton(title: "", target: self, action: #selector(rowTapped(_:)))
            btn.tag = i
            btn.isBordered = false
            btn.wantsLayer = true
            btn.alignment = .left
            btn.attributedTitle = rowTitle(b)
            rowButtons.append(btn)
            list.addArrangedSubview(btn)
        }
        if all.isEmpty {
            let l = NSTextField(labelWithString: filter.isEmpty ? "no bookmarks yet — press B in playback" : "no match")
            l.textColor = .secondaryLabelColor
            list.addArrangedSubview(l)
        } else if all.count > visible.count {
            let l = NSTextField(labelWithString: "… \(all.count - visible.count) more — type to narrow")
            l.font = .systemFont(ofSize: 10)
            l.textColor = .secondaryLabelColor
            list.addArrangedSubview(l)
        }
        if let s = selIndex, s >= visible.count { selIndex = visible.isEmpty ? nil : visible.count - 1 }
        updateSelection()
    }

    private func rowTitle(_ b: Bookmark) -> NSAttributedString {
        let s = NSMutableAttributedString(string: " \(b.cameraName)  ", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        s.append(NSAttributedString(string: fmt.string(from: b.time), attributes: [
            .foregroundColor: NSColor(white: 0.7, alpha: 1),
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        ]))
        if !b.label.isEmpty {
            s.append(NSAttributedString(string: "  \(b.label)", attributes: [
                .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.2, alpha: 1),
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]))
        }
        s.append(NSAttributedString(string: " "))
        return s
    }

    /// Same red-border cursor as the grid and the supplementary selector.
    private func updateSelection() {
        for (i, btn) in rowButtons.enumerated() {
            btn.layer?.borderColor = NSColor.systemRed.cgColor
            btn.layer?.borderWidth = (i == selIndex) ? 2 : 0
            btn.layer?.cornerRadius = 5
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !rowButtons.isEmpty else { return }
        let next = (selIndex ?? (delta > 0 ? -1 : 0)) + delta
        selIndex = min(max(0, next), rowButtons.count - 1)
        updateSelection()
    }

    private func confirmDelete(_ b: Bookmark) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete bookmark?"
        var detail = "\(b.cameraName) · \(fmt.string(from: b.time))"
        if !b.label.isEmpty { detail += " · \(b.label)" }
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            if resp == .alertFirstButtonReturn {
                BookmarkStore.remove(id: b.id)
                self.rebuild()
                self.onChanged?()
            }
            self.window?.makeFirstResponder(self)
        }
    }

    // MARK: input

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {                        // esc: clear filter, then close
            cancelOperation(nil)
            return
        }
        switch event.specialKey {
        case .upArrow?, .leftArrow?: moveSelection(-1); return
        case .downArrow?, .rightArrow?: moveSelection(1); return
        default: break
        }
        if event.keyCode == 117 {                       // ⌦ always deletes the selection
            if let s = selIndex, s < visible.count { confirmDelete(visible[s]) }
            return
        }
        if event.keyCode == 51 {                        // ⌫: filter editing wins over delete
            if !filter.isEmpty {
                filter.removeLast()
                selIndex = nil
                rebuild()
            } else if let s = selIndex, s < visible.count {
                confirmDelete(visible[s])
            }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // return: selection, else top row
            if let s = selIndex, s < visible.count { onPick?(visible[s]) }
            else if let first = visible.first { onPick?(first) }
            return
        }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let c = chars.lowercased()
        let scalar = c.unicodeScalars.first!
        if CharacterSet.alphanumerics.contains(scalar) || c == " " || c == "-" || c == ":" || c == "." {
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

    @objc private func rowTapped(_ sender: NSButton) {
        guard sender.tag < visible.count else { return }
        onPick?(visible[sender.tag])
    }
}
