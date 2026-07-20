// MediaSaver.swift — save a snapshot (JPEG) or clip (MP4) of the focused
// camera, via a save panel defaulting to the Desktop.
//
// Live snapshots come straight off the camera's ISAPI picture endpoint at
// full resolution; playback snapshots and all clips go through ffmpeg over
// RTSP with stream copy (no transcode). Clips are fragmented MP4, so even a
// force-quit mid-recording leaves a playable file.

import AppKit
import UniformTypeIdentifiers

enum MediaSaver {
    static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    /// "Front Door 2026-07-20 14.32.05.jpg" — the timestamp is footage time
    /// for playback (NVR timezone), wall clock for live.
    static func defaultName(camera: String, date: Date, timeZone: TimeZone?, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        if let timeZone { f.timeZone = timeZone }
        let name = camera
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        return "\(name) \(f.string(from: date)).\(ext)"
    }

    /// Scratch file for capturing while the save panel is still open.
    static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hik-\(UUID().uuidString).\(ext)")
    }

    /// Desktop path for `name`, never overwriting — collisions get " (2)"…
    /// Used by the quit path, where no save panel can arbitrate.
    static func uniqueDesktopURL(name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = desktop.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// The save panel's "Reveal in Finder" checkbox, remembered across saves.
    static var revealInFinder: Bool {
        get { UserDefaults.standard.bool(forKey: "revealSavedInFinder") }
        set { UserDefaults.standard.set(newValue, forKey: "revealSavedInFinder") }
    }

    static func reveal(_ url: URL) {
        if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// Sheet with our default name (base name preselected for typing over),
    /// Desktop as the starting folder, and the reveal checkbox.
    /// Completion (main thread): the chosen URL, or nil if cancelled.
    static func promptForSave(defaultName: String, type: UTType, window: NSWindow,
                              completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = desktop
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        let check = NSButton(checkboxWithTitle: "Reveal in Finder", target: nil, action: nil)
        check.state = revealInFinder ? .on : .off
        check.sizeToFit()
        let pad = NSView(frame: NSRect(x: 0, y: 0,
                                       width: check.frame.width + 20, height: check.frame.height + 16))
        check.frame.origin = NSPoint(x: 10, y: 8)
        pad.addSubview(check)
        panel.accessoryView = pad
        panel.beginSheetModal(for: window) { resp in
            revealInFinder = check.state == .on
            completion(resp == .OK ? panel.url : nil)
        }
    }

    /// Full-resolution JPEG of "now" from the camera itself, written to
    /// `url`. Completion (main thread): success.
    static func captureLiveSnapshot(camera: Camera, to url: URL,
                                    completion: @escaping (Bool) -> Void) {
        ISAPI.snapshot(host: camera.host, channel: mainChannel) { data in
            var ok = false
            if let data, !data.isEmpty, (try? data.write(to: url, options: .atomic)) != nil {
                ok = true
            }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// One decoded frame at `position` from the NVR playback stream, written
    /// to `url`. Takes a few seconds (RTSP setup + ffmpeg's initial
    /// buffering). Completion (main thread): success.
    static func capturePlaybackSnapshot(camera: Camera, client: NVRClient, track: Int,
                                        position: Date, to url: URL,
                                        completion: @escaping (Bool) -> Void) {
        let (path, _) = client.playbackRequest(track: track, from: position,
                                               to: position.addingTimeInterval(300))
        let input = playbackURL(client: client, path: path)
        runFFmpeg(["-hide_banner", "-loglevel", "error", "-nostdin",
                   "-rtsp_transport", "tcp", "-i", input,
                   "-frames:v", "1", "-q:v", "2", "-f", "image2", "-y", url.path],
                  timeout: 30) {
            let ok = (fileSize(url) ?? 0) > 0
            if !ok { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    static func playbackURL(client: NVRClient, path: String) -> String {
        "rtsp://\(urlEncode(client.nvr.user)):\(urlEncode(client.nvr.password))@\(client.nvr.host):\(client.nvr.rtspPort)\(path)"
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private static func runFFmpeg(_ args: [String], timeout: TimeInterval,
                                  completion: @escaping () -> Void) {
        guard let ff = ffmpegPath else { completion(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ff)
        p.arguments = args
        p.standardError = ProcessInfo.processInfo.environment["HIK_DEBUG"] != nil
            ? FileHandle.standardError : FileHandle.nullDevice
        p.terminationHandler = { _ in completion() }
        do { try p.run() } catch { completion(); return }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
    }
}

/// One in-flight clip recording: an ffmpeg stream-copy pull (a second RTSP
/// session — live from the camera, playback from the NVR at 1×) independent
/// of the viewing pipeline, so pausing/seeking never disturbs the file.
final class ClipRecorder {
    let fileURL: URL
    let startedAt = Date()
    /// Fired once on the main thread when ffmpeg exits, with whether the
    /// file came out non-empty. Fires for both user stops and self-exits
    /// (stream error, end of recording).
    var onFinish: ((Bool) -> Void)?

    private let process = Process()
    private var forceKill: DispatchWorkItem?

    init?(inputURL: String, codec: VideoCodec, fileURL: URL) {
        guard let ff = ffmpegPath else { return nil }
        self.fileURL = fileURL
        process.executableURL = URL(fileURLWithPath: ff)
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin",
                    "-rtsp_transport", "tcp", "-i", inputURL, "-an", "-c:v", "copy"]
        if codec == .hevc { args += ["-tag:v", "hvc1"] }   // QuickTime-openable HEVC
        args += ["-f", "mp4", "-movflags", "frag_keyframe+empty_moov", "-y", fileURL.path]
        process.arguments = args
        process.standardError = ProcessInfo.processInfo.environment["HIK_DEBUG"] != nil
            ? FileHandle.standardError : FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.finished() }
        }
    }

    func start() -> Bool {
        do { try process.run(); return true } catch { return false }
    }

    /// SIGINT lets ffmpeg finish the file cleanly; a laggard gets SIGTERM.
    func stop() {
        guard process.isRunning else { return }
        process.interrupt()
        let kill = DispatchWorkItem { [process] in if process.isRunning { process.terminate() } }
        forceKill = kill
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: kill)
    }

    /// Quit path: block briefly so the file is finalized before the app exits.
    func stopAndWait() {
        stop()
        for _ in 0..<15 where process.isRunning { usleep(100_000) }
    }

    private func finished() {
        forceKill?.cancel()
        let ok = (MediaSaver.fileSize(fileURL) ?? 0) > 4096
        if !ok { try? FileManager.default.removeItem(at: fileURL) }
        onFinish?(ok)
        onFinish = nil
    }
}
