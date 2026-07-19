// NVRClient.swift — read-only ISAPI client for the NVR's recordings.
//
// Three things: channel discovery (camera IP -> NVR channel, so playback needs
// zero per-camera setup), the NVR's UTC offset, and recorded-segment search.
// Timestamps over ISAPI carry a 'Z' suffix but are actually the NVR's *local*
// time (long-standing Hikvision quirk — a real UTC "future" time gets a 400),
// so every format/parse here uses the NVR's own offset, never the Mac's.

import Foundation

struct RecordingSegment {
    let start: Date
    let end: Date
}

final class NVRClient {
    let nvr: StoredNVR
    private(set) var timeZone = TimeZone.current
    private(set) var channelByHost: [String: Int] = [:]   // main thread
    private var ready = false

    init(nvr: StoredNVR) { self.nvr = nvr }

    /// Fetch the timezone + channel map once; later calls hit the cache.
    /// Completion on main.
    func prepare(completion: @escaping (Bool) -> Void) {
        if ready { DispatchQueue.main.async { completion(true) }; return }
        get("/ISAPI/System/time") { [weak self] data in
            guard let self else { return }
            if let data, let xml = String(data: data, encoding: .utf8),
               let tz = Self.parseTimeZone(xml) {
                self.timeZone = tz
            }
            self.get("/ISAPI/ContentMgmt/InputProxy/channels") { data in
                let map = data.map(Self.parseChannels) ?? [:]
                DispatchQueue.main.async {
                    self.channelByHost = map
                    self.ready = !map.isEmpty
                    completion(self.ready)
                }
            }
        }
    }

    /// Recording track for an NVR channel: main-stream recording is
    /// channel*100 + 1 (channel 7 -> track 701).
    static func track(forChannel ch: Int) -> Int { ch * 100 + 1 }

    /// All recorded segments for `track` in [from, to), merged and sorted.
    /// Pages through the search API (the NVR caps each response). Completion
    /// on main.
    func searchSegments(track: Int, from: Date, to: Date, completion: @escaping ([RecordingSegment]) -> Void) {
        let searchID = UUID().uuidString
        let inFmt = formatter("yyyy-MM-dd'T'HH:mm:ss'Z'")
        var all: [RecordingSegment] = []

        func page(_ position: Int) {
            guard let u = URL(string: "http://\(nvr.host)/ISAPI/ContentMgmt/search") else {
                DispatchQueue.main.async { completion([]) }; return
            }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 10
            let body = """
            <?xml version="1.0" encoding="utf-8"?>
            <CMSearchDescription>
            <searchID>\(searchID)</searchID>
            <trackList><trackID>\(track)</trackID></trackList>
            <timeSpanList><timeSpan><startTime>\(inFmt.string(from: from))</startTime><endTime>\(inFmt.string(from: to))</endTime></timeSpan></timeSpanList>
            <maxResults>64</maxResults>
            <searchResultPostion>\(position)</searchResultPostion>
            <metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList>
            </CMSearchDescription>
            """
            req.httpBody = Data(body.utf8)
            ISAPI.session.dataTask(with: req) { data, _, _ in
                guard let data else { DispatchQueue.main.async { completion(Self.merge(all)) }; return }
                let parser = SearchResultParser()
                let xml = XMLParser(data: data)
                xml.delegate = parser
                xml.parse()
                let segs = parser.spans.compactMap { span -> RecordingSegment? in
                    guard let s = inFmt.date(from: span.0), let e = inFmt.date(from: span.1), e > s else { return nil }
                    return RecordingSegment(start: s, end: e)
                }
                all.append(contentsOf: segs)
                if parser.more && !segs.isEmpty {
                    page(position + segs.count)
                } else {
                    DispatchQueue.main.async { completion(Self.merge(all)) }
                }
            }.resume()
        }
        page(0)
    }

