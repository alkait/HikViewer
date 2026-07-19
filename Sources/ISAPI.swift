// ISAPI.swift — minimal ISAPI client (digest auth) and the snapshot cache.

import AppKit

final class DigestDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        // Credentials are per-device; pick them by the host being challenged.
        let host = challenge.protectionSpace.host
        if let nvr = Settings.nvr, nvr.host == host {
            completionHandler(.useCredential,
                              URLCredential(user: nvr.user, password: nvr.password, persistence: .forSession))
            return
        }
        guard let cam = Settings.cameras.first(where: { $0.host == host }) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: cam.user, password: Settings.password(for: host), persistence: .forSession))
    }
}

enum ISAPI {
    static let session = URLSession(configuration: .ephemeral, delegate: DigestDelegate(), delegateQueue: nil)

    /// Ask the camera to emit an IDR frame right now instead of waiting out
    /// the GOP (~2-4 s). Runtime request only — changes no configuration.
    static func requestKeyFrame(host: String, channel: String) {
        guard let url = URL(string: "http://\(host)/ISAPI/Streaming/channels/\(channel)/requestKeyFrame") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = 5
        session.dataTask(with: req).resume()
    }

    /// One JPEG frame (raw bytes), used as a placeholder while video connects
    /// and written to the on-disk cache for an instant paint next launch.
    static func snapshot(host: String, channel: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: "http://\(host)/ISAPI/Streaming/channels/\(channel)/picture") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        session.dataTask(with: req) { data, _, _ in completion(data) }.resume()
    }
}

/// Last-known JPEG per camera on disk, so the grid paints instantly at launch
/// (before any network) with a clearly-marked "cached" frame.
enum SnapshotCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("hikviewer/cache")
    }()

    private static func url(for host: String) -> URL {
        dir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    static func load(host: String) -> NSImage? { NSImage(contentsOf: url(for: host)) }

    static func save(host: String, jpeg: Data) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? jpeg.write(to: url(for: host), options: .atomic)
    }
}
