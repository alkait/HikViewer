// EventConfig.swift — read-only fetch of per-camera event configuration
// through the NVR: motion + intrusion (field detection) enabled state, their
// arming schedules, and the intrusion zone polygons. Feeds the nerd-stats
// panel's motion/intrusion rows and the zone overlay. GETs only — nothing
// here writes to the NVR or cameras.

import Foundation
import CoreGraphics

/// What the panel shows for one camera. Composed on the fly from the store's
/// caches, so fields fill in as fetches land.
struct ChannelEvents {
    enum State { case loading, on, off, unknown }
    var motion = State.loading
    var motionSchedule: String?          // nil while the schedule list loads
    var intrusion = State.loading
    var intrusionSchedule: String?
    /// Configured detection areas, normalized 0–1 polygons with a bottom-left
    /// origin (y up) — same as AppKit. Intrusion zones come straight from the
    /// camera's VCA polygons; motion areas are the camera's detection grid
    /// with runs of enabled cells merged into rectangles.
    var motionRegions: [[CGPoint]] = []
    var intrusionRegions: [[CGPoint]] = []
    /// AcuSense target filters ("human", "vehicle", "human+vehicle"); nil on
    /// cameras without target classification. Intrusion is the union across
    /// its active zones.
    var motionTargets: String?
    var intrusionTargets: String?
}

enum EventInfoResult {
    case noNVR              // no NVR configured in Settings
    case connecting         // NVR channel map still loading
    case notRecorded        // camera isn't a channel on this NVR
    case ready(ChannelEvents)
}

/// Per-channel event config cache. Main-thread only; `info` kicks the fetches
/// it is missing and returns whatever is cached so far. Everything expires
/// together after 5 minutes so config edits on the NVR eventually show up.
final class EventInfoStore {
    private struct PerChannel {
        var motion: ChannelEvents.State = .loading
        var intrusion: ChannelEvents.State = .loading
        var motionRegions: [[CGPoint]] = []
        var regions: [[CGPoint]] = []
        var motionTargets: String?
        var intrusionTargets: String?
    }

    private var host = ""
    private var perChannel: [Int: PerChannel] = [:]
    private var fetching = Set<Int>()
    private var motionSched: [Int: String]?      // nil = not loaded yet
    private var intrusionSched: [Int: String]?
    private var schedFetching = false
    private var stamp = Date.distantPast

    func info(nvrHost: String, channel: Int) -> ChannelEvents {
        if nvrHost != host || Date().timeIntervalSince(stamp) > 300 {
            host = nvrHost
            perChannel = [:]
            fetching = []
            motionSched = nil
            intrusionSched = nil
            schedFetching = false
            stamp = Date()
        }
        fetchChannel(channel)
        fetchSchedules()

        var out = ChannelEvents()
        if let pc = perChannel[channel] {
            out.motion = pc.motion
            out.intrusion = pc.intrusion
            out.motionRegions = pc.motionRegions
            out.intrusionRegions = pc.regions
            out.motionTargets = pc.motionTargets
            out.intrusionTargets = pc.intrusionTargets
        }
        // Loaded schedule list with no entry for this channel = never armed.
        out.motionSchedule = motionSched.map { $0[channel] ?? "never" }
        out.intrusionSchedule = intrusionSched.map { $0[channel] ?? "never" }
        return out
    }

    // MARK: fetches (read-only GETs; digest auth comes from ISAPI.session)

