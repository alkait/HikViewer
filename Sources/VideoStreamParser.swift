// VideoStreamParser.swift — Annex B (HEVC / H.264) parsing -> CMSampleBuffers.

import Foundation
import CoreMedia

/// Splits an Annex B byte stream (HEVC or H.264) into NAL units, groups slices
/// into access units, and emits one CMSampleBuffer per frame (length-prefixed
/// NALs, as CMVideoFormatDescription with nalUnitHeaderLength=4 expects).
final class VideoStreamParser {
    private let codec: VideoCodec
    private var buf = [UInt8]()
    private var inNAL = false
    private var scanned = 0

    private var vps: [UInt8]?   // HEVC only
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var fmtKey = 0
    private(set) var format: CMVideoFormatDescription?

    private var au = [[UInt8]]()
    private var auIsIRAP = false
    private var seenIRAP = false

    var onAccessUnit: ((CMSampleBuffer, _ isSync: Bool) -> Void)?

    init(codec: VideoCodec) { self.codec = codec }

    /// Drop partial data after a pipe restart; keep parameter sets (the camera
    /// resends them before every IDR anyway).
    func reset() {
        buf.removeAll()
        inNAL = false
        scanned = 0
        au.removeAll()
        auIsIRAP = false
        seenIRAP = false
    }

    func push(_ data: Data) {
        buf.append(contentsOf: data)
        var start = inNAL ? 0 : -1
        var pos = scanned
        let n = buf.count
        // Scan for 00 00 01 only; a 4-byte 00 00 00 01 leaves one trailing
        // zero on the previous NAL, stripped in handleNAL.
        while pos + 3 <= n {
            if buf[pos] == 0 && buf[pos + 1] == 0 && buf[pos + 2] == 1 {
                if start >= 0 { handleNAL(Array(buf[start..<pos])) }
                start = pos + 3
                pos = start
                continue
            }
            pos += 1
        }
        if start >= 0 {
            buf.removeSubrange(0..<start)
            inNAL = true
            scanned = max(0, buf.count - 2)
        } else {
            buf.removeSubrange(0..<max(0, n - 3))
            inNAL = false
            scanned = 0
        }
    }

    private func handleNAL(_ raw: [UInt8]) {
        var nal = raw
        while nal.count > 2 && nal.last == 0 { nal.removeLast() }
        guard nal.count >= 3 else { return }
        switch codec {
        case .hevc:
            let type = (nal[0] >> 1) & 0x3F
            switch type {
            case 32: vps = nal; maybeMakeFormat()
            case 33: sps = nal; maybeMakeFormat()
            case 34: pps = nal; maybeMakeFormat()
            default:
                guard type <= 31 else { return }  // drop SEI/AUD/non-VCL
                let firstSliceInPic = nal[2] & 0x80 != 0  // first_slice_segment_in_pic_flag
                if firstSliceInPic { flushAU() }
                if au.isEmpty { auIsIRAP = (16...21).contains(type) }
                au.append(nal)
            }
        case .h264:
            let type = nal[0] & 0x1F
            switch type {
            case 7: sps = nal; maybeMakeFormat()
            case 8: pps = nal; maybeMakeFormat()
            case 1, 5:  // non-IDR / IDR coded slice
                let firstSliceInPic = nal[1] & 0x80 != 0  // first_mb_in_slice == 0 → leading '1'
                if firstSliceInPic { flushAU() }
                if au.isEmpty { auIsIRAP = (type == 5) }
                au.append(nal)
            default: return  // drop SEI(6)/AUD(9)/etc.
            }
        }
    }

    private func flushAU() {
        defer { au.removeAll(); auIsIRAP = false }
        guard !au.isEmpty, let fmt = format else { return }
        if !seenIRAP {
            guard auIsIRAP else { return }  // can't decode until a keyframe
            seenIRAP = true
        }
        if let sb = makeSampleBuffer(nals: au, fmt: fmt, sync: auIsIRAP) {
            onAccessUnit?(sb, auIsIRAP)
        }
    }

    private func maybeMakeFormat() {
        switch codec {
        case .hevc:
            guard let v = vps, let s = sps, let p = pps else { return }
            var hasher = Hasher()
            hasher.combine(v); hasher.combine(s); hasher.combine(p)
            let key = hasher.finalize()
            if key == fmtKey, format != nil { return }
            v.withUnsafeBufferPointer { vb in s.withUnsafeBufferPointer { sb in p.withUnsafeBufferPointer { pb in
                let ptrs: [UnsafePointer<UInt8>] = [vb.baseAddress!, sb.baseAddress!, pb.baseAddress!]
                let sizes = [v.count, s.count, p.count]
                var fmt: CMFormatDescription?
                if CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 3,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt) == noErr {
                    format = fmt; fmtKey = key
                }
            }}}
        case .h264:
            guard let s = sps, let p = pps else { return }
            var hasher = Hasher()
            hasher.combine(s); hasher.combine(p)
            let key = hasher.finalize()
            if key == fmtKey, format != nil { return }
            s.withUnsafeBufferPointer { sb in p.withUnsafeBufferPointer { pb in
                let ptrs: [UnsafePointer<UInt8>] = [sb.baseAddress!, pb.baseAddress!]
                let sizes = [s.count, p.count]
                var fmt: CMFormatDescription?
                if CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ptrs, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt) == noErr {
                    format = fmt; fmtKey = key
                }
            }}
        }
    }

    private func makeSampleBuffer(nals: [[UInt8]], fmt: CMVideoFormatDescription, sync: Bool) -> CMSampleBuffer? {
        var payload = [UInt8]()
        payload.reserveCapacity(nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            let len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: len) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let bb = block else { return nil }
        let copied = payload.withUnsafeBufferPointer {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sb = sample else { return nil }

        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !sync {
                CFDictionarySetValue(dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }
}
