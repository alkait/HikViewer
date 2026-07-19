// PlaybackStream.swift — native RTSP client for NVR playback.
//
// Playback deliberately does NOT go through ffmpeg: its RTP depacketizer sits
// on the NVR's initial burst for ~4 s before emitting the first packet
// (measured; the NVR itself delivers video ~0.25 s after PLAY). Speaking RTSP
// directly gets the first frame on screen in ~0.3 s and lets us send the
// `Scale:` header for fast playback natively — no ffmpeg flags, no relay.
//
// Scope: TCP-interleaved RTP, video track only, digest auth, HEVC (RFC 7798)
// and H.264 (RFC 6184) depacketization into Annex B fed to the same
// VideoStreamParser -> CMSampleBuffer pipeline the live tiles use. Timestamps
// aren't taken from RTP — the parser stamps frames on arrival, and the NVR
// paces delivery at the requested speed, exactly like the live path.

import Foundation
import CoreMedia
import CryptoKit

final class PlaybackStream {
    var onSample: ((CMSampleBuffer, _ isSync: Bool) -> Void)?
    var onState: ((String) -> Void)?      // main thread
    var onEnded: (() -> Void)?            // main thread

    private let host: String
    private let port: Int
    private let user: String
    private let password: String
    private let path: String              // "/Streaming/tracks/101/?starttime=…&endtime=…"
    private let startClock: String        // "20260719T083000Z" (NVR-local fake-UTC)
    private let scale: Int
    private let codec: VideoCodec
    private let parser: VideoStreamParser

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    private var keepalive: DispatchSourceTimer?

    private var cseq = 0
    private var realm = ""
    private var nonce = ""
    private var sessionID = ""
    private var readBuf = Data()
    private var fuNAL: [UInt8] = []       // fragmented-NAL reassembly
    private var gotFirstFrame = false
    private let launchTime = Date()

    private var uri: String { "rtsp://\(host):\(port)\(path)" }