    private func get(_ path: String, done: @escaping (Data?) -> Void) {
        guard let u = URL(string: "http://\(host)\(path)") else { done(nil); return }
        var req = URLRequest(url: u)
        req.timeoutInterval = 8
        ISAPI.session.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async { done(data) }
        }.resume()
    }

    private func fetchChannel(_ ch: Int) {
        guard perChannel[ch] == nil, !fetching.contains(ch) else { return }
        fetching.insert(ch)
        var pc = PerChannel()
        var landed = 0
        func land() {
            landed += 1
            guard landed == 2 else { return }
            fetching.remove(ch)
            perChannel[ch] = pc
        }
        get("/ISAPI/System/Video/inputs/channels/\(ch)/motionDetection") { data in
            if let data {
                let p = MotionDetectionParser()
                let xml = XMLParser(data: data)
                xml.delegate = p
                xml.parse()
                pc.motion = p.sawEnabled ? (p.enabled ? .on : .off) : .unknown
                // Grid cameras carry both a gridMap and a (redundant) polygon
                // list — the grid is the authoritative regionType.
                if !p.gridMap.isEmpty, p.rows > 0, p.cols > 0 {
                    pc.motionRegions = Self.gridPolygons(map: p.gridMap, rows: p.rows, cols: p.cols)
                } else {
                    pc.motionRegions = p.regions
                }
                pc.motionTargets = Self.targetLabel(p.targetType)
            } else {
                pc.motion = .unknown
            }
            land()
        }
        get("/ISAPI/Smart/FieldDetection/\(ch)") { data in
            if let data {
                let p = FieldDetectionParser()
                let xml = XMLParser(data: data)
                xml.delegate = p
                xml.parse()
                pc.intrusion = p.sawEnabled ? (p.enabled ? .on : .off) : .unknown
                pc.regions = p.regions
                pc.intrusionTargets = Self.targetLabel(p.targets.joined(separator: ","))
            } else {
                pc.intrusion = .unknown
            }
            land()
        }
    }

    private func fetchSchedules() {
        guard motionSched == nil, !schedFetching else { return }
        schedFetching = true
        var landed = 0
        var motion: [Int: String] = [:], intrusion: [Int: String] = [:]
        func land() {
            landed += 1
            guard landed == 2 else { return }
            schedFetching = false
            motionSched = motion
            intrusionSched = intrusion
        }
        func fetch(_ path: String, into out: @escaping ([Int: String]) -> Void) {
            get(path) { data in
                var summaries: [Int: String] = [:]
                if let data {
                    let p = ScheduleListParser()
                    let xml = XMLParser(data: data)
                    xml.delegate = p
                    xml.parse()
                    summaries = p.blocks.mapValues { Self.summarize($0) }
                }
                out(summaries)
                land()
            }
        }
        fetch("/ISAPI/Event/schedules/motionDetections") { motion = $0 }
        fetch("/ISAPI/Event/schedules/fieldDetections") { intrusion = $0 }
    }

    /// "human,vehicle" (any order, duplicates) -> "human+vehicle"; empty/nil
    /// -> nil (camera has no AcuSense target filter on this event).
    static func targetLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var seen: [String] = []
        for t in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !t.isEmpty && !seen.contains(t) {
            seen.append(t)
        }
        return seen.isEmpty ? nil : seen.sorted().joined(separator: "+")
    }

    /// Motion grid -> polygons: decode the row-major hex bitmap (each row
    /// padded to whole bytes, MSB = leftmost column, row 0 = top of frame),
    /// then merge vertical runs of identical row-spans into rectangles so the
    /// overlay is a few clean shapes instead of hundreds of cells.
    static func gridPolygons(map: String, rows: Int, cols: Int) -> [[CGPoint]] {
        let charsPerRow = (cols + 7) / 8 * 2
        let chars = Array(map)
        guard rows > 0, cols > 0, chars.count >= rows * charsPerRow else { return [] }
        var bits = [[Bool]](repeating: [Bool](repeating: false, count: cols), count: rows)
        for r in 0..<rows {
            for b in 0..<charsPerRow / 2 {
                let i = r * charsPerRow + b * 2
                guard let v = UInt8(String(chars[i...i + 1]), radix: 16) else { continue }
                for bit in 0..<8 where b * 8 + bit < cols {
                    if v & (0x80 >> bit) != 0 { bits[r][b * 8 + bit] = true }
                }
            }
        }
        var rects: [(c0: Int, c1: Int, r0: Int, r1: Int)] = []
        var open: [(c0: Int, c1: Int, r0: Int)] = []
        for r in 0..<rows {
            var runs: [(Int, Int)] = []
            var c = 0
            while c < cols {
                guard bits[r][c] else { c += 1; continue }
                var e = c
                while e + 1 < cols, bits[r][e + 1] { e += 1 }
                runs.append((c, e))
                c = e + 1
            }
            var next: [(c0: Int, c1: Int, r0: Int)] = []
            for run in runs {
                if let i = open.firstIndex(where: { $0.c0 == run.0 && $0.c1 == run.1 }) {
                    next.append(open.remove(at: i))
                } else {
                    next.append((run.0, run.1, r))
                }
            }
            for o in open { rects.append((o.c0, o.c1, o.r0, r - 1)) }
            open = next
        }
        for o in open { rects.append((o.c0, o.c1, o.r0, rows - 1)) }
        return rects.map { rc in
            let x0 = CGFloat(rc.c0) / CGFloat(cols), x1 = CGFloat(rc.c1 + 1) / CGFloat(cols)
            let yT = 1 - CGFloat(rc.r0) / CGFloat(rows), yB = 1 - CGFloat(rc.r1 + 1) / CGFloat(rows)
            return [CGPoint(x: x0, y: yB), CGPoint(x: x1, y: yB),
                    CGPoint(x: x1, y: yT), CGPoint(x: x0, y: yT)]
        }
    }

    // MARK: schedule summary

    /// Compact one-line arming summary: "24/7", "daily 01:30–05:30",
    /// "Mon–Fri 08:00–17:00; Sat 10:00–12:00". dayOfWeek 1 = Monday; a block
    /// with no dayOfWeek is the holiday row — appended only when it differs.
    static func summarize(_ blocks: [(day: Int, begin: String, end: String)]) -> String {
        func hhmm(_ s: String) -> String { String(s.prefix(5)) }
        let live = blocks.filter { $0.begin != $0.end }          // zero-length = disabled
        let week = live.filter { $0.day <= 7 }
        let holiday = live.filter { $0.day > 7 }
            .map { "\(hhmm($0.begin))–\(hhmm($0.end))" }.sorted().joined(separator: ",")

        var summary: String
        if week.isEmpty {
            summary = "never"
        } else {
            var perDay: [Int: String] = [:]
            for d in Set(week.map { $0.day }) {
                perDay[d] = week.filter { $0.day == d }
                    .map { "\(hhmm($0.begin))–\(hhmm($0.end))" }.sorted().joined(separator: ",")
            }
            if perDay.count == 7, Set(perDay.values).count == 1 {
                let r = perDay.values.first!
                summary = r == "00:00–24:00" ? "24/7" : "daily \(r)"
            } else {
                let names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                var parts: [String] = []
                var d = 1
                while d <= 7 {
                    guard let r = perDay[d] else { d += 1; continue }
                    var e = d
                    while e + 1 <= 7, perDay[e + 1] == r { e += 1 }
                    parts.append("\(d == e ? names[d] : "\(names[d])–\(names[e])") \(r)")
                    d = e + 1
                }
                summary = parts.joined(separator: "; ")
            }
        }
        if !holiday.isEmpty, summary != "24/7" || holiday != "00:00–24:00" {
            summary += " · hol \(holiday == "00:00–24:00" ? "24h" : holiday)"
        }
        return summary
    }
}

