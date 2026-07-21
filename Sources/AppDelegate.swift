// AppDelegate.swift — app lifecycle: builds the grid, wires tiles to streams,
// focus/playback switching, config export/import.

import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let grid = GridView()
    let settings = SettingsWindowController()
    let emptyLabel = NSTextField(labelWithString: "No cameras or credentials — press ⌘, to open Settings")
    var streams: [CameraStream] = []
    /// Extra pipe on the 4K main stream for the currently focused camera.
    var mainStream: CameraStream?
    /// Recorded-footage playback on the focused tile (P to enter).
    var playback: PlaybackController?
    var nvrClient: NVRClient?
    /// Floating supplementary panes on the focused view (+ to add).
    let supp = SupplementaryManager()
    /// Set while showing a camera opened from a supplementary pane; back
    /// returns to this origin view with its panes restored.
    private var promotedOrigin: (index: Int, wasPlayback: Bool, position: Date?)?
    private var selector: SupplementarySelector?
    private var helpView: ShortcutHelpView?
    private var bookmarkPrompt: BookmarkNamePrompt?
    private var bookmarkPane: BookmarkListPane?
    /// In-flight clip recording (R); at most one, tied to the camera it
    /// started on — leaving that camera stops it.
    private var recorder: ClipRecorder?
    private var recTimer: Timer?
    private weak var recTile: TileView?
    private var recHost: String?
    /// Suggested filename for the in-flight recording; a quit mid-recording
    /// auto-saves under it (no panel can be shown while terminating).
    private var recDefaultName: String?
    /// Host of the currently focused camera — focusChanged needs to know
    /// which view it is leaving to record that view's state.
    private var focusedHost: String?
    /// Set around focus changes the app makes itself (promote, back,
    /// rebuild): focusChanged then neither records nor restores view state —
    /// the caller manages it.
    private var programmaticNav = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = makeAppIcon()
        if ffmpegPath == nil {
            let a = NSAlert()
            a.messageText = "ffmpeg is required"
            a.informativeText = ffmpegInstallHint
            a.addButton(withTitle: "Quit")
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        grid.onFocusChange = { [weak self] idx in self?.focusChanged(idx) }
        // Keep streams parallel to grid.tiles while a tile is drag-reordered,
        // then write the final order back to config.json.
        grid.onMove = { [weak self] from, to in
            guard let self, from < self.streams.count, to < self.streams.count else { return }
            self.streams.insert(self.streams.remove(at: from), at: to)
        }
        grid.onReorderEnd = { [weak self] in self?.persistOrder() }
        grid.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        // Esc order: leave playback (stay focused) → back to the origin view
        // if this one was opened from a supplementary pane → unfocus.
        grid.onEscape = { [weak self] in
            guard let self else { return false }
            if self.playback != nil {
                self.exitPlayback()
                return true
            }
            if self.promotedOrigin != nil {
                self.goBackFromPromoted()
                return true
            }
            return false
        }
        supp.onPromote = { [weak self] cam in self?.promoteSupplementary(cam) }
        settings.onSave = { [weak self] in self?.rebuildStreams() }

        emptyLabel.textColor = .white
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        grid.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: grid.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: grid.centerYAnchor),
        ])

        let rect = NSRect(x: 0, y: 0, width: 1200, height: 460)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "HikViewer"
        window.appearance = NSAppearance(named: .darkAqua)   // dark title bar over the video grid
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 300)
        window.contentView = grid
        window.setFrameAutosaveName("HikViewer")
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(grid)
        // Skip auto-fullscreen when unconfigured: the Settings window that
        // opens on first run would land behind the fullscreen space.
        if Settings.startFullScreen && Settings.isConfigured { window.toggleFullScreen(nil) }
        NSApp.activate(ignoringOtherApps: true)

        if Settings.isConfigured && !Settings.cameras.isEmpty {
            rebuildStreams()
            restoreSession()
        } else {
            emptyLabel.isHidden = false
            settings.show()
        }

        Updater.checkInBackground()
    }

    @objc func openSettings(_ sender: Any?) { settings.show() }

    @objc func checkForUpdates(_ sender: Any?) { Updater.checkInteractive() }

    /// Export the full config (cameras + NVR, credentials included) to JSON.
    @objc func exportCameras(_ sender: Any?) {
        guard !Settings.stored.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hik-cameras.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Exports every camera (and the NVR) including passwords."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(StoredConfig(cameras: Settings.stored, nvr: Settings.nvr)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Import a config exported by this app (either format), replacing the
    /// current one. An old camera-only export keeps the current NVR.
    @objc func importCameras(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let cfg = Settings.decode(data), !cfg.cameras.isEmpty else {
            let a = NSAlert()
            a.messageText = "Import failed"
            a.informativeText = "That file isn't a valid HikViewer camera export."
            a.runModal()
            return
        }
        Settings.save(cameras: cfg.cameras, nvr: cfg.nvr ?? Settings.nvr)
        settings.show()      // reflect the imported list; user reviews then it's live
        rebuildStreams()
    }

    private func makeStreams() -> [CameraStream] {
        guard let ff = ffmpegPath else { return [] }
        return Settings.cameras.map { cam in
            CameraStream(camera: cam, url: rtspURL(camera: cam, channel: channel),
                         channelId: channel, ffmpegPath: ff)
        }
    }

    /// Tear down every pipe and rebuild the grid from the current Settings.
    /// Called on launch and again whenever Settings are saved.
    func rebuildStreams() {
        stopRecording()
        if let pb = playback { pb.exit(); playback = nil }
        closeSelector()
        closeHelp()
        closeBookmarkUI()
        supp.teardown()
        promotedOrigin = nil
        nvrClient = nil      // pick up NVR credential changes lazily
        // Programmatic: a Settings save shouldn't rewrite the outgoing view's
        // remembered state; quitting later records the grid anyway.
        programmaticNav = true
        grid.focused = nil   // while tiles/streams are still in sync
        programmaticNav = false
        focusedHost = nil
        grid.clearKeyCursor()
        let old = streams
        streams = []
        if !old.isEmpty { DispatchQueue.global().async { old.forEach { $0.stop() } } }
        grid.tiles.forEach { $0.removeFromSuperview() }
        grid.tiles = []
        let ready = Settings.isConfigured && !Settings.cameras.isEmpty
        emptyLabel.isHidden = ready
        guard ready else { return }

        streams = makeStreams()
        for stream in streams {
            let tile = TileView(title: stream.camera.name)
            // Look the index up at click time — reordering shuffles the arrays.
            // Double-click only enters full view; leaving it is Esc's job.
            tile.onDoubleClick = { [weak self, weak tile] in
                guard let self, let tile, !self.grid.isReordering, self.grid.focused == nil,
                      let i = self.grid.tiles.firstIndex(where: { $0 === tile }) else { return }
                self.grid.focused = i
            }
            tile.onLongPress = { [weak self, weak tile] in
                guard let self, let tile else { return false }
                return self.grid.beginDrag(tile)
            }
            tile.onDrag = { [weak self, weak tile] event in
                guard let self, let tile else { return }
                self.grid.updateDrag(tile, with: event)
            }
            tile.onDragEnd = { [weak self, weak tile] in
                guard let self, let tile else { return }
                self.grid.endDrag(tile)
            }
            tile.onZoomChange = { [weak self] in self?.updateBackArrow() }
            tile.onBack = { [weak self] in self?.goBackFromPromoted() }
            // Fan the substream out: the grid tile plus (when this camera is a
            // live supplementary pane on the focused view) the floating pane.
            let sampleHost = stream.camera.host
            stream.onSample = { [weak tile, weak self] sb, sync in
                tile?.enqueue(sb, isSync: sync, from: .sub)
                self?.supp.distributeLive(host: sampleHost, sb, sync)
            }
            stream.onState = { [weak tile] s in tile?.setStatus(s) }
            grid.tiles.append(tile)
            grid.addSubview(tile)
            // Instant: last-known cached frame (marked cached, possibly stale).
            let host = stream.camera.host
            if let cached = SnapshotCache.load(host: host) {
                tile.setPlaceholder(cached, cached: true)
            }
            // Fresh: live snapshot replaces it and refreshes the on-disk cache.
            ISAPI.snapshot(host: host, channel: channel) { [weak tile] data in
                guard let data, let image = NSImage(data: data) else { return }
                SnapshotCache.save(host: host, jpeg: data)
                DispatchQueue.main.async { tile?.setPlaceholder(image, cached: false) }
            }
        }
        grid.needsLayout = true
        streams.forEach { $0.start() }
    }

    /// Write the grid's current tile order back to config.json so it survives
    /// relaunch. Stored entries without a live stream (e.g. empty host) keep
    /// their relative order after the visible ones.
    func persistOrder() {
        var remaining = Settings.stored
        var ordered: [StoredCamera] = []
        for s in streams {
            if let i = remaining.firstIndex(where: { $0.host == s.camera.host }) {
                ordered.append(remaining.remove(at: i))
            }
        }
        Settings.save(cameras: ordered + remaining, nvr: Settings.nvr)
    }

    /// Focused tile shows the camera's main stream (4K); the substream keeps
    /// running underneath so the grid — and an unfocus — are instant. The tile
    /// swaps to the main feed on its first (key)frame, so there's no blank gap.
    func focusChanged(_ idx: Int?) {
        let outgoing = focusedHost
        let host: String? = idx.flatMap { $0 < streams.count ? streams[$0].camera.host : nil }
        focusedHost = host
        // Remember the outgoing view (before its playback/panes are torn
        // down) and where the user is now. Promoted views are excluded: they
        // were recorded as their origin when the pane was promoted.
        if !programmaticNav, promotedOrigin == nil {
            if let out = outgoing { saveViewState(host: out) }
            SessionStore.update {
                $0.location = host == nil ? .grid : .camera
                $0.cameraHost = host
            }
        }
        // A recording follows its camera across live<->playback but not away
        // from it — leaving the camera stops (and opens) the clip.
        if recorder != nil, host != recHost { stopRecording() }
        if let pb = playback { pb.exit(); playback = nil }
        closeSelector()
        closeBookmarkUI()
        // Panes survive playback exits on the same camera; any other focus
        // change tears them down (their layout is saved for restore).
        if supp.attachedHost != host { supp.teardown() }
        if idx == nil { promotedOrigin = nil }
        if let old = mainStream {
            mainStream = nil
            DispatchQueue.global().async { old.stop() }
        }
        defer { updateBackArrow() }
        for (i, t) in grid.tiles.enumerated() where i < streams.count {
            t.setFeed(.sub)
            t.setStatus(streams[i].lastStatus)
            // Zoom is armed only on the focused tile; it persists across
            // live<->playback on the same camera, resets on leaving it.
            t.zoomEnabled = (i == idx)
            if i != idx, t.isZoomed { t.resetZoom() }
        }
        if let i = idx, channel != mainChannel, i < streams.count, let ff = ffmpegPath {
            let cam = streams[i].camera
            let tile = grid.tiles[i]
            let ms = CameraStream(camera: cam, url: rtspURL(camera: cam, channel: mainChannel),
                                  channelId: mainChannel, ffmpegPath: ff)
            ms.onSample = { [weak tile] sb, sync in
                guard let tile else { return }
                tile.setFeed(.main)  // no-op after the first frame
                tile.enqueue(sb, isSync: sync, from: .main)
            }
            ms.onState = { [weak tile] s in tile?.setStatus(s) }
            mainStream = ms
            ms.start()
        }
        restoreViewState(idx: idx, outgoing: outgoing)
    }

    // MARK: remembering where the user left off

    /// Record how `host`'s camera view looks right now. The last playback
    /// position survives a return to live, so P can resume from it.
    private func saveViewState(host: String, position: Date? = nil) {
        let inPlayback = playback != nil
        let pos = inPlayback ? (position ?? playback?.currentPosition)
                             : SessionStore.state.perCamera[host]?.playbackPosition
        let panes = supp.count > 0
        SessionStore.update {
            $0.perCamera[host] = CameraViewState(mode: inPlayback ? .playback : .live,
                                                 playbackPosition: pos, panesVisible: panes)
        }
    }

    /// A camera view just opened fresh (from the grid or at launch): bring
    /// back its panes and, if it was left in playback, the position. Skipped
    /// for same-camera re-entries (leaving playback) and promote/back
    /// navigation, which manage their own state.
    private func restoreViewState(idx: Int?, outgoing: String?) {
        guard !programmaticNav, Settings.rememberLastView, promotedOrigin == nil,
              let i = idx, i < streams.count, i < grid.tiles.count else { return }
        let host = streams[i].camera.host
        guard host != outgoing, let st = SessionStore.state.perCamera[host] else { return }
        if st.panesVisible {
            supp.attach(to: grid.tiles[i], mainHost: host)
            supp.restoreSaved()
        }
        if st.mode == .playback {
            enterPlayback(startAt: st.playbackPosition)
        }
    }

    /// At launch: reopen the grid or the camera view the user quit from.
    /// Never a promoted view — a quit there was recorded as its origin.
    private func restoreSession() {
        guard Settings.rememberLastView else { return }
        let s = SessionStore.state
        guard s.location == .camera, let host = s.cameraHost,
              let idx = streams.firstIndex(where: { $0.camera.host == host }) else { return }
        grid.focused = idx      // focusChanged restores panes/playback
    }

    // MARK: playback (recorded footage from the NVR, on the focused tile)

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.charactersIgnoringModifiers == "?" {
            toggleHelp()
            return true
        }
        // Shift-B: the bookmark pane, from any context. Checked before the
        // playback block so plain B stays "add bookmark" there.
        if e.charactersIgnoringModifiers?.lowercased() == "b", e.modifierFlags.contains(.shift) {
            toggleBookmarkPane()
            return true
        }
        // + on a focused view: add a supplementary pane (selector panel).
        if grid.focused != nil, let ch = e.charactersIgnoringModifiers, ch == "+" || ch == "=" {
            openSupplementarySelector()
            return true
        }
        // - closes panes, most recently added first.
        if grid.focused != nil, let ch = e.charactersIgnoringModifiers, ch == "-" || ch == "_" {
            if supp.count > 0 { supp.removeLastPane() } else { NSSound.beep() }
            return true
        }
        if let pb = playback {
            switch e.specialKey {
            case .leftArrow: pb.step(-arrowSkip(e)); return true
            case .rightArrow: pb.step(arrowSkip(e)); return true
            default: break
            }
            guard let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
            if ch.count == 1, let digit = Int(ch) {   // YouTube-style: 5 → 50% of the day
                pb.jumpToFraction(Double(digit) / 10)
                return true
            }
            switch ch {
            case " ": pb.togglePause(); return true
            case "c": pb.toggleCalendar(); return true
            case "x": pb.cycleSpeed(); return true
            case "s": saveSnapshot(); return true
            case "r": toggleRecording(); return true
            case "b": promptBookmark(pb); return true
            case "n":
                if e.modifierFlags.contains(.shift) { pb.jumpToPreviousMotion() }
                else { pb.jumpToNextMotion() }
                return true
            case "p": exitPlayback(); return true
            default: return false
            }
        }
        if grid.focused != nil, let ch = e.charactersIgnoringModifiers?.lowercased() {
            if ch == "s" { saveSnapshot(); return true }
            if ch == "r" { toggleRecording(); return true }
        }
        if e.charactersIgnoringModifiers?.lowercased() == "p", grid.focused != nil {
            // Resume from the camera's remembered position, not "a minute ago".
            var startAt: Date?
            if Settings.rememberLastView, promotedOrigin == nil,
               let i = grid.focused, i < streams.count {
                startAt = SessionStore.state.perCamera[streams[i].camera.host]?.playbackPosition
            }
            enterPlayback(startAt: startAt)
            return true
        }
        return false
    }

    /// Arrow-key seek size: 10 s, Shift = 60 s, Cmd = 15 min.
    private func arrowSkip(_ e: NSEvent) -> TimeInterval {
        if e.modifierFlags.contains(.command) { return 900 }
        if e.modifierFlags.contains(.shift) { return 60 }
        return 10
    }

    private func enterPlayback(startAt: Date? = nil) {
        guard playback == nil, let i = grid.focused, i < streams.count else { return }
        let cam = streams[i].camera
        let tile = grid.tiles[i]
        guard let nvr = Settings.nvr, !nvr.host.isEmpty else {
            tile.setStatus("no NVR in Settings (⌘,)")
            return
        }
        if nvrClient == nil { nvrClient = NVRClient(nvr: nvr) }
        guard let client = nvrClient else { return }
        tile.setStatus("loading recordings…")
        client.prepare { [weak self] ok in
            guard let self, self.playback == nil, self.grid.focused == i else { return }
            guard ok else { tile.setStatus("NVR unreachable"); return }
            guard let ch = client.channelByHost[cam.host] else {
                tile.setStatus("not recorded on this NVR")
                return
            }
            // Playback replaces the main-stream pipe; the substream keeps
            // running underneath, so Esc back to live is instant.
            if let ms = self.mainStream {
                self.mainStream = nil
                DispatchQueue.global().async { ms.stop() }
            }
            let pb = PlaybackController(camera: cam, track: NVRClient.track(forChannel: ch),
                                        client: client, tile: tile)
            pb.onTransport = { [weak self] pos, speed, paused in
                guard let self else { return }
                // Every play/seek/pause refreshes the remembered position
                // (crash insurance; a clean quit records it exactly).
                if self.promotedOrigin == nil { self.saveViewState(host: cam.host, position: pos) }
                guard let client = self.nvrClient else { return }
                self.supp.playbackTransport(position: pos, speed: speed, paused: paused, client: client)
            }
            self.playback = pb
            self.supp.setBottomInset(44)
            pb.begin(at: startAt ?? Date().addingTimeInterval(-60))   // default: a minute back
            self.updateBackArrow()
        }
    }

    private func exitPlayback() {
        guard let pb = playback else { return }
        pb.exit()
        playback = nil
        supp.switchToLive()
        supp.setBottomInset(0)
        focusChanged(grid.focused)   // restores the main-stream pipe + statuses
    }

    // MARK: supplementary panes (+ to add, double-click to promote)

    private func openSupplementarySelector() {
        guard selector == nil, promotedOrigin == nil, supp.count < 4,
              let i = grid.focused, i < grid.tiles.count, i < streams.count else {
            NSSound.beep()
            return
        }
        let tile = grid.tiles[i]
        let mainHost = streams[i].camera.host
        let added = Set(supp.paneHosts)
        let inPlayback = playback != nil
        let chMap = nvrClient?.channelByHost ?? [:]
        let entries = Settings.cameras.filter { $0.host != mainHost }.map { cam -> SupplementarySelector.Entry in
            if added.contains(cam.host) {
                return .init(camera: cam, enabled: false, note: "added")
            }
            if inPlayback, chMap[cam.host] == nil {
                return .init(camera: cam, enabled: false, note: "no recording")
            }
            return .init(camera: cam, enabled: true, note: nil)
        }
        var restoreNames: [String]?
        if supp.count == 0 {
            let names = LayoutStore.saved(for: mainHost).compactMap { saved in
                Settings.cameras.first { $0.host == saved.host }?.name
            }
            if !names.isEmpty { restoreNames = names }
        }
        let sel = SupplementarySelector(entries: entries, restoreNames: restoreNames)
        sel.onClose = { [weak self] in self?.closeSelector() }
        sel.onPick = { [weak self] cam in
            guard let self else { return }
            self.closeSelector()
            self.supp.attach(to: tile, mainHost: mainHost)
            self.supp.addPane(camera: cam)
            self.replaySuppTransport()
        }
        sel.onRestore = { [weak self] in
            guard let self else { return }
            self.closeSelector()
            self.supp.attach(to: tile, mainHost: mainHost)
            self.supp.restoreSaved()
            self.replaySuppTransport()
        }
        sel.frame = tile.bounds
        sel.autoresizingMask = [.width, .height]
        tile.addSubview(sel)
        selector = sel
        window.makeFirstResponder(sel)
    }

    private func closeSelector() {
        guard let sel = selector else { return }
        sel.removeFromSuperview()
        selector = nil
        window.makeFirstResponder(grid)
    }

    /// A pane in playback mode was just added/restored — align it to the
    /// main view's current transport.
    private func replaySuppTransport() {
        guard let pb = playback, let client = nvrClient else { return }
        supp.playbackTransport(position: pb.currentPosition, speed: pb.currentSpeed,
                               paused: pb.isPaused, client: client)
    }

    /// Double-click on a pane: open that camera as a plain standard view at
    /// the same moment (no panes there, adding disabled), with a way back.
    private func promoteSupplementary(_ camera: Camera) {
        guard promotedOrigin == nil, let cur = grid.focused, cur < streams.count,
              let target = streams.firstIndex(where: { $0.camera.host == camera.host }),
              target != cur else { return }
        let wasPlayback = playback != nil
        let position = playback?.currentPosition
        // The promoted view counts as its origin for "where you left off":
        // record the origin's state (playback and panes still live here) so
        // a quit from the promoted view reopens the origin, never this view.
        let originHost = streams[cur].camera.host
        saveViewState(host: originHost, position: position)
        SessionStore.update { $0.location = .camera; $0.cameraHost = originHost }
        promotedOrigin = (cur, wasPlayback, position)
        programmaticNav = true
        supp.teardown()              // saves the layout for the way back
        grid.focused = target        // tears down the origin's playback
        programmaticNav = false
        if wasPlayback { enterPlayback(startAt: position) }
        updateBackArrow()
    }

    private func goBackFromPromoted() {
        guard let origin = promotedOrigin else { return }
        promotedOrigin = nil
        programmaticNav = true       // this restore path works even with "remember" off
        grid.focused = origin.index
        programmaticNav = false
        guard let i = grid.focused, i < grid.tiles.count, i < streams.count else { return }
        supp.attach(to: grid.tiles[i], mainHost: streams[i].camera.host)
        supp.restoreSaved()
        if origin.wasPlayback { enterPlayback(startAt: origin.position) }
        updateBackArrow()
    }

    // MARK: shortcut help (?)

    private func toggleHelp() {
        if helpView != nil { closeHelp(); return }
        let context: HelpContext = playback != nil ? .playback
                                 : grid.focused != nil ? .camera : .grid
        let v = ShortcutHelpView(context: context)
        v.onClose = { [weak self] in self?.closeHelp() }
        v.frame = grid.bounds
        v.autoresizingMask = [.width, .height]
        grid.addSubview(v)
        helpView = v
        window.makeFirstResponder(v)
    }

    private func closeHelp() {
        guard let v = helpView else { return }
        v.removeFromSuperview()
        helpView = nil
        window.makeFirstResponder(grid)
    }

    // MARK: bookmarks (B adds in playback, Shift-B lists everywhere)

    /// B in playback: pause (a bookmark is a precise moment), then ask for an
    /// optional name over the focused tile.
    private func promptBookmark(_ pb: PlaybackController) {
        guard bookmarkPrompt == nil, bookmarkPane == nil,
              let i = grid.focused, i < streams.count, i < grid.tiles.count else { return }
        if !pb.isPaused { pb.togglePause() }
        let cam = streams[i].camera
        let pos = pb.currentPosition
        let tz = nvrClient?.timeZone ?? .current
        let prompt = BookmarkNamePrompt(subtitle: "\(cam.name) · \(BookmarkStore.rowFormatter(tz).string(from: pos))")
        prompt.onSave = { [weak self] label in
            BookmarkStore.add(Bookmark(id: UUID(), host: cam.host, cameraName: cam.name,
                                       time: pos, label: label, created: Date()))
            self?.playback?.refreshBookmarks()
            self?.closeBookmarkUI()
        }
        prompt.onCancel = { [weak self] in self?.closeBookmarkUI() }
        let tile = grid.tiles[i]
        prompt.frame = tile.bounds
        prompt.autoresizingMask = [.width, .height]
        tile.addSubview(prompt)
        bookmarkPrompt = prompt
        prompt.focus(in: window)
    }

    private func toggleBookmarkPane() {
        if bookmarkPane != nil { closeBookmarkUI(); return }
        guard bookmarkPrompt == nil else { return }
        closeHelp()
        let pane = BookmarkListPane(timeZone: nvrClient?.timeZone ?? .current)
        pane.onClose = { [weak self] in self?.closeBookmarkUI() }
        pane.onPick = { [weak self] b in self?.jumpToBookmark(b) }
        pane.onChanged = { [weak self] in self?.playback?.refreshBookmarks() }
        pane.frame = grid.bounds
        pane.autoresizingMask = [.width, .height]
        grid.addSubview(pane)
        bookmarkPane = pane
        window.makeFirstResponder(pane)
    }

    private func closeBookmarkUI() {
        guard bookmarkPrompt != nil || bookmarkPane != nil else { return }
        bookmarkPrompt?.removeFromSuperview()
        bookmarkPrompt = nil
        bookmarkPane?.removeFromSuperview()
        bookmarkPane = nil
        window.makeFirstResponder(grid)
    }

    /// Open the bookmark's camera in playback at its moment — the same
    /// programmatic navigation the promote/back flows use.
    private func jumpToBookmark(_ b: Bookmark) {
        closeBookmarkUI()
        guard let target = streams.firstIndex(where: { $0.camera.host == b.host }) else {
            NSSound.beep()      // camera no longer configured
            return
        }
        if grid.focused == target {
            if let pb = playback { pb.seek(to: b.time) } else { enterPlayback(startAt: b.time) }
            return
        }
        promotedOrigin = nil
        programmaticNav = true
        grid.focused = target
        programmaticNav = false
        SessionStore.update { $0.location = .camera; $0.cameraHost = b.host }
        enterPlayback(startAt: b.time)
    }

    // MARK: snapshots & clips (S / R, saved to the Desktop and opened)

    @objc func saveSnapshotMenu(_ sender: Any?) { saveSnapshot() }

    @objc func toggleRecordingMenu(_ sender: Any?) { toggleRecording() }

    /// S: still of the focused camera — live grabs the camera's full-res
    /// ISAPI picture; playback pulls one decoded frame at the current
    /// position from the NVR (takes a few seconds). The capture starts into
    /// a temp file the moment S is pressed, in parallel with the save panel,
    /// so naming the file doesn't shift the captured moment.
    private func saveSnapshot() {
        guard let i = grid.focused, i < streams.count, i < grid.tiles.count else {
            NSSound.beep()
            return
        }
        let cam = streams[i].camera
        let tile = grid.tiles[i]
        tile.flash()             // the shutter flash marks the captured moment
        let temp = MediaSaver.tempURL(ext: "jpg")

        var captureOK: Bool?
        var chosen: URL?
        var panelClosed = false
        // Runs when both the capture and the panel are done, in either order.
        let finish: () -> Void = { [weak tile] in
            guard panelClosed, let ok = captureOK else { return }
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let dest = chosen else { tile?.setStatus(""); return }   // cancelled
            guard ok else { tile?.setStatus("snapshot failed"); return }
            try? FileManager.default.removeItem(at: dest)   // replace confirmed by the panel
            do {
                try FileManager.default.moveItem(at: temp, to: dest)
                tile?.setStatus("")
                MediaSaver.reveal(dest)
            } catch { tile?.setStatus("snapshot failed") }
        }

        let name: String
        if let pb = playback, let client = nvrClient, let ch = client.channelByHost[cam.host] {
            let pos = pb.currentPosition
            name = MediaSaver.defaultName(camera: cam.name, date: pos,
                                          timeZone: client.timeZone, ext: "jpg")
            MediaSaver.capturePlaybackSnapshot(camera: cam, client: client,
                                               track: NVRClient.track(forChannel: ch),
                                               position: pos, to: temp) { ok in
                captureOK = ok
                finish()
            }
        } else {
            name = MediaSaver.defaultName(camera: cam.name, date: Date(), timeZone: nil, ext: "jpg")
            MediaSaver.captureLiveSnapshot(camera: cam, to: temp) { ok in
                captureOK = ok
                finish()
            }
        }
        MediaSaver.promptForSave(defaultName: name, type: .jpeg, window: window) { [weak tile] url in
            panelClosed = true
            chosen = url
            if url != nil, captureOK == nil { tile?.setStatus("saving snapshot…") }
            finish()
        }
    }

    /// R: toggle clip recording of the focused camera. Recording starts the
    /// moment R is pressed, into a temp file; the save panel appears when it
    /// stops (Cancel discards the clip). Live records the main stream;
    /// playback records from the current position at 1×, unaffected by
    /// pausing/seeking while it runs.
    private func toggleRecording() {
        if recorder != nil {
            stopRecording()
            return
        }
        guard let i = grid.focused, i < streams.count, i < grid.tiles.count else {
            NSSound.beep()
            return
        }
        let cam = streams[i].camera
        let tile = grid.tiles[i]
        let input: String
        let stamp: Date
        let tz: TimeZone?
        if let pb = playback, let client = nvrClient, let ch = client.channelByHost[cam.host] {
            let pos = pb.currentPosition
            let (path, _) = client.playbackRequest(track: NVRClient.track(forChannel: ch),
                                                   from: pos, to: pos.addingTimeInterval(6 * 3600))
            input = MediaSaver.playbackURL(client: client, path: path)
            stamp = pos
            tz = client.timeZone
        } else {
            input = rtspURL(camera: cam, channel: mainChannel)
            stamp = Date()
            tz = nil
        }
        let name = MediaSaver.defaultName(camera: cam.name, date: stamp, timeZone: tz, ext: "mp4")
        let temp = MediaSaver.tempURL(ext: "mp4")
        guard let rec = ClipRecorder(inputURL: input, codec: cam.codec, fileURL: temp), rec.start() else {
            tile.setStatus("recording failed to start")
            return
        }
        recDefaultName = name
        rec.onFinish = { [weak self, weak tile] ok in
            guard let self else { return }
            self.recTimer?.invalidate()
            self.recTimer = nil
            tile?.setRecording(nil)
            if ok { self.promptToKeepClip(rec.fileURL, defaultName: name) }
            else { tile?.setStatus("recording failed") }
            if self.recorder === rec {
                self.recorder = nil
                self.recTile = nil
                self.recHost = nil
                self.recDefaultName = nil
            }
        }
        recorder = rec
        recTile = tile
        recHost = cam.host
        tile.setRecording("0:00")
        recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let rec = self.recorder else { return }
            let s = Int(Date().timeIntervalSince(rec.startedAt))
            self.recTile?.setRecording(String(format: "%d:%02d", s / 60, s % 60))
        }
    }

    /// The recording finished — let the user name/place it, or discard.
    private func promptToKeepClip(_ temp: URL, defaultName: String) {
        MediaSaver.promptForSave(defaultName: defaultName, type: .mpeg4Movie, window: window) { url in
            guard let url else {
                try? FileManager.default.removeItem(at: temp)   // cancelled: discard
                return
            }
            try? FileManager.default.removeItem(at: url)        // replace confirmed by the panel
            do {
                try FileManager.default.moveItem(at: temp, to: url)
                MediaSaver.reveal(url)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                NSSound.beep()
            }
        }
    }

    private func stopRecording() {
        recorder?.stop()         // onFinish does the cleanup when ffmpeg exits
    }

    /// The translucent back arrow shows only when Esc's next action would
    /// leave the promoted view (not zoomed, not in playback).
    private func updateBackArrow() {
        for (i, t) in grid.tiles.enumerated() {
            t.setBackVisible(promotedOrigin != nil && grid.focused == i
                             && playback == nil && !t.isZoomed)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Record where the user quit. A promoted view was already recorded
        // as its origin at promote time — leave that in place.
        if promotedOrigin == nil {
            if let i = grid.focused, i < streams.count {
                let host = streams[i].camera.host
                saveViewState(host: host)   // exact playback position at quit
                SessionStore.update { $0.location = .camera; $0.cameraHost = host }
            } else {
                SessionStore.update { $0.location = .grid; $0.cameraHost = nil }
            }
        }
        // A recording still running at quit is finalized and auto-saved to
        // the Desktop under its default name — no save panel mid-terminate.
        if let rec = recorder {
            rec.onFinish = nil
            rec.stopAndWait()
            if (MediaSaver.fileSize(rec.fileURL) ?? 0) > 4096 {
                let dest = MediaSaver.uniqueDesktopURL(name: recDefaultName ?? rec.fileURL.lastPathComponent)
                try? FileManager.default.moveItem(at: rec.fileURL, to: dest)
            } else {
                try? FileManager.default.removeItem(at: rec.fileURL)
            }
        }
        playback?.exit()
        mainStream?.stop()
        streams.forEach { $0.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
