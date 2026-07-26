// EventSelector.swift — the E dialog in playback: a centered panel (styled
// after SupplementarySelector) choosing which event bands the timeline
// highlights — none, motion (with the human/vehicle refinement toggles), or
// intrusion. Transactional: ←→ move, ↑↓ switch rows, Space flips a toggle,
// Return applies everything and dismisses, Esc or a click outside cancels.
// Clicking a band cell applies immediately (with the pending toggles).

import AppKit

/// Which event type the playback timeline highlights.
enum PlaybackEventBand: String {
    case none, motion, intrusion

    var color: NSColor {
        switch self {
        case .none: return NSColor(white: 1, alpha: 0.4)
        case .motion: return TimelineStrip.motionColor
        case .intrusion: return TimelineStrip.intrusionColor
        }
    }
}

final class EventSelector: NSView {
    var onApply: ((PlaybackEventBand, _ human: Bool, _ vehicle: Bool) -> Void)?
    var onDismiss: (() -> Void)?
    /// A pending human/vehicle flip while the dialog is open — the controller
    /// re-resolves the motion count and pushes it back via setMotionCount.
    var onPendingChange: (() -> Void)?

    private(set) var pendingHuman: Bool
    private(set) var pendingVehicle: Bool

    private static let bands: [PlaybackEventBand] = [.none, .motion, .intrusion]
    private let currentBand: PlaybackEventBand
    private var bandCursor: Int                 // column in the band row
    private var cursorOnFilters = false         // cursor row: bands / filters
    private var filterCursor = 0                // 0 = human, 1 = vehicle
    private var motionCount: Int?               // nil = still fetching
    private var intrusionCount: Int?

    private let panel = NSView()
    private var bandButtons: [NSButton] = []
    private var filterButtons: [NSButton] = []
    private let filterRow = NSStackView()

    override var acceptsFirstResponder: Bool { true }

    init(current: PlaybackEventBand, human: Bool, vehicle: Bool) {
        currentBand = current
        pendingHuman = human
        pendingVehicle = vehicle
        bandCursor = Self.bands.firstIndex(of: current) ?? 1
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        panel.layer?.cornerRadius = 10
        addSubview(panel)

        let title = NSTextField(labelWithString: "Timeline events")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white

        let bandRow = NSStackView()
        bandRow.spacing = 8
        for i in Self.bands.indices {
            let b = chipButton(tag: i, action: #selector(bandTapped(_:)))
            bandButtons.append(b)
            bandRow.addArrangedSubview(b)
        }

        filterRow.spacing = 8
        for (i, (symbol, label)) in [("figure.walk", "Human"), ("car.fill", "Vehicle")].enumerated() {
            let b = chipButton(tag: i, action: #selector(filterTapped(_:)))
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            b.imagePosition = .imageLeading
            filterButtons.append(b)
            filterRow.addArrangedSubview(b)
        }

        let hint = NSTextField(labelWithString: "←→ move · ↑↓ row · space toggle · ↵ apply · esc")
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = NSColor(white: 0.55, alpha: 1)

        let root = NSStackView(views: [title, bandRow, filterRow, hint])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
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
        render()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private func chipButton(tag: Int, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.tag = tag
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    /// Counts arrive asynchronously (nil while the fetch is in flight — the
    /// label then shows no number rather than a stale one).
    func setMotionCount(_ n: Int?) { motionCount = n; render() }
    func setIntrusionCount(_ n: Int?) { intrusionCount = n; render() }

    private func render() {
        for (i, b) in bandButtons.enumerated() {
            let band = Self.bands[i]
            var label: String
            switch band {
            case .none: label = "None"
            case .motion: label = "Motion" + (motionCount.map { " (\($0))" } ?? "")
            case .intrusion: label = "Intrusion" + (intrusionCount.map { " (\($0))" } ?? "")
            }
            let active = band == currentBand
            b.attributedTitle = NSAttributedString(string: "  \(label)  ", attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(active ? 1 : 0.75),
                .font: NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .medium),
            ])
            // Active band = filled chip in its color (calendar-selected style);
            // the keyboard cursor = red ring on top, grid-cursor style.
            b.layer?.backgroundColor = active
                ? band.color.withAlphaComponent(0.35).cgColor
                : NSColor(white: 1, alpha: 0.08).cgColor
            let cursored = !cursorOnFilters && i == bandCursor
            b.layer?.borderColor = cursored ? NSColor.systemRed.cgColor : band.color.cgColor
            b.layer?.borderWidth = cursored ? 2 : (active ? 1.5 : 0)
        }

        // Filters refine motion only: dimmed and inert unless Motion is the
        // cursored band (keeps the panel from resizing under the cursor).
        let motionCursored = cursorOnFilters || Self.bands[bandCursor] == .motion
        filterRow.alphaValue = motionCursored ? 1 : 0.35
        for (i, b) in filterButtons.enumerated() {
            let on = i == 0 ? pendingHuman : pendingVehicle
            b.isEnabled = motionCursored
            b.attributedTitle = NSAttributedString(string: " \(i == 0 ? "Human" : "Vehicle") ", attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(on ? 1 : 0.55),
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ])
            b.contentTintColor = on ? TimelineStrip.motionColor : NSColor(white: 1, alpha: 0.4)
            b.layer?.backgroundColor = on
                ? TimelineStrip.motionColor.withAlphaComponent(0.25).cgColor
                : NSColor(white: 1, alpha: 0.06).cgColor
            let cursored = cursorOnFilters && i == filterCursor
            b.layer?.borderColor = NSColor.systemRed.cgColor
            b.layer?.borderWidth = cursored ? 2 : 0
        }
    }

    private func apply() {
        onApply?(Self.bands[bandCursor], pendingHuman, pendingVehicle)
        onDismiss?()
    }

    private func toggleFilter(_ index: Int) {
        if index == 0 { pendingHuman.toggle() } else { pendingVehicle.toggle() }
        render()
        onPendingChange?()
    }

    // MARK: input

    @objc private func bandTapped(_ sender: NSButton) {
        bandCursor = sender.tag
        cursorOnFilters = false
        apply()
    }

    @objc private func filterTapped(_ sender: NSButton) {
        toggleFilter(sender.tag)
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the dimmed backdrop (outside the panel) cancels.
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) {
            onDismiss?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismiss?(); return }        // esc
        switch event.specialKey {
        case .leftArrow: move(-1); return
        case .rightArrow: move(1); return
        case .downArrow:
            if !cursorOnFilters, Self.bands[bandCursor] == .motion {
                cursorOnFilters = true
                render()
            }
            return
        case .upArrow:
            if cursorOnFilters {
                cursorOnFilters = false
                render()
            }
            return
        case .carriageReturn, .enter: apply(); return
        default: break
        }
        if event.charactersIgnoringModifiers == " " {
            if cursorOnFilters { toggleFilter(filterCursor) }
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "e" {   // E again closes
            onDismiss?()
            return
        }
        // Swallow everything else: playback shortcuts stay out while the
        // dialog holds focus, and nothing falls through to beep.
    }

    private func move(_ delta: Int) {
        if cursorOnFilters {
            filterCursor = min(max(0, filterCursor + delta), filterButtons.count - 1)
        } else {
            bandCursor = min(max(0, bandCursor + delta), Self.bands.count - 1)
        }
        render()
    }
}
