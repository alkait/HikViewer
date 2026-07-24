// CameraStream.swift — per-camera ffmpeg pipe (RTSP -> raw Annex B stream).

import Foundation
import CoreMedia

/// One ffmpeg pipe: RTSP in (stream copy, no transcode), raw elementary stream
/// out, parsed into CMSampleBuffers. Reconnects forever on any exit or stall.
/// Live streams only — playback uses PlaybackStream (native RTSP).
final class CameraStream {
    let camera: Camera
    /// Nerd-stats collector for this stream (panel reads it; always written).
    let stats = StreamStats()
    private let url: String
    let channelId: String
    private let ffmpegPath: String
    private let queue: DispatchQueue
    private let parser: VideoStreamParser
    private var process: Process?
    private var stopped = false
    private var lastData = Date()
    private var gotFirstFrame = false
    private var sentKeyFrameRequest = false
    private var launchTime = Date()
    private var watchdog: DispatchSourceTimer?

    var onSample: ((CMSampleBuffer, _ isSync: Bool) -> Void)?
    var onState: ((String) -> Void)?
    private(set) var lastStatus = ""  // main-thread only

    init(camera: Camera, url: String, channelId: String, ffmpegPath: String) {
        self.camera = camera
        self.url = url
        self.channelId = channelId
        self.ffmpegPath = ffmpegPath
        self.queue = DispatchQueue(label: "cam." + camera.host)
        self.parser = VideoStreamParser(codec: camera.codec, smoothableLive: true, stats: stats)
        parser.onAccessUnit = { [weak self] sb, sync in
            guard let self else { return }
            if !self.gotFirstFrame {
                self.gotFirstFrame = true
                var status = "live"
                if let f = self.parser.format {
                    let d = CMVideoFormatDescriptionGetDimensions(f)
                    status = "\(d.width)×\(d.height)"
                }
                self.report(status)
                if ProcessInfo.processInfo.environment["HIK_DEBUG"] != nil {
                    let dt = Date().timeIntervalSince(self.launchTime)
                    FileHandle.standardError.write(Data(String(format: "[%@] first frame in %.2fs\n", self.camera.name, dt).utf8))
                }
            }
            self.onSample?(sb, sync)
        }
    }

    func start() {
        queue.async { self.launch() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.checkStale() }
        t.resume()
        watchdog = t
    }

    func stop() {
        queue.sync {
            stopped = true
            watchdog?.cancel()
            if let p = process, p.isRunning { p.terminate() }
        }
    }

    private func report(_ status: String) {
        DispatchQueue.main.async {
            self.lastStatus = status
            self.onState?(status)
        }
        if ProcessInfo.processInfo.environment["HIK_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[\(camera.name)] \(status)\n".utf8))
        }
    }

    private func launch() {
        guard !stopped else { return }
        parser.reset()
        gotFirstFrame = false
        sentKeyFrameRequest = false
        launchTime = Date()
        lastData = Date()
        report("connecting…")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        var args = [
            "-hide_banner", "-loglevel", "error", "-nostdin",
            "-rtsp_transport", "tcp", "-fflags", "nobuffer",
        ]
        // Zero-probe fast start: codec params come from the RTSP SDP, so skip
        // ffmpeg's input analysis (saves ~1-2 s). The H.264 raw muxer, though,
        // needs the SPS dimensions before it writes its header, so let it probe.
        if camera.codec == .hevc {
            args += ["-probesize", "32", "-analyzeduration", "0"]
        }
        args += ["-i", url, "-an", "-c:v", "copy", "-f", camera.codec.ffmpegFormat, "pipe:1"]
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = ProcessInfo.processInfo.environment["HIK_DEBUG"] != nil
            ? FileHandle.standardError : FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty {  // EOF
                fh.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.queue.async {
                self.lastData = Date()
                self.stats.noteBytes(d.count)
                // First bytes = RTSP session is playing; ask for an immediate
                // IDR so we don't wait out the GOP for a decodable frame.
                if !self.sentKeyFrameRequest {
                    self.sentKeyFrameRequest = true
                    self.nudgeKeyFrame(attempt: 0)
                }
                self.parser.push(d)
            }
        }
        p.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                self.stats.setPid(nil)
                self.stats.noteReconnect()
                self.report("reconnecting…")
                self.queue.asyncAfter(deadline: .now() + 2) { self.launch() }
            }
        }
        do {
            try p.run()
            process = p
            stats.setPid(p.processIdentifier)
        } catch {
            report("ffmpeg failed to launch")
            queue.asyncAfter(deadline: .now() + 5) { self.launch() }
        }
    }

    /// Some firmware ignores a single requestKeyFrame fired right at session
    /// start — retry once a second until the first frame lands (on queue).
    private func nudgeKeyFrame(attempt: Int) {
        guard !stopped, !gotFirstFrame, attempt < 3 else { return }
        ISAPI.requestKeyFrame(host: camera.host, channel: channelId)
        let epoch = launchTime
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.launchTime == epoch else { return }
            self.nudgeKeyFrame(attempt: attempt + 1)
        }
    }

    /// The camera occasionally stalls a TCP session without closing it; kill
    /// the pipe so the termination handler reconnects.
    private func checkStale() {
        guard !stopped, let p = process, p.isRunning else { return }
        if Date().timeIntervalSince(lastData) > 12 {
            stats.noteStall()
            report("stalled, restarting…")
            p.terminate()
        }
    }
}