/// <MotionDetection>: top-level <enabled>, the grid granularity + gridMap
/// (regionType "grid"), and the RegionList polygons some cameras use instead.
private final class MotionDetectionParser: NSObject, XMLParserDelegate {
    var enabled = false
    var sawEnabled = false
    var rows = 0, cols = 0
    var gridMap = ""
    var regions: [[CGPoint]] = []
    var targetType: String?             // AcuSense filter, e.g. "human,vehicle"
    private var current: [CGPoint] = []
    private var x: Double?
    private var text = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "Region" { current = []; x = nil }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "enabled":                     // first one is the top-level toggle
            if !sawEnabled { enabled = (value == "true"); sawEnabled = true }
        case "rowGranularity": rows = Int(value) ?? 0
        case "columnGranularity": cols = Int(value) ?? 0
        case "gridMap": gridMap = value
        case "targetType": targetType = value
        case "positionX": x = Double(value)
        case "positionY":
            if let px = x, let y = Double(value) {
                current.append(CGPoint(x: px / 1000, y: y / 1000))
                x = nil
            }
        case "Region":
            if current.count >= 3 { regions.append(current) }
        default: break
        }
    }
}

/// <FieldDetection><enabled>…, then FieldDetectionRegion polygons. Regions
/// with fewer than 3 points are unused slots (the NVR always reports 4).
private final class FieldDetectionParser: NSObject, XMLParserDelegate {
    var enabled = false
    var sawEnabled = false
    var regions: [[CGPoint]] = []
    var targets: [String] = []          // detectionTarget of each active zone
    private var current: [CGPoint] = []
    private var target = ""
    private var x: Double?
    private var text = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "FieldDetectionRegion" { current = []; target = ""; x = nil }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "enabled":                     // top-level; regions carry none
            if !sawEnabled { enabled = (value == "true"); sawEnabled = true }
        case "detectionTarget": target = value
        case "positionX": x = Double(value)
        case "positionY":
            if let px = x, let y = Double(value) {
                current.append(CGPoint(x: px / 1000, y: y / 1000))
                x = nil
            }
        case "FieldDetectionRegion":
            if current.count >= 3 {
                regions.append(current)
                if !target.isEmpty { targets.append(target) }
            }
        default: break
        }
    }
}

/// One of the /ISAPI/Event/schedules/* lists: every channel's TimeBlocks in a
/// single document. A TimeBlock without <dayOfWeek> is the holiday row
/// (stored as day 8).
private final class ScheduleListParser: NSObject, XMLParserDelegate {
    var blocks: [Int: [(day: Int, begin: String, end: String)]] = [:]
    private var channel: Int?
    private var day: Int?
    private var begin = "", end = ""
    private var text = ""

    func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "Schedule": channel = nil
        case "TimeBlock": day = nil; begin = ""; end = ""
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "videoInputChannelID", "dynVideoInputChannelID": channel = Int(value)
        case "dayOfWeek": day = Int(value)
        case "beginTime": begin = value
        case "endTime": end = value
        case "TimeBlock":
            if let ch = channel, !begin.isEmpty, !end.isEmpty {
                blocks[ch, default: []].append((day ?? 8, begin, end))
            }
        default: break
        }
    }
}
