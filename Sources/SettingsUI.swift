// SettingsUI.swift — the Settings window (camera list + NVR) and the
// per-camera edit sheet.

import AppKit

/// A camera plus its (staged, not-yet-saved) password.
struct StagedCam { var cam: Camera; var pass: String }

/// Modal editor for one camera, shown as a sheet over the settings window.
final class CameraEditController: NSWindowController {
    private let nameField = NSTextField(string: "")
    private let hostField = NSTextField(string: "")
    private let userField = NSTextField(string: "")
    private let passField = NSSecureTextField(string: "")
    private let portField = NSTextField(string: "")
    private let codecPopup = NSPopUpButton()
    private var completion: ((StagedCam) -> Void)?

    init() {
        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Camera"
        super.init(window: win)

        codecPopup.addItems(withTitles: [VideoCodec.hevc.display, VideoCodec.h264.display])
        for f in [nameField, hostField, userField, passField, portField] {
            f.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), nameField],
            [NSTextField(labelWithString: "Host / IP:"), hostField],
            [NSTextField(labelWithString: "Username:"), userField],
            [NSTextField(labelWithString: "Password:"), passField],
            [NSTextField(labelWithString: "RTSP port:"), portField],
            [NSTextField(labelWithString: "Codec:"), codecPopup],
        ])
        form.rowSpacing = 10
        form.column(at: 0).xPlacement = .trailing

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(okTapped))
        ok.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, ok])

        let stack = NSStackView(views: [form, actions])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = win.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func present(on parent: NSWindow, editing staged: StagedCam?, completion: @escaping (StagedCam) -> Void) {
        self.completion = completion
        let c = staged?.cam
        nameField.stringValue = c?.name ?? ""
        hostField.stringValue = c?.host ?? ""
        userField.stringValue = c?.user ?? "admin"
        passField.stringValue = staged?.pass ?? ""
        portField.stringValue = String(c?.port ?? 554)
        codecPopup.selectItem(at: (c?.codec ?? .hevc) == .h264 ? 1 : 0)
        parent.beginSheet(window!)
    }

    @objc private func cancelTapped() { endSheet() }

    @objc private func okTapped() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let pass = passField.stringValue
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        guard !host.isEmpty, !user.isEmpty, !pass.isEmpty, (1...65535).contains(port) else {
            NSSound.beep(); return
        }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = host }
        let codec: VideoCodec = codecPopup.indexOfSelectedItem == 1 ? .h264 : .hevc
        completion?(StagedCam(cam: Camera(host: host, name: name, user: user, port: port, codec: codec), pass: pass))
        endSheet()
    }

    private func endSheet() {
        if let w = window, let parent = w.sheetParent { parent.endSheet(w) }
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var cams: [StagedCam] = []      // staged edits; committed on Save
    private let editor = CameraEditController()
    private let nvrHostField = NSTextField(string: "")
    private let nvrUserField = NSTextField(string: "")
    private let nvrPassField = NSSecureTextField(string: "")
    var onSave: (() -> Void)?

    init() {
        let win = NSWindow(contentRect: .zero,
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Camera Settings"
        win.isReleasedWhenClosed = false
        super.init(window: win)

        let columns: [(String, String, CGFloat)] = [
            ("name", "Name", 150), ("host", "Host / IP", 120),
            ("user", "User", 90), ("port", "Port", 48), ("codec", "Codec", 66),
        ]
        for (id, title, w) in columns {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title; col.width = w
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(editCamera)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "+", target: self, action: #selector(addCamera))
        let remove = NSButton(title: "−", target: self, action: #selector(removeCamera))
        for b in [add, remove] {
            b.bezelStyle = .smallSquare
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        let edit = NSButton(title: "Edit…", target: self, action: #selector(editCamera))
        let tableButtons = NSStackView(views: [add, remove, edit])
        tableButtons.spacing = 6

        // NVR (recordings live there; playback-only, optional).
        nvrHostField.placeholderString = "host / IP"
        nvrUserField.placeholderString = "user"
        nvrPassField.placeholderString = "password"
        nvrHostField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        nvrUserField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        nvrPassField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let nvrRow = NSStackView(views: [
            NSTextField(labelWithString: "NVR (for playback):"),
            nvrHostField, nvrUserField, nvrPassField,
        ])
        nvrRow.spacing = 6

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, save])

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Cameras — each has its own username, password, port, and codec (double-click to edit)"),
            scroll,
            tableButtons,
            nvrRow,
            actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = win.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.heightAnchor.constraint(equalToConstant: 300),
            scroll.widthAnchor.constraint(equalToConstant: 480),
            actions.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        cams = Settings.stored.map {
            StagedCam(cam: Camera(host: $0.host, name: $0.name, user: $0.user, port: $0.port,
                                  codec: VideoCodec(rawValue: $0.codec) ?? .hevc),
                      pass: $0.password)
        }
        nvrHostField.stringValue = Settings.nvr?.host ?? ""
        nvrUserField.stringValue = Settings.nvr?.user ?? "admin"
        nvrPassField.stringValue = Settings.nvr?.password ?? ""
        table.reloadData()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: cameras table (view-based, read-only rows; editing via the sheet)

    func numberOfRows(in tableView: NSTableView) -> Int { cams.count }

    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let c = cams[row].cam
        let text: String
        switch column.identifier.rawValue {
        case "name": text = c.name
        case "host": text = c.host
        case "user": text = c.user
        case "port": text = String(c.port)
        case "codec": text = c.codec.display
        default: text = ""
        }
        let cell = (t.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = column.identifier
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        cell.stringValue = text
        return cell
    }

    @objc private func addCamera() {
        editor.present(on: window!, editing: nil) { [weak self] staged in
            self?.cams.append(staged)
            self?.table.reloadData()
        }
    }

    @objc private func editCamera() {
        let row = table.selectedRow
        guard row >= 0, row < cams.count else { NSSound.beep(); return }
        editor.present(on: window!, editing: cams[row]) { [weak self] staged in
            self?.cams[row] = staged
            self?.table.reloadData()
        }
    }

    @objc private func removeCamera() {
        let row = table.selectedRow
        guard row >= 0, row < cams.count else { NSSound.beep(); return }
        cams.remove(at: row)
        table.reloadData()
    }

    @objc private func cancelTapped() { window?.close() }

    @objc private func saveTapped() {
        guard !cams.isEmpty else { NSSound.beep(); return }
        let nvrHost = nvrHostField.stringValue.trimmingCharacters(in: .whitespaces)
        let nvrUser = nvrUserField.stringValue.trimmingCharacters(in: .whitespaces)
        let nvr: StoredNVR? = nvrHost.isEmpty ? nil : StoredNVR(
            host: nvrHost,
            user: nvrUser.isEmpty ? "admin" : nvrUser,
            password: nvrPassField.stringValue,
            port: Settings.nvr?.port)   // RTSP port isn't in the UI; keep any hand-set value
        Settings.save(cameras: cams.map {
            StoredCamera(host: $0.cam.host, name: $0.cam.name, user: $0.cam.user,
                         port: $0.cam.port, codec: $0.cam.codec.rawValue, password: $0.pass)
        }, nvr: nvr)
        window?.close()
        onSave?()
    }
}
