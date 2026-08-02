// EventListPane.swift — the Shift-E centralized intrusion review: one pane
// listing a whole day's intrusion events across every camera (from the same
// all-channel alarm-log crawl the playback timeline uses), newest first.
// Selector-style: type to filter, ↑↓ move the red cursor, ←→ step days,
// Return jumps into that camera's playback at the event with the intrusion
// band up. Events carry a seen marker — jumping to one marks it, ⌫/⌦ toggles
// it in place — so reviewed events dim and the new ones stand out.

import AppKit

/// Which intrusion events have been reviewed. Keys are "channel|startEpoch" —
/// stable across fetches (span starts come from the NVR's
/// fieldDetectionStart log entries). Same shape as BookmarkStore: local UI
/// state, no credentials, not part of export/import.
enum SeenEventStore {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("hikviewer/seen-events.json")
    }()

    private(set) static var keys: Set<String> = load()

    private static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        // Prune events older than 90 days (long past NVR retention) so the
        // file doesn't grow forever — the key's tail is the event epoch.
        let cutoff = Date().addingTimeInterval(-90 * 86400).timeIntervalSince1970
        return Set(list.filter { key in
            guard let epoch = key.split(separator: "|").last.flatMap({ Double($0) }) else { return false }
            return epoch > cutoff
        })
    }

    static func markSeen(_ key: String) {
        guard keys.insert(key).inserted else { return }
        persist()
    }

    static func toggle(_ key: String) {
        if keys.remove(key) == nil { keys.insert(key) }
        persist()
    }

    private static func persist() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(keys)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

final class EventListPane: NSView {
    struct Row {
        let cameraName: String
        let host: String?          // nil: the channel has no configured camera
        let channel: Int
        let start: Date
        let end: Date
        var key: String { "\(channel)|\(Int(start.timeIntervalSince1970))" }
    }

    var onPick: ((Row) -> Void)?
    var onClose: (() -> Void)?
    /// Fetch one day's rows [from, to). May deliver twice: cached, then fresh.
    var loadDay: ((_ from: Date, _ to: Date, _ deliver: @escaping ([Row]) -> Void) -> Void)?

    /// Start of the displayed day (NVR tz) — read back at close so the next
    /// open resumes here.
    private(set) var day: Date?
    /// The cursored event — read back at close so the next open re-selects it.
    var selectedKey: String? {
        if let s = selIndex, s < visible.count { return visible[s].key }
        return pendingSelectKey
    }

    private var cal = Calendar(identifier: .gregorian)
    private let dayFmt = DateFormatter()
    private let timeFmt = DateFormatter()
    private var rows: [Row] = []
    private var visible: [Row] = []
    /// Read back at close so the next open restores it (with day + selection).
    private(set) var filter = ""
    private var selIndex: Int?
    private var pendingSelectKey: String?    // selection carried across reopen
    private var loading = false
    private var message: String? = "connecting to NVR…"
    private var token = 0                    // drops stale day loads

    /// Top-origin stack so the scroll view shows the newest rows first
    /// instead of opening scrolled to the bottom.
    private final class FlippedStackView: NSStackView {
        override var isFlipped: Bool { true }
    }

    private let panel = NSView()
    private let titleLabel = NSTextField(labelWithString: "Intrusion")
    private let infoLabel = NSTextField(labelWithString: "")
    private let list = FlippedStackView()
    private let scroll = NSScrollView()
    private var scrollWidth: NSLayoutConstraint!
    private var scrollHeight: NSLayoutConstraint!
    private var rowButtons: [NSButton] = []
    /// Viewport cap (~12 rows) — beyond it the list scrolls (arrows follow).
    private static let maxListHeight: CGFloat = 300

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 10
        addSubview(panel)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white

        infoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        infoLabel.textColor = NSColor(white: 0.7, alpha: 1)
        infoLabel.alignment = .center

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scrollWidth = scroll.widthAnchor.constraint(equalToConstant: 200)
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([scrollWidth, scrollHeight])

        let hint = NSTextField(labelWithString: "↵ open · ⌫ seen · ←→ day · ⇧T today · type to filter (-x, -\"a b\" exclude) · esc")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = NSColor(white: 0.55, alpha: 1)

        let root = NSStackView(views: [titleLabel, infoLabel, scroll, hint])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
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

    /// The NVR is prepared: adopt its timezone, open on the remembered (or
    /// today's) day, and restore the remembered selection.
    func ready(timeZone: TimeZone, openAt: Date?, selectKey: String?, filter savedFilter: String = "") {
        filter = savedFilter
        cal.timeZone = timeZone
        for (f, fmt) in [(dayFmt, "EEE yyyy-MM-dd"), (timeFmt, "h:mm:ss a")] {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            f.timeZone = timeZone
        }
        let today = cal.startOfDay(for: Date())
        day = min(openAt ?? today, today)
        pendingSelectKey = selectKey
        loadCurrentDay()
    }

