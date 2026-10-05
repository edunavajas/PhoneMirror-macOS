import SwiftUI
import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Combine

final class LayerHostView: NSView {
    private let hosted: CALayer
    var aspect: CGFloat? { didSet { applyAspect() } }
    private var appliedAspect: CGFloat?

    init(hosted: CALayer) {
        self.hosted = hosted
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(hosted)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        hosted.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        appliedAspect = nil
        applyAspect()
    }

    private func applyAspect() {
        guard let aspect, aspect > 0, let window, aspect != appliedAspect else { return }
        appliedAspect = aspect
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        let visible = window.screen?.visibleFrame ?? window.frame
        let width = window.contentView?.bounds.width ?? 320
        var height = width / aspect
        if height > visible.height {
            height = visible.height
        }
        window.setContentSize(NSSize(width: height * aspect, height: height))
        window.center()
    }
}

struct VideoLayerView: NSViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    var aspect: CGFloat?

    func makeNSView(context: Context) -> LayerHostView { LayerHostView(hosted: displayLayer) }
    func updateNSView(_ nsView: LayerHostView, context: Context) {
        nsView.aspect = aspect
    }
}

final class MirrorSessionMac: ObservableObject {
    @Published var state: StreamClient.State = .idle
    @Published var fps = 0
    @Published var rotation = 0
    @Published var videoSize: CGSize?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let client = StreamClient()
    private let decoder = VideoDecoder()
    private var cancellables = Set<AnyCancellable>()

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor

        client.onFormat = { [weak self] format in self?.decoder.configure(format) }
        client.onFrame = { [weak self] frame in self?.decoder.decode(frame) }
        decoder.onImage = { [weak self] imageBuffer, _ in self?.enqueue(imageBuffer) }
        decoder.onError = { message in print("PhoneMirror decoder: \(message)") }

        client.$state.receive(on: DispatchQueue.main).sink { [weak self] in self?.state = $0 }
            .store(in: &cancellables)
        client.$fps.receive(on: DispatchQueue.main).sink { [weak self] in self?.fps = $0 }
            .store(in: &cancellables)
    }

    func start() { client.start() }
    func stop() { client.stop() }

    func rotateRight() { rotation = (rotation + 90) % 360 }
    func rotateLeft() { rotation = (rotation + 270) % 360 }

    private func enqueue(_ imageBuffer: CVImageBuffer) {
        let size = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
        if videoSize != size {
            DispatchQueue.main.async { [weak self] in self?.videoSize = size }
        }
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription) == noErr,
            let fd = formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: imageBuffer,
            formatDescription: fd, sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer) == noErr, let sample = sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            guard self.displayLayer.isReadyForMoreMediaData else { return }
            self.displayLayer.enqueue(sample)
        }
    }
}
