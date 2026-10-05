import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

enum MirrorService {
    /// Bonjour service type. Overridable per app so the Mac->iPhone app and the
    /// iPhone->Mac app never discover each other by mistake.
    static var type = "_macmirror._tcp"
    static let domain = "local."
}

enum MessageType: UInt8 {
    case videoFormat = 1
    case videoFrame = 2
}

enum VideoCodec: UInt8 {
    case h264 = 1
    case hevc = 2

    var displayName: String { self == .hevc ? "HEVC" : "H.264" }
}

struct MessageHeader {
    static let magic: UInt32 = 0x4D4D_5231 // "MMR1"
    static let size = 12

    var type: MessageType
    var flags: UInt8 = 0
    var length: UInt32

    func encoded() -> Data {
        var d = Data(capacity: MessageHeader.size)
        d.appendUInt32(MessageHeader.magic)
        d.append(type.rawValue)
        d.append(flags)
        d.appendUInt16(0)
        d.appendUInt32(length)
        return d
    }

    static func decode(_ data: Data) -> MessageHeader? {
        guard data.count >= size else { return nil }
        let b = [UInt8](data.prefix(size))
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        guard magic == MessageHeader.magic, let type = MessageType(rawValue: b[4]) else { return nil }
        let len = UInt32(b[8]) << 24 | UInt32(b[9]) << 16 | UInt32(b[10]) << 8 | UInt32(b[11])
        return MessageHeader(type: type, flags: b[5], length: len)
    }
}

struct VideoFrameMessage {
    var presentationTimeStamp: CMTime
    var isKeyframe: Bool
    var data: Data

    func encoded() -> Data {
        var d = Data(capacity: 17 + data.count)
        d.appendInt64(presentationTimeStamp.value)
        d.appendInt32(presentationTimeStamp.timescale)
        d.append(isKeyframe ? 1 : 0)
        d.appendUInt16(0)
        d.appendUInt32(UInt32(data.count))
        d.append(data)
        return d
    }

    static func decode(_ payload: Data) -> VideoFrameMessage? {
        var r = ByteReader(payload)
        guard let value = r.int64(), let timescale = r.int32(), let kf = r.uint8(),
              r.skip(2), let len = r.uint32(), let body = r.bytes(Int(len)) else { return nil }
        return VideoFrameMessage(
            presentationTimeStamp: CMTime(value: value, timescale: timescale),
            isKeyframe: kf != 0,
            data: Data(body))
    }
}

struct VideoFormatMessage {
    var codec: VideoCodec = .h264
    var nalUnitHeaderLength: Int32 = 4
    var parameterSets: [Data]

    func encoded() -> Data {
        var d = Data()
        d.append(codec.rawValue)
        d.appendInt32(nalUnitHeaderLength)
        d.appendUInt32(UInt32(parameterSets.count))
        for ps in parameterSets {
            d.appendUInt32(UInt32(ps.count))
            d.append(ps)
        }
        return d
    }

    static func decode(_ payload: Data) -> VideoFormatMessage? {
        var r = ByteReader(payload)
        guard let rawCodec = r.uint8(), let codec = VideoCodec(rawValue: rawCodec),
              let header = r.int32(), let count = r.uint32() else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let len = r.uint32(), let body = r.bytes(Int(len)) else { return nil }
            sets.append(Data(body))
        }
        return VideoFormatMessage(codec: codec, nalUnitHeaderLength: header, parameterSets: sets)
    }

    func makeFormatDescription() -> CMVideoFormatDescription? {
        let total = parameterSets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 1)
        defer { raw.deallocate() }
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var offset = 0
        for ps in parameterSets {
            ps.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                raw.advanced(by: offset).copyMemory(from: base, byteCount: ps.count)
            }
            pointers.append(UnsafePointer(raw.advanced(by: offset).assumingMemoryBound(to: UInt8.self)))
            sizes.append(ps.count)
            offset += ps.count
        }
        var fd: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: nalUnitHeaderLength, formatDescriptionOut: &fd)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: nalUnitHeaderLength, extensions: nil, formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }
}

enum CodecParameterSets {
    static func extract(from fd: CMVideoFormatDescription, codec: VideoCodec) -> VideoFormatMessage? {
        var count = 0
        let probe: OSStatus
        switch codec {
        case .h264:
            probe = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        case .hevc:
            probe = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        guard probe == noErr, count > 0 else { return nil }
        var nalLength: Int32 = 4
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &nalLength)
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &nalLength)
            }
            guard status == noErr, let p = ptr, size > 0 else { return nil }
            sets.append(Data(bytes: p, count: size))
        }
        return VideoFormatMessage(codec: codec, nalUnitHeaderLength: nalLength, parameterSets: sets)
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func skip(_ n: Int) -> Bool {
        guard offset + n <= bytes.count else { return false }
        offset += n
        return true
    }

    mutating func uint8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func int32() -> Int32? { uint32().map { Int32(bitPattern: $0) } }

    mutating func uint32() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    mutating func int64() -> Int64? {
        guard offset + 8 <= bytes.count else { return nil }
        defer { offset += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[offset + i]) }
        return Int64(bitPattern: v)
    }

    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, offset + n <= bytes.count else { return nil }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
}

extension Data {
    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8(v >> 8)); append(UInt8(v & 0xFF))
    }

    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8(v >> 24)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF)); append(UInt8(v & 0xFF))
    }

    mutating func appendInt32(_ v: Int32) { appendUInt32(UInt32(bitPattern: v)) }

    mutating func appendInt64(_ v: Int64) {
        let u = UInt64(bitPattern: v)
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((u >> UInt64(shift)) & 0xFF)) }
    }
}