    /// Which days of a month have any recording on `track` (drives the
    /// calendar's enabled days). Completion on main.
    func recordedDays(track: Int, year: Int, month: Int, completion: @escaping (Set<Int>) -> Void) {
        guard let u = URL(string: "http://\(nvr.host)/ISAPI/ContentMgmt/record/tracks/\(track)/dailyDistribution") else {
            DispatchQueue.main.async { completion([]) }; return
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        req.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <trackDailyParam><year>\(year)</year><monthOfYear>\(month)</monthOfYear></trackDailyParam>
        """.utf8)
        ISAPI.session.dataTask(with: req) { data, _, _ in
            var days: Set<Int> = []
            if let data {
                let delegate = DailyDistributionParser()
                let xml = XMLParser(data: data)
                xml.delegate = delegate
                xml.parse()
                days = delegate.recordedDays
            }
            DispatchQueue.main.async { completion(days) }
        }.resume()
    }

    // MARK: motion (generic + human/vehicle classified)

    private var motionCache: [String: (stamp: Date, spans: [Int: [RecordingSegment]])] = [:]
    private var targetCache: [String: (stamp: Date, spans: [RecordingSegment])] = [:]

    /// Past days never change; today's entries go stale as new events land.
    private func cacheValid(_ stamp: Date, windowEnd: Date) -> Bool {
        windowEnd < Date() || Date().timeIntervalSince(stamp) < 60
    }

    /// Generic motion spans for ALL channels in [from, to), from the NVR's
    /// alarm log (motionStart/motionStop pairs — the recordings themselves are
    /// continuous and carry no motion typing). One fetch serves every camera.
    /// Completion on main.
    func motionLog(from: Date, to: Date, completion: @escaping ([Int: [RecordingSegment]]) -> Void) {
        let key = "\(Int(from.timeIntervalSince1970))"
        if let hit = motionCache[key], cacheValid(hit.stamp, windowEnd: to) {
            DispatchQueue.main.async { completion(hit.spans) }
            return
        }
        let outFmt = formatter("yyyy-MM-dd'T'HH:mm:ss'Z'")   // request: fake-Z local
        let inFmt = formatter("yyyy-MM-dd'T'HH:mm:ss")       // response: local, no suffix
        var events: [(channel: Int, isStart: Bool, time: Date)] = []

        func finish() {
            let spans = Self.pairMotionEvents(events, from: from, to: to)
            DispatchQueue.main.async {
                self.motionCache[key] = (Date(), spans)
                completion(spans)
            }
        }
        func page(_ position: Int) {
            guard let u = URL(string: "http://\(nvr.host)/ISAPI/ContentMgmt/logSearch") else { finish(); return }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 10
            let body = """
            <CMSearchDescription><searchID>\(UUID().uuidString)</searchID><metaId>log.std-cgi.com</metaId>\
            <timeSpanList><timeSpan><startTime>\(outFmt.string(from: from))</startTime><endTime>\(outFmt.string(from: to))</endTime></timeSpan></timeSpanList>\
            <maxResults>64</maxResults><searchResultPostion>\(position)</searchResultPostion>\
            <metadataList><metadataDescriptor>//metadata.std-cgi.com/types/logs?name=alarm&amp;subName=motionalarm</metadataDescriptor></metadataList>\
            </CMSearchDescription>
            """
            req.httpBody = Data(body.utf8)
            ISAPI.session.dataTask(with: req) { data, _, _ in
                guard let data else { finish(); return }
                let parser = MotionLogParser()
                let xml = XMLParser(data: data)
                xml.delegate = parser
                xml.parse()
                for item in parser.items {
                    // metaId: log.hikvision.com/Alarm/motionStart/15
                    let parts = item.metaId.split(separator: "/")
                    guard parts.count >= 2, let ch = Int(parts[parts.count - 1]),
                          let t = inFmt.date(from: item.time) else { continue }
                    let kind = parts[parts.count - 2]
                    if kind == "motionStart" { events.append((ch, true, t)) }
                    else if kind == "motionStop" { events.append((ch, false, t)) }
                }
                if parser.more && !parser.items.isEmpty { page(position + parser.items.count) }
                else { finish() }
            }.resume()
        }
        page(0)
    }

    static func pairMotionEvents(_ events: [(channel: Int, isStart: Bool, time: Date)],
                                 from: Date, to: Date) -> [Int: [RecordingSegment]] {
        var out: [Int: [RecordingSegment]] = [:]
        var open: [Int: Date] = [:]
        for e in events.sorted(by: { $0.time < $1.time }) {
            if e.isStart {
                if open[e.channel] == nil { open[e.channel] = e.time }
            } else if let s = open.removeValue(forKey: e.channel) {
                out[e.channel, default: []].append(RecordingSegment(start: s, end: e.time))
            } else {
                // Stop without a start: motion began before the window.
                out[e.channel, default: []].append(RecordingSegment(start: from, end: e.time))
            }
        }
        let clamp = min(to, Date())
        for (ch, s) in open where s < clamp {
            out[ch, default: []].append(RecordingSegment(start: s, end: clamp))
        }
        return out.mapValues { merge($0) }
    }

    /// AcuSense-classified motion spans ("human" or "vehicle") for one channel
    /// in [from, to) via /ISAPI/ContentMgmt/SearchByTargetType — the same API
    /// behind the NVR web player's Human/Vehicle checkboxes. Unlike the XML
    /// APIs this one speaks real ISO 8601 with offsets, not fake-Z local time.
    /// Completion on main.
    func classifiedSpans(channel: Int, from: Date, to: Date, type: String,
                         completion: @escaping ([RecordingSegment]) -> Void) {
        let key = "\(channel)|\(type)|\(Int(from.timeIntervalSince1970))"
        if let hit = targetCache[key], cacheValid(hit.stamp, windowEnd: to) {
            DispatchQueue.main.async { completion(hit.spans) }
            return
        }
        let fmt = formatter("yyyy-MM-dd'T'HH:mm:ssZZZZZ")
        let iso = ISO8601DateFormatter()
        var all: [RecordingSegment] = []

        func finish() {
            let spans = Self.merge(all)
            DispatchQueue.main.async {
                self.targetCache[key] = (Date(), spans)
                completion(spans)
            }
        }
        func page(_ position: Int) {
            guard let u = URL(string: "http://\(nvr.host)/ISAPI/ContentMgmt/SearchByTargetType?format=json") else {
                finish(); return
            }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 10
            let body: [String: Any] = ["SearchDescription": [
                "searchID": UUID().uuidString,
                "searchResultPosition": position,
                "maxResults": 100,
                "SearchCondList": [[
                    "channelID": channel,
                    "targetTypes": [type],
                    "searchTimeList": [["searchTime": [
                        "startTime": fmt.string(from: from),
                        "endTime": fmt.string(from: to),
                    ]]],
                ]],
            ]]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            ISAPI.session.dataTask(with: req) { data, _, _ in
                guard let data,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = root["SearchResult"] as? [String: Any] else { finish(); return }
                let status = result["responseStatusStrg"] as? String ?? ""
                var count = 0
                for match in result["matchList"] as? [[String: Any]] ?? [] {
                    for info in match["RecordInfoList"] as? [[String: Any]] ?? [] {
                        count += 1
                        guard let rt = info["RecordTime"] as? [String: Any],
                              let s = (rt["startTime"] as? String).flatMap(iso.date(from:)),
                              let e = (rt["endTime"] as? String).flatMap(iso.date(from:)),
                              e > s else { continue }
                        all.append(RecordingSegment(start: s, end: e))
                    }
                }
                if status == "MORE", count > 0 { page(position + count) }
                else { finish() }
            }.resume()
        }
        page(0)
    }

    /// RTSP path + clock string replaying `track` for [from, to) — consumed by
    /// PlaybackStream. The NVR stops sending at `to`; the stalled read is the
    /// "segment ended" signal.
    func playbackRequest(track: Int, from: Date, to: Date) -> (path: String, startClock: String) {
        let f = formatter("yyyyMMdd'T'HHmmss'Z'")
        let s = f.string(from: from)
        return ("/Streaming/tracks/\(track)/?starttime=\(s)&endtime=\(f.string(from: to))", s)
    }

    func formatter(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        f.timeZone = timeZone
        return f
    }

    private func get(_ path: String, completion: @escaping (Data?) -> Void) {
        guard let u = URL(string: "http://\(nvr.host)\(path)") else { completion(nil); return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        ISAPI.session.dataTask(with: req) { data, _, _ in completion(data) }.resume()
    }

    // MARK: XML plumbing

    /// Offset from <localTime>2026-07-19T08:32:13+04:00</localTime>.
    static func parseTimeZone(_ xml: String) -> TimeZone? {
        guard let r1 = xml.range(of: "<localTime>"), let r2 = xml.range(of: "</localTime>") else { return nil }
        let t = String(xml[r1.upperBound..<r2.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6 else { return nil }
        let off = String(t.suffix(6))          // "+04:00"
        let sign = off.hasPrefix("-") ? -1 : 1
        let parts = off.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60))
    }

    static func parseChannels(_ data: Data) -> [String: Int] {
        let delegate = ChannelListParser()
        let xml = XMLParser(data: data)
        xml.delegate = delegate
        xml.parse()
        return delegate.map
    }

    static func merge(_ raw: [RecordingSegment]) -> [RecordingSegment] {
        let sorted = raw.sorted { $0.start < $1.start }
        var out: [RecordingSegment] = []
        for s in sorted {
            if let last = out.last, s.start.timeIntervalSince(last.end) < 2 {
                if s.end > last.end { out[out.count - 1] = RecordingSegment(start: last.start, end: s.end) }
            } else {
                out.append(s)
            }
        }
        return out
    }
}

/// <InputProxyChannel><id>N</id>…<ipAddress>x.x.x.x</ipAddress>… -> [ip: N]
private final class ChannelListParser: NSObject, XMLParserDelegate {
    var map: [String: Int] = [:]
    private var id: Int?
    private var ip: String?
    private var text = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "InputProxyChannel" { id = nil; ip = nil }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "id": if id == nil { id = Int(value) }              // first <id> = the channel's own
        case "ipAddress": if ip == nil, !value.isEmpty { ip = value }
        case "InputProxyChannel": if let id, let ip { map[ip] = id }
        default: break
        }
    }
}

/// <searchMatchItem><logDescriptor><metaId>…/Alarm/motionStart/15</metaId>
/// <StartDateTime>…</StartDateTime>… -> (metaId, time) pairs + MORE marker.
private final class MotionLogParser: NSObject, XMLParserDelegate {
    var items: [(metaId: String, time: String)] = []
    var more = false
    private var metaId = ""
    private var time = ""
    private var text = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "searchMatchItem" { metaId = ""; time = "" }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "metaId": metaId = value
        case "StartDateTime": time = value
        case "searchMatchItem": if !metaId.isEmpty, !time.isEmpty { items.append((metaId, time)) }
        case "responseStatusStrg": more = (value == "MORE")
        default: break
        }
    }
}

/// <day><dayOfMonth>N</dayOfMonth><record>true</record></day> -> {N, …}
private final class DailyDistributionParser: NSObject, XMLParserDelegate {
    var recordedDays: Set<Int> = []
    private var day: Int?
    private var recorded = false
    private var text = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "day" { day = nil; recorded = false }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "dayOfMonth": day = Int(value)
        case "record": recorded = (value == "true")
        case "day": if let day, recorded { recordedDays.insert(day) }
        default: break
        }
    }
}

/// Pulls (startTime, endTime) pairs out of each <searchMatchItem>, plus the
/// MORE marker that drives pagination.
private final class SearchResultParser: NSObject, XMLParserDelegate {
    var spans: [(String, String)] = []
    var more = false
    private var inMatch = false
    private var start: String?
    private var text = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "searchMatchItem" { inMatch = true; start = nil }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "startTime": if inMatch { start = value }
        case "endTime": if inMatch, let s = start { spans.append((s, value)); start = nil }
        case "searchMatchItem": inMatch = false
        case "responseStatusStrg": more = (value == "MORE")
        default: break
        }
    }
}
