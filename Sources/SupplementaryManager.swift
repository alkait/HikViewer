// SupplementaryManager.swift — owns the ≤4 floating supplementary panes on
// the focused tile: adding/removing, drag/resize persistence, and feeding
// them (live substream tap, or playback streams synced to the main view's
// transport).

import AppKit
import CoreMedia

/// One saved pane, normalized to the tile's bounds.
struct PaneLayout: Codable {
    var host: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// Last-used pane set per main camera, on disk so it survives relaunches.
/// Deliberately separate from config.json: layout state, no credentials, and
/// export/import stays untouched.
enum LayoutStore {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("hikviewer/layouts.json")
    }()

    static func load() -> [String: [PaneLayout]] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([String: [PaneLayout]].self, from: data) else { return [:] }
        return all
    }

    static func save(_ layouts: [PaneLayout], for mainHost: String) {
        var all = load()
        all[mainHost] = layouts
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func saved(for mainHost: String) -> [PaneLayout] { load()[mainHost] ?? [] }
}

final class SupplementaryManager {
    private final class Pane {
        let camera: Camera
        let view: SupplementaryTile
        var stream: PlaybackStream?
        var norm: NSRect
        init(camera: Camera, view: SupplementaryTile, norm: NSRect) {
            self.camera = camera
            self.view = view
            self.norm = norm
        }
    }

    var onPromote: ((Camera) -> Void)?

    private var panes: [Pane] = []
    private weak var hostTile: TileView?
    private(set) var attachedHost: String?
    private var playbackActive = false
    private var bottomInset: CGFloat = 0

    // The live tap is read from stream queues — guard the sink map.
    private let liveLock = NSLock()
    private var liveSinks: [String: SupplementaryTile] = [:]

    var count: Int { panes.count }
    var paneHosts: [String] { panes.map { $0.camera.host } }

    func attach(to tile: TileView, mainHost: String) {
        if attachedHost != nil, attachedHost != mainHost { teardown() }
        hostTile = tile
        attachedHost = mainHost
        tile.onLayoutChange = { [weak self] in self?.applyFrames() }
    }

    func addPane(camera: Camera, norm: NSRect? = nil) {
        guard panes.count < 4, hostTile != nil, !paneHosts.contains(camera.host) else { return }
        let v = SupplementaryTile(camera: camera)
        v.bottomInset = bottomInset
        v.onPromote = { [weak self] in self?.onPromote?(camera) }
        v.onClose = { [weak self, weak v] in
            guard let self, let v else { return }
            self.removePane(view: v)
        }
        v.onFrameChanged = { [weak self] in self?.captureNorms() }
        v.onUserLayoutChange = { [weak self] in
            self?.captureNorms()
            self?.persist()
        }
        let pane = Pane(camera: camera, view: v, norm: norm ?? freeSlot())
        panes.append(pane)
        hostTile?.addSubview(v)
        applyFrames()
        rebuildLiveSinks()
        persist()

        // Same anti-black-screen tricks as the grid (rebuildStreams): paint
        // the last-known snapshot instantly and refresh it from the camera.
        // In playback mode the snapshot shows "now" rather than the playback
        // moment, but a briefly wrong-time frame beats a black box — the
        // pane's stream replaces it within a second. Dim the fresh one there
        // (cached: true) so it reads as approximate, like a stale frame.
        let host = camera.host
        let inPlayback = playbackActive
        if let cached = SnapshotCache.load(host: host) {
            v.setPlaceholder(cached, cached: true)
        }
        ISAPI.snapshot(host: host, channel: channel) { [weak v] data in
            guard let data, let image = NSImage(data: data) else { return }
            SnapshotCache.save(host: host, jpeg: data)
            DispatchQueue.main.async { v?.setPlaceholder(image, cached: inPlayback) }
        }
        // The IDR nudge only helps the live substream tap — playback panes
        // get their own NVR stream, which starts on a keyframe anyway.
        guard !inPlayback else { return }
        nudgeKeyFrame(host: host, view: v, attempt: 0)
    }

