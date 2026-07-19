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
        if Settings.startFullScreen { window.toggleFullScreen(nil) }
        NSApp.activate(ignoringOtherApps: true)

        if Settings.isConfigured && !Settings.cameras.isEmpty {
            rebuildStreams()
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
        if let pb = playback { pb.exit(); playback = nil }
        closeSelector()
        supp.teardown()
        promotedOrigin = nil
        nvrClient = nil      // pick up NVR credential changes lazily
        grid.focused = nil   // while tiles/streams are still in sync
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
        if let pb = playback { pb.exit(); playback = nil }
        closeSelector()
        // Panes survive playback exits on the same camera; any other focus
        // change tears them down (their layout is saved for restore).
        let host: String? = idx.flatMap { $0 < streams.count ? streams[$0].camera.host : nil }
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
        guard let i = idx, channel != mainChannel, i < streams.count, let ff = ffmpegPath else { return }
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

    // MARK: playback (recorded footage from the NVR, on the focused tile)

    private func handleKey(_ e: NSEvent) -> Bool {
        // + on a focused view: add a supplementary pane (selector panel).
        if grid.focused != nil, let ch = e.charactersIgnoringModifiers, ch == "+" || ch == "=" {
            openSupplementarySelector()
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
            case "n":
                if e.modifierFlags.contains(.shift) { pb.jumpToPreviousMotion() }
                else { pb.jumpToNextMotion() }
                return true
            case "p": exitPlayback(); return true
            default: return false
            }
        }
        if e.charactersIgnoringModifiers?.lowercased() == "p", grid.focused != nil {
            enterPlayback()
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
                guard let self, let client = self.nvrClient else { return }
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
        guard promotedOrigin == nil, let cur = grid.focused,
              let target = streams.firstIndex(where: { $0.camera.host == camera.host }),
              target != cur else { return }
        let wasPlayback = playback != nil
        let position = playback?.currentPosition
        promotedOrigin = (cur, wasPlayback, position)
        supp.teardown()              // saves the layout for the way back
        grid.focused = target        // tears down the origin's playback
        if wasPlayback { enterPlayback(startAt: position) }
        updateBackArrow()
    }

    private func goBackFromPromoted() {
        guard let origin = promotedOrigin else { return }
        promotedOrigin = nil
        grid.focused = origin.index
        guard let i = grid.focused, i < grid.tiles.count, i < streams.count else { return }
        supp.attach(to: grid.tiles[i], mainHost: streams[i].camera.host)
        supp.restoreSaved()
        if origin.wasPlayback { enterPlayback(startAt: origin.position) }
        updateBackArrow()
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
        playback?.exit()
        mainStream?.stop()
        streams.forEach { $0.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