    func fail(_ msg: String) {
        loading = false
        message = msg
        rebuild()
    }

    private func loadCurrentDay() {
        guard let day, let end = cal.date(byAdding: .day, value: 1, to: day) else { return }
        token += 1
        let t = token
        rows = []
        message = nil
        loading = true
        rebuild()
        loadDay?(day, end) { [weak self] delivered in
            guard let self, self.token == t else { return }
            self.loading = false
            self.rows = delivered.sorted { $0.start > $1.start }
            self.rebuild()
            self.prefetchNeighbors()
        }
    }

    /// Warm the adjacent days once the shown day has landed: all LAN-local,
    /// and the client caches per day (sharing any in-flight crawl), so ←/→
    /// stepping is instant and a continuous walk stays one day ahead.
    private func prefetchNeighbors() {
        guard let day else { return }
        let today = cal.startOfDay(for: Date())
        for delta in [-1, 1] {
            guard let d = cal.date(byAdding: .day, value: delta, to: day), d <= today,
                  let end = cal.date(byAdding: .day, value: 1, to: d) else { continue }
            loadDay?(d, end) { _ in }
        }
    }

    private func showDay(_ target: Date) {
        guard target != day else { return }
        day = target
        selIndex = nil
        pendingSelectKey = nil
        loadCurrentDay()
    }

    private func stepDay(_ delta: Int) {
        guard let cur = day, let next = cal.date(byAdding: .day, value: delta, to: cur) else { return }
        showDay(min(next, cal.startOfDay(for: Date())))    // never into the future
    }

    private func jumpToToday() {
        guard day != nil else { return }                   // not ready yet
        showDay(cal.startOfDay(for: Date()))
    }

    // MARK: rendering

    /// Filter → (include, exclude) terms. Space-separated terms must all
    /// match; a "-" prefix excludes instead ("porch -outside"). Double quotes
    /// group words into one exact phrase — "front door", -"outside right" —
    /// so an exclusion is provably that term, not two loose words. A bare "-"
    /// is inert, and an unclosed quote runs to the end of the filter (the
    /// phrase just narrows live as it's typed).
    static func parseFilter(_ filter: String) -> (include: [String], exclude: [String]) {
        var include: [String] = [], exclude: [String] = []
        var i = filter.startIndex
        while i < filter.endIndex {
            if filter[i] == " " { i = filter.index(after: i); continue }
            var negated = false
            if filter[i] == "-" {
                negated = true
                i = filter.index(after: i)
            }
            var term = ""
            if i < filter.endIndex, filter[i] == "\"" {
                i = filter.index(after: i)
                while i < filter.endIndex, filter[i] != "\"" {
                    term.append(filter[i])
                    i = filter.index(after: i)
                }
                if i < filter.endIndex { i = filter.index(after: i) }   // closing quote
            } else {
                while i < filter.endIndex, filter[i] != " " {
                    term.append(filter[i])
                    i = filter.index(after: i)
                }
            }
            guard !term.isEmpty else { continue }
            if negated { exclude.append(term) } else { include.append(term) }
        }
        return (include, exclude)
    }

    private var matching: [Row] {
        let (include, exclude) = Self.parseFilter(filter)
        guard !include.isEmpty || !exclude.isEmpty else { return rows }
        return rows.filter { r in
            let hay = "\(r.cameraName) \(timeFmt.string(from: r.start))".lowercased()
            if exclude.contains(where: { hay.contains($0) }) { return false }
            return include.allSatisfy { hay.contains($0) }
        }
    }