    /// Some firmware ignores a single requestKeyFrame — retry once a second
    /// until the pane renders its first frame (same as CameraStream.launch).
    private func nudgeKeyFrame(host: String, view: SupplementaryTile?, attempt: Int) {
        guard let view, !view.hasVideo, attempt < 3, !playbackActive else { return }
        ISAPI.requestKeyFrame(host: host, channel: channel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak view] in
            self?.nudgeKeyFrame(host: host, view: view, attempt: attempt + 1)
        }
    }

    /// Bring back the last-used set for the attached main camera.
    func restoreSaved() {
        guard let host = attachedHost else { return }
        for l in LayoutStore.saved(for: host).prefix(4) {
            guard panes.count < 4, !paneHosts.contains(l.host),
                  let cam = Settings.cameras.first(where: { $0.host == l.host }) else { continue }
            addPane(camera: cam, norm: NSRect(x: l.x, y: l.y, width: l.w, height: l.h))
        }
    }

    /// "-" — close the most recently added pane.
    func removeLastPane() {
        guard let last = panes.last else { return }
        removePane(view: last.view)
    }

    private func removePane(view: SupplementaryTile) {
        guard let i = panes.firstIndex(where: { $0.view === view }) else { return }
        panes[i].stream?.stop()
        panes[i].view.removeFromSuperview()
        panes.remove(at: i)
        rebuildLiveSinks()
        // No persist: closing panes must not shrink the saved set, so
        // closing all of them (in any order) leaves the full last set behind
        // the selector's "↺ Restore last" row. The saved set tracks adds,
        // drags/resizes, and teardown — a set trimmed deliberately gets
        // persisted at teardown, when panes are still up.
    }

    /// Remove every pane (saving the layout for restore). Safe to call twice.
    func teardown() {
        if attachedHost != nil, !panes.isEmpty { persist() }
        for p in panes {
            p.stream?.stop()
            p.view.removeFromSuperview()
        }
        panes = []
        rebuildLiveSinks()
        hostTile?.onLayoutChange = nil
        hostTile = nil
        attachedHost = nil
        playbackActive = false
        bottomInset = 0
    }

    // MARK: feeding

    /// Live tap: the grid substreams already run under the focused view, so
    /// live panes cost zero extra sessions — frames fan out here.
    func distributeLive(host: String, _ sb: CMSampleBuffer, _ sync: Bool) {
        liveLock.lock()
        let sink = liveSinks[host]
        liveLock.unlock()
        sink?.enqueue(sb, isSync: sync)
    }

    /// The main view's playback transport changed — re-align every pane.
    /// Paused = stop pipes and freeze on the last frame.
    func playbackTransport(position: Date, speed: Int, paused: Bool, client: NVRClient) {
        playbackActive = true
        rebuildLiveSinks()
        for pane in panes {
            pane.stream?.stop()
            pane.stream = nil
        }
        if paused {
            // Frozen panes keep their last frame — but a pane added while
            // paused has none yet and would sit black. Run its stream just
            // long enough to render the frame at the paused position, then
            // stop: the pane freezes in sync with the main view.
            for pane in panes where !pane.view.hasVideo {
                startStream(for: pane, position: position, speed: 1,
                            client: client, freezeAfterFirstFrame: true)
            }
            return
        }
        for pane in panes {
            startStream(for: pane, position: position, speed: speed,
                        client: client, freezeAfterFirstFrame: false)
        }
    }

    private func startStream(for pane: Pane, position: Date, speed: Int,
                             client: NVRClient, freezeAfterFirstFrame: Bool) {
        guard let ch = client.channelByHost[pane.camera.host] else {
            pane.view.setNote("no recording")
            return
        }
        pane.view.setNote(nil)
        let (path, clock) = client.playbackRequest(
            track: NVRClient.track(forChannel: ch),
            from: position, to: position.addingTimeInterval(6 * 3600))
        let s = PlaybackStream(host: client.nvr.host, port: client.nvr.rtspPort,
                               user: client.nvr.user, password: client.nvr.password,
                               path: path, startClock: clock, scale: speed,
                               codec: pane.camera.codec)
        let view = pane.view
        s.onSample = { [weak view] sb, sync in view?.enqueue(sb, isSync: sync) }
        s.onState = { _ in }
        s.onEnded = { }               // freeze at the end; the main view leads
        // Clear (or arm) the one-shot: a stale freeze closure from a
        // paused-add must not survive into a normal playing stream.
        view.onFirstFrame = freezeAfterFirstFrame ? { [weak s] in s?.stop() } : nil
        view.resync()
        pane.stream = s
        s.start()
    }

    /// Main view returned to live — panes follow the substream tap again.
    func switchToLive() {
        playbackActive = false
        for pane in panes {
            pane.stream?.stop()
            pane.stream = nil
            pane.view.setNote(nil)
            pane.view.resync()
        }
        rebuildLiveSinks()
    }

    /// Keep panes clear of the playback bar.
    func setBottomInset(_ inset: CGFloat) {
        bottomInset = inset
        for p in panes { p.view.bottomInset = inset }
        applyFrames()
    }

    // MARK: geometry & persistence

    private func rebuildLiveSinks() {
        liveLock.lock()
        liveSinks = playbackActive ? [:]
            : Dictionary(uniqueKeysWithValues: panes.map { ($0.camera.host, $0.view) })
        liveLock.unlock()
    }

    /// Default slots: a column of four on the far right, top to bottom,
    /// skipping occupied ones.
    private func freeSlot() -> NSRect {
        let slots = (0..<4).map { i in
            NSRect(x: 0.755, y: 0.755 - Double(i) * 0.233, width: 0.235, height: 0.22)
        }
        for slot in slots where !panes.contains(where: { $0.norm.intersects(slot) }) {
            return slot
        }
        return slots[panes.count % 4]
    }

    /// Normalized rects -> pixel frames (called on add and window resize).
    private func applyFrames() {
        guard let tile = hostTile, tile.bounds.width > 0, tile.bounds.height > 0 else { return }
        for p in panes {
            let f = NSRect(x: p.norm.origin.x * tile.bounds.width,
                           y: p.norm.origin.y * tile.bounds.height,
                           width: p.norm.width * tile.bounds.width,
                           height: p.norm.height * tile.bounds.height)
            p.view.frame = p.view.clamped(f)
        }
    }

    /// Pixel frames -> normalized rects (after a user drag/resize).
    private func captureNorms() {
        guard let tile = hostTile, tile.bounds.width > 0, tile.bounds.height > 0 else { return }
        for p in panes {
            p.norm = NSRect(x: p.view.frame.origin.x / tile.bounds.width,
                            y: p.view.frame.origin.y / tile.bounds.height,
                            width: p.view.frame.width / tile.bounds.width,
                            height: p.view.frame.height / tile.bounds.height)
        }
    }

    private func persist() {
        guard let host = attachedHost else { return }
        LayoutStore.save(panes.map {
            PaneLayout(host: $0.camera.host, x: $0.norm.origin.x, y: $0.norm.origin.y,
                       w: $0.norm.width, h: $0.norm.height)
        }, for: host)
    }
}