    init(host: String, port: Int, user: String, password: String,
         path: String, startClock: String, scale: Int, codec: VideoCodec) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.path = path
        self.startClock = startClock
        self.scale = scale
        self.codec = codec
        self.parser = VideoStreamParser(codec: codec)
        parser.onAccessUnit = { [weak self] sb, sync in
            guard let self else { return }
            if !self.gotFirstFrame {
                self.gotFirstFrame = true
                var status = "playback"
                if let f = self.parser.format {
                    let d = CMVideoFormatDescriptionGetDimensions(f)
                    status = "\(d.width)×\(d.height)"
                }
                self.report(status)
                if ProcessInfo.processInfo.environment["HIK_DEBUG"] != nil {
                    let dt = Date().timeIntervalSince(self.launchTime)
                    FileHandle.standardError.write(Data(String(format: "[playback] first frame in %.2fs\n", dt).utf8))
                }
            }
            self.onSample?(sb, sync)
        }
    }

    func start() {
        Thread.detachNewThread { [weak self] in self?.run() }
    }

    func stop() {
        lock.lock()
        stopped = true
        if fd >= 0 { close(fd); fd = -1 }   // unblocks the reader thread
        lock.unlock()
        keepalive?.cancel()
        keepalive = nil
    }

    // MARK: session (worker thread)

    private func run() {
        report("connecting…")
        guard let sock = connectSocket() else { fail("NVR unreachable"); return }
        lock.lock()
        if stopped { lock.unlock(); close(sock); return }
        fd = sock
        lock.unlock()

        var tv = timeval(tv_sec: 12, tv_usec: 0)   // stalled session watchdog
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(4))

        // DESCRIBE (expect a 401 first to learn realm/nonce), SETUP, PLAY.
        guard var resp = request("DESCRIBE", uri, ["Accept: application/sdp"]) else { fail("NVR unreachable"); return }
        if resp.code == 401 {
            guard parseAuthChallenge(resp.head), let again = request("DESCRIBE", uri, ["Accept: application/sdp"]) else {
                fail("auth failed"); return
            }
            resp = again
        }
        guard resp.code == 200 else { fail("playback refused (\(resp.code))"); return }

        guard let setup = request("SETUP", uri + "/trackID=video",
                                  ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"]),
              setup.code == 200,
              let sess = firstMatch("Session: *([^;\r\n]+)", in: setup.head) else {
            fail("playback setup failed"); return
        }
        sessionID = sess

        var playHeaders = ["Session: \(sessionID)", "Range: clock=\(startClock)-"]
        if scale > 1 { playHeaders.append("Scale: \(scale).000") }
        guard let play = request("PLAY", uri, playHeaders), play.code == 200 else {
            fail("playback failed"); return
        }

        startKeepalive()
        readLoop()
    }

    /// After PLAY: interleaved binary frames ($-prefixed) mixed with the odd
    /// RTSP text response (keepalive replies) — video is channel 0.
    private func readLoop() {
        while true {
            guard let head = readExact(4) else { ended(); return }
            if head[head.startIndex] == 0x24 {  // '$'
                let channel = head[head.startIndex + 1]
                let len = Int(head[head.startIndex + 2]) << 8 | Int(head[head.startIndex + 3])
                guard let payload = readExact(len) else { ended(); return }
                if channel == 0 { handleRTP([UInt8](payload)) }
            } else {
                guard consumeTextResponse(alreadyRead: head) else { ended(); return }
            }
        }
    }

    private func ended() {
        lock.lock()
        let wasStopped = stopped
        lock.unlock()
        guard !wasStopped else { return }
        report("ended")
        DispatchQueue.main.async { self.onEnded?() }
    }

    private func fail(_ status: String) {
        report(status)
        DispatchQueue.main.async { self.onEnded?() }
    }

    private func report(_ status: String) {
        DispatchQueue.main.async { self.onState?(status) }
    }

    /// RTSP keepalive — Hikvision expires sessions without traffic (~60 s).
    private func startKeepalive() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + 25, repeating: 25)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.cseq += 1
            let msg = "OPTIONS \(self.uri) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nSession: \(self.sessionID)\r\n\(self.authHeader("OPTIONS", self.uri))\r\n"
            self.lock.lock()
            let sock = self.fd
            self.lock.unlock()
            guard sock >= 0 else { return }
            _ = msg.withCString { write(sock, $0, strlen($0)) }
        }
        t.resume()
        keepalive = t
    }

    // MARK: RTP depacketization -> Annex B -> parser

    private func handleRTP(_ p: [UInt8]) {
        guard p.count > 12, p[0] >> 6 == 2 else { return }
        var offset = 12 + Int(p[0] & 0x0F) * 4          // fixed header + CSRCs
        if p[0] & 0x10 != 0 {                           // extension header
            guard p.count >= offset + 4 else { return }
            offset += 4 + (Int(p[offset + 2]) << 8 | Int(p[offset + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0 { end -= Int(p[end - 1]) }  // padding
        guard offset < end else { return }
        let payload = Array(p[offset..<end])

        switch codec {
        case .hevc: depacketizeHEVC(payload)
        case .h264: depacketizeH264(payload)
        }
    }

    private func emit(_ nal: [UInt8]) {
        guard !nal.isEmpty else { return }
        var annexB: [UInt8] = [0, 0, 0, 1]
        annexB += nal
        parser.push(Data(annexB))
    }

    /// RFC 7798: 48 = aggregation packet, 49 = fragmentation unit, else one NAL.
    private func depacketizeHEVC(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        let type = (p[0] >> 1) & 0x3F
        switch type {
        case 48:
            var i = 2
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.count else { return }
                emit(Array(p[i..<i + size]))
                i += size
            }
        case 49:
            guard p.count >= 3 else { return }
            let fu = p[2]
            let start = fu & 0x80 != 0, endBit = fu & 0x40 != 0
            if start {
                fuNAL = [(p[0] & 0x81) | ((fu & 0x3F) << 1), p[1]]
            }
            guard !fuNAL.isEmpty else { return }    // lost the start fragment
            fuNAL += p[3...]
            if endBit {
                emit(fuNAL)
                fuNAL = []
            }
        default:
            emit(p)
        }
    }

    /// RFC 6184: 24 = STAP-A, 28 = FU-A, else one NAL.
    private func depacketizeH264(_ p: [UInt8]) {
        guard p.count >= 1 else { return }
        let type = p[0] & 0x1F
        switch type {
        case 24:
            var i = 1
            while i + 2 <= p.count {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= p.count else { return }
                emit(Array(p[i..<i + size]))
                i += size
            }
        case 28:
            guard p.count >= 2 else { return }
            let fu = p[1]
            let start = fu & 0x80 != 0, endBit = fu & 0x40 != 0
            if start {
                fuNAL = [(p[0] & 0xE0) | (fu & 0x1F)]
            }
            guard !fuNAL.isEmpty else { return }
            fuNAL += p[2...]
            if endBit {
                emit(fuNAL)
                fuNAL = []
            }
        default:
            emit(p)
        }
    }

    // MARK: RTSP plumbing

    private func request(_ method: String, _ requestURI: String, _ headers: [String]) -> (code: Int, head: String)? {
        cseq += 1
        var msg = "\(method) \(requestURI) RTSP/1.0\r\nCSeq: \(cseq)\r\n"
        msg += authHeader(method, requestURI)
        for h in headers { msg += h + "\r\n" }
        msg += "\r\n"
        lock.lock()
        let sock = fd
        lock.unlock()
        guard sock >= 0 else { return nil }
        let sent = msg.withCString { write(sock, $0, strlen($0)) }
        guard sent > 0 else { return nil }
        return readResponse()
    }

    private func authHeader(_ method: String, _ requestURI: String) -> String {
        guard !realm.isEmpty else { return "" }
        let ha1 = md5Hex("\(user):\(realm):\(password)")
        let ha2 = md5Hex("\(method):\(requestURI)")
        let response = md5Hex("\(ha1):\(nonce):\(ha2)")
        return "Authorization: Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(requestURI)\", response=\"\(response)\"\r\n"
    }

    private func parseAuthChallenge(_ head: String) -> Bool {
        guard let r = firstMatch("realm=\"([^\"]+)\"", in: head),
              let n = firstMatch("nonce=\"([^\"]+)\"", in: head) else { return false }
        realm = r
        nonce = n
        return true
    }

    private func readResponse() -> (code: Int, head: String)? {
        var acc = Data()
        let sep = Data("\r\n\r\n".utf8)
        while acc.range(of: sep) == nil {
            guard let b = readExact(1) else { return nil }
            acc.append(b)
            if acc.count > 65536 { return nil }
        }
        let head = String(data: acc, encoding: .utf8) ?? ""
        if let clStr = firstMatch("Content-Length: *(\\d+)", in: head), let cl = Int(clStr), cl > 0 {
            guard readExact(cl) != nil else { return nil }
        }
        guard let codeStr = firstMatch("RTSP/1\\.0 (\\d+)", in: head), let code = Int(codeStr) else { return nil }
        return (code, head)
    }

    /// A text response arriving mid-stream (keepalive reply) whose first 4
    /// bytes were already consumed by the interleave reader.
    private func consumeTextResponse(alreadyRead: Data) -> Bool {
        var acc = alreadyRead
        let sep = Data("\r\n\r\n".utf8)
        while acc.range(of: sep) == nil {
            guard let b = readExact(1) else { return false }
            acc.append(b)
            if acc.count > 65536 { return false }
        }
        let head = String(data: acc, encoding: .utf8) ?? ""
        if let clStr = firstMatch("Content-Length: *(\\d+)", in: head), let cl = Int(clStr), cl > 0 {
            guard readExact(cl) != nil else { return false }
        }
        return true
    }

    private func readExact(_ n: Int) -> Data? {
        guard n >= 0 else { return nil }
        while readBuf.count < n {
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            lock.lock()
            let sock = fd
            lock.unlock()
            guard sock >= 0 else { return nil }
            let got = read(sock, &buf, buf.count)
            guard got > 0 else { return nil }   // EOF, error, or 12 s stall
            readBuf.append(contentsOf: buf[0..<got])
        }
        let out = readBuf.prefix(n)
        readBuf.removeFirst(n)
        return out
    }

    private func connectSocket() -> Int32? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(info) }
        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock >= 0 else { return nil }
        guard connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            close(sock)
            return nil
        }
        return sock
    }

    private func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
