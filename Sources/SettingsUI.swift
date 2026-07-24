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
    private let nameDetect = NSButton()
    private let codecDetect = NSButton()
    private let nameSpinner = NSProgressIndicator()
    private let codecSpinner = NSProgressIndicator()
    private var completion: ((StagedCam) -> Void)?

    init() {
        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Camera"
        super.init(window: win)

        codecPopup.addItems(withTitles: [VideoCodec.hevc.display, VideoCodec.h264.display])
        for f in [nameField, hostField, userField, passField, portField] {
            f.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        for b in [nameDetect, codecDetect] {
            b.title = "Detect"
            b.bezelStyle = .rounded
            b.target = self
        }
        nameDetect.action = #selector(detectName)
        codecDetect.action = #selector(detectCodec)
        for s in [nameSpinner, codecSpinner] {
            s.style = .spinning
            s.controlSize = .small
            s.isDisplayedWhenStopped = false
        }
        let divider = NSBox()
        divider.boxType = .separator
        let nameRow = NSStackView(views: [nameField, nameDetect, nameSpinner])
        let codecRow = NSStackView(views: [codecPopup, codecDetect, codecSpinner])

        // Connection fields first, then a divider, then the two fields the
        // Detect buttons can fill from the camera itself.
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Host / IP:"), hostField],
            [NSTextField(labelWithString: "Username:"), userField],
            [NSTextField(labelWithString: "Password:"), passField],
            [NSTextField(labelWithString: "RTSP port:"), portField],
            [divider],
            [NSTextField(labelWithString: "Name:"), nameRow],
            [NSTextField(labelWithString: "Codec:"), codecRow],
        ])
        form.rowSpacing = 10
        form.column(at: 0).xPlacement = .trailing
        form.row(at: 4).mergeCells(in: NSRange(location: 0, length: 2))
        form.cell(for: divider)?.xPlacement = .fill

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
        userField.stringValue = c?.user ?? ""
        passField.stringValue = staged?.pass ?? ""
        portField.stringValue = String(c?.port ?? 554)
        codecPopup.selectItem(at: (c?.codec ?? .hevc) == .h264 ? 1 : 0)
        parent.beginSheet(window!)
    }

    @objc private func cancelTapped() { endSheet() }

    @objc private func detectName() { detect(into: .name) }
    @objc private func detectCodec() { detect(into: .codec) }

    private enum DetectField { case name, codec }

    /// One read-only ISAPI GET with the staged credentials; fills only the
    /// field whose button was pressed — pressing it is the consent to
    /// overwrite.
    private func detect(into target: DetectField) {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let pass = passField.stringValue
        guard !host.isEmpty, !user.isEmpty, !pass.isEmpty else {
            flash("Enter host and credentials first"); return
        }
        let spinner = target == .name ? nameSpinner : codecSpinner
        nameDetect.isEnabled = false
        codecDetect.isEnabled = false
        spinner.startAnimation(nil)
        ISAPI.detectChannel(host: host, user: user, password: pass) { [weak self] name, codec in
            guard let self else { return }
            self.nameDetect.isEnabled = true
            self.codecDetect.isEnabled = true
            spinner.stopAnimation(nil)
            switch target {
            case .name:
                guard let name, !name.isEmpty else {
                    self.flash("Couldn't detect name — check host/credentials"); return
                }
                self.nameField.stringValue = name
                self.flash("Detected: \(name)")
            case .codec:
                guard let codec else {
                    self.flash("Couldn't detect codec — check host/credentials"); return
                }
                self.codecPopup.selectItem(at: codec == .h264 ? 1 : 0)
                self.flash("Detected: \(codec.display)")
            }
        }
    }

    private func flash(_ text: String) {
        if let v = window?.contentView { HUDView.flash(text, in: v) }
    }

    @objc private func okTapped() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let pass = passField.stringValue
        let port = Int(portField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        guard !host.isEmpty, !user.isEmpty, !pass.isEmpty, (1...65535).contains(port) else {
            flash("Host, user, password and port are required")
            return
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
    private let fullScreenCheck = NSButton(checkboxWithTitle: "Always start in full screen", target: nil, action: nil)
    private let rememberCheck = NSButton(checkboxWithTitle: "Remember where I left off (open view, playback position)", target: nil, action: nil)
    private let smoothCheck = NSButton(checkboxWithTitle: "Smooth live video (buffers ~0.2 s to absorb Wi-Fi jitter)", target: nil, action: nil)
    var onSave: (() -> Void)?

    private func flashHUD(_ text: String) {
        if let v = window?.contentView { HUDView.flash(text, in: v) }
    }

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
            fullScreenCheck,
            rememberCheck,
            smoothCheck,
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
        fullScreenCheck.state = Settings.startFullScreen ? .on : .off
        rememberCheck.state = Settings.rememberLastView ? .on : .off
        smoothCheck.state = Settings.smoothLive ? .on : .off
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
        guard row >= 0, row < cams.count else { flashHUD("Select a camera first"); return }
        editor.present(on: window!, editing: cams[row]) { [weak self] staged in
            self?.cams[row] = staged
            self?.table.reloadData()
        }
    }

    @objc private func removeCamera() {
        let row = table.selectedRow
        guard row >= 0, row < cams.count else { flashHUD("Select a camera first"); return }
        cams.remove(at: row)
        table.reloadData()
    }

    @objc private func cancelTapped() { window?.close() }

    @objc private func saveTapped() {
        guard !cams.isEmpty else { flashHUD("Add at least one camera"); return }
        Settings.startFullScreen = fullScreenCheck.state == .on
        Settings.rememberLastView = rememberCheck.state == .on
        Settings.smoothLive = smoothCheck.state == .on
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
