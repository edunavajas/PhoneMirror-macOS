import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sawKeyframe = false

    var onImage: ((CVImageBuffer, CMTime) -> Void)?
    var onError: ((String) -> Void)?

    func configure(_ message: VideoFormatMessage) {
        guard let fd = message.makeFormatDescription() else {
            onError?("Formato H.264 no válido")
            return
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        sawKeyframe = false
        formatDescription = fd

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var newSession: VTDecompressionSession?
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, imageBuffer, pts, _ in
                guard status == noErr, let refcon, let imageBuffer else { return }
                Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                    .deliver(imageBuffer, pts)
            },
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &record,
            decompressionSessionOut: &newSession)
        guard status == noErr, let session = newSession else {
            onError?("VTDecompressionSessionCreate: \(status)")
            return
        }
        self.session = session
    }

    func decode(_ frame: VideoFrameMessage) {
        guard let session, let formatDescription else { return }
        if frame.isKeyframe { sawKeyframe = true }
        guard sawKeyframe else { return }
        let bytes = [UInt8](frame.data)
        let length = bytes.count
        guard length > 0 else { return }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
            let block = blockBuffer else { return }

        let copied = bytes.withUnsafeBytes { src -> OSStatus in
            guard let base = src.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: frame.presentationTimeStamp,
            decodeTimeStamp: .invalid)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr, let sample = sampleBuffer else { return }

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: &infoFlags)
        if status != noErr { onError?("decode failed: \(status)") }
    }

    fileprivate func deliver(_ imageBuffer: CVImageBuffer, _ pts: CMTime) {
        onImage?(imageBuffer, pts)
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }
}