    private func rebuild() {
        titleLabel.stringValue = day.map { "Intrusion — \(dayFmt.string(from: $0))" } ?? "Intrusion"
        if !filter.isEmpty {
            infoLabel.stringValue = "filter: \(filter)"
        } else if loading {
            infoLabel.stringValue = "loading events…"
        } else if message != nil || rows.isEmpty {
            infoLabel.stringValue = ""
        } else {
            let unseen = rows.filter { !SeenEventStore.keys.contains($0.key) }.count
            let events = "\(rows.count) event\(rows.count == 1 ? "" : "s")"
            infoLabel.stringValue = unseen > 0 ? "\(events) · \(unseen) unseen" : "\(events) · all seen"
        }
        infoLabel.isHidden = infoLabel.stringValue.isEmpty

        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        rowButtons = []

        visible = matching
        for (i, r) in visible.enumerated() {
            let btn = NSButton(title: "", target: self, action: #selector(rowTapped(_:)))
            btn.tag = i
            btn.isBordered = false
            btn.wantsLayer = true
            btn.alignment = .left
            btn.attributedTitle = rowTitle(r)
            rowButtons.append(btn)
            list.addArrangedSubview(btn)
        }
        if let msg = message {
            let l = NSTextField(labelWithString: msg)
            l.textColor = .secondaryLabelColor
            list.addArrangedSubview(l)
        } else if visible.isEmpty, !loading {
            let l = NSTextField(labelWithString: filter.isEmpty ? "no intrusion events this day" : "no match")
            l.textColor = .secondaryLabelColor
            list.addArrangedSubview(l)
        }
        if selIndex == nil, let k = pendingSelectKey,
           let i = visible.firstIndex(where: { $0.key == k }) {
            selIndex = i
        }
        if let s = selIndex, s >= visible.count { selIndex = visible.isEmpty ? nil : visible.count - 1 }
        updateSelection()

        // Size the viewport to the content, capped — the scroller takes over
        // beyond the cap (arrows keep the cursor in view; wheel/trackpad work).
        let size = list.fittingSize
        scrollWidth.constant = max(size.width, 200)
        scrollHeight.constant = max(min(size.height, Self.maxListHeight), 20)
        if selIndex != nil { scrollSelectionIntoView() }
        else { scroll.contentView.scroll(to: .zero) }   // flipped: zero = top
    }

    private func scrollSelectionIntoView() {
        guard let s = selIndex, s < rowButtons.count else { return }
        layoutSubtreeIfNeeded()
        rowButtons[s].scrollToVisible(rowButtons[s].bounds)
    }

    /// Unseen: intrusion-orange dot, full brightness. Seen: dot fades to a
    /// placeholder (alignment holds) and the text dims.
    private func rowTitle(_ r: Row) -> NSAttributedString {
        let seen = SeenEventStore.keys.contains(r.key)
        let s = NSMutableAttributedString(string: " ● ", attributes: [
            .foregroundColor: seen ? NSColor(white: 1, alpha: 0.12) : TimelineStrip.intrusionColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
        ])
        s.append(NSAttributedString(string: "\(r.cameraName)  ", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(seen ? 0.45 : 1),
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ]))
        s.append(NSAttributedString(string: timeFmt.string(from: r.start), attributes: [
            .foregroundColor: NSColor(white: 1, alpha: seen ? 0.35 : 0.7),
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        ]))
        s.append(NSAttributedString(string: "  \(Self.durationText(r.end.timeIntervalSince(r.start))) ", attributes: [
            .foregroundColor: NSColor(white: 1, alpha: seen ? 0.3 : 0.55),
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ]))
        return s
    }

    static func durationText(_ s: TimeInterval) -> String {
        let sec = max(1, Int(s.rounded()))
        if sec < 60 { return "\(sec)s" }
        let m = sec / 60
        if m < 60 { return String(format: "%dm %02ds", m, sec % 60) }
        return String(format: "%dh %02dm", m / 60, m % 60)
    }

    /// Same red-border cursor as the grid and the bookmark list.
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
        pendingSelectKey = nil
        updateSelection()
        scrollSelectionIntoView()
    }

    /// ⌫/⌦: flip the cursored event's seen mark without watching it —
    /// dismissing the trivial ones keeps the unseen count honest.
    private func toggleSeen() {
        guard let s = selIndex, s < visible.count else { return }
        SeenEventStore.toggle(visible[s].key)
        rebuild()
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
        case .upArrow?: moveSelection(-1); return
        case .downArrow?: moveSelection(1); return
        case .leftArrow?: stepDay(-1); return
        case .rightArrow?: stepDay(1); return
        default: break
        }
        if event.keyCode == 117 {                       // ⌦ always toggles seen
            toggleSeen()
            return
        }
        if event.keyCode == 51 {                        // ⌫: filter editing wins
            if !filter.isEmpty {
                filter.removeLast()
                selIndex = nil
                rebuild()
            } else {
                toggleSeen()
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
        // Shifted letters never reach the filter (it matches lowercased), so
        // they are free to be commands: ⇧T = today, ⇧E = the toggle that
        // opened the pane closes it. Shifted punctuation (the quote is ⇧')
        // falls through to the filter.
        if event.modifierFlags.contains(.shift) {
            if c == "t" { jumpToToday(); return }
            if c == "e" { onClose?(); return }
            if let sc = c.unicodeScalars.first, CharacterSet.alphanumerics.contains(sc) { return }
        }
        let scalar = c.unicodeScalars.first!
        if CharacterSet.alphanumerics.contains(scalar) || c == " " || c == "-" || c == ":" || c == "." || c == "\"" {
            filter += c
            selIndex = nil
            pendingSelectKey = nil
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
