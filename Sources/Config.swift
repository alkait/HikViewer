// Config.swift — camera/NVR models and the on-disk configuration store.

import Foundation

enum VideoCodec: String {
    case hevc, h264
    var ffmpegFormat: String { rawValue }   // valid ffmpeg muxer names
    var display: String { self == .hevc ? "HEVC" : "H.264" }
}

struct Camera {
    let host: String
    let name: String
    let user: String
    let port: Int
    let codec: VideoCodec
}

/// One camera as stored on disk (includes its password). Part of the
/// export/import format.
struct StoredCamera: Codable {
    var host: String
    var name: String
    var user: String
    var port: Int
    var codec: String       // "hevc" / "h264"
    var password: String
}

/// The NVR that holds the recordings (playback only — live viewing stays
/// direct-to-camera). ISAPI goes over HTTP on port 80; `port` is RTSP.
struct StoredNVR: Codable {
    var host: String
    var user: String
    var password: String
    var port: Int?          // RTSP; nil = 554
    var rtspPort: Int { port ?? 554 }
}

/// The whole config file: cameras plus the optional NVR.
struct StoredConfig: Codable {
    var cameras: [StoredCamera]
    var nvr: StoredNVR?
}

/// App configuration — the full camera list, credentials included — in a single
/// JSON file under Application Support, chmod 600 (readable only by your user).
///
/// Deliberately NOT the Keychain: this is a self-built binary that gets rebuilt
/// often, and each rebuild changes its code identity, so the Keychain would
/// re-prompt for every item after every build. A 0600 file avoids that and makes
/// export/import a plain file copy. Trade-off: passwords sit in a file your
/// account can read (not encrypted at rest like the Keychain).
enum Settings {
    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("hikviewer/config.json")
    }()

    private static var cache: StoredConfig = load()

    /// Current format ({cameras, nvr}) or the pre-playback bare camera array.
    static func decode(_ data: Data) -> StoredConfig? {
        if let cfg = try? JSONDecoder().decode(StoredConfig.self, from: data) { return cfg }
        if let cams = try? JSONDecoder().decode([StoredCamera].self, from: data) {
            return StoredConfig(cameras: cams, nvr: nil)
        }
        return nil
    }

    static func load() -> StoredConfig {
        guard let data = try? Data(contentsOf: fileURL), let cfg = decode(data) else {
            return StoredConfig(cameras: [], nvr: nil)
        }
        return cfg
    }

    static var stored: [StoredCamera] { cache.cameras }
    static var nvr: StoredNVR? { cache.nvr }

    static func save(cameras: [StoredCamera], nvr: StoredNVR?) {
        cache = StoredConfig(cameras: cameras, nvr: nvr)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static var cameras: [Camera] {
        cache.cameras.compactMap { s in
            guard !s.host.isEmpty else { return nil }
            return Camera(host: s.host, name: s.name.isEmpty ? s.host : s.name,
                          user: s.user, port: s.port, codec: VideoCodec(rawValue: s.codec) ?? .hevc)
        }
    }

    static func password(for host: String) -> String {
        cache.cameras.first { $0.host == host }?.password ?? ""
    }

    /// At least one camera fully usable (host + user + password).
    static var isConfigured: Bool {
        cache.cameras.contains { !$0.host.isEmpty && !$0.user.isEmpty && !$0.password.isEmpty }
    }

    /// UI preference, not part of the camera config — lives in UserDefaults
    /// (like the window-frame autosave) so exports stay cameras-only.
    static var startFullScreen: Bool {
        get { UserDefaults.standard.object(forKey: "startFullScreen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "startFullScreen") }
    }
}

// MARK: - Shared helpers

func findFFmpeg() -> String? {
    var candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        candidates += path.split(separator: ":").map { String($0) + "/ffmpeg" }
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

let ffmpegPath = findFFmpeg()
let ffmpegInstallHint = "ffmpeg not found. Install it with Homebrew:\n\n    brew install ffmpeg\n\nThen reopen the app."

let urlSafeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
func urlEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: urlSafeChars) ?? s
}

let channel = "102"       // grid feed (substream)
let mainChannel = "101"   // focused-tile feed (main stream)

func rtspURL(camera: Camera, channel: String) -> String {
    "rtsp://\(urlEncode(camera.user)):\(urlEncode(Settings.password(for: camera.host)))@\(camera.host):\(camera.port)/Streaming/Channels/\(channel)"
}
