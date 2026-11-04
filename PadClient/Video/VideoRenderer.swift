import AVFoundation
import CoreMedia
import os
import SwiftUI
import UIKit

/// Hosts an AVSampleBufferDisplayLayer and shows decoded frames immediately,
/// with no buffering. Letterboxing comes from `.resizeAspect`.
/// Created on the main thread (it owns a UIView); `display` may be called
/// from the decode thread because the layer's enqueue is thread-safe.
final class VideoRenderer: @unchecked Sendable {
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    let view: LayerView
    private let displayLayer: AVSampleBufferDisplayLayer

    @MainActor
    init() {
        view = LayerView()
        displayLayer = view.displayLayer
        view.backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        view.isUserInteractionEnabled = false
    }

    private let frameSize = OSAllocatedUnfairLock(initialState: CGSize.zero)

    /// Area of the view the video occupies after `.resizeAspect` letterboxing,
    /// in view coordinates. Input mapping (Milestone 5) uses this.
    @MainActor
    var videoRect: CGRect {
        let size = frameSize.withLock { $0 }
        let bounds = view.bounds
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        frameSize.withLock { $0 = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) }
        guard let sampleBuffer = Self.sampleBuffer(for: pixelBuffer) else { return }
        if #available(iOS 17.4, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func flush() {
        if #available(iOS 17.4, *) {
            displayLayer.sampleBufferRenderer.flush()
        } else {
            displayLayer.flush()
        }
    }

    private static func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary], let first = attachments.first {
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}

struct VideoDisplayView: UIViewRepresentable {
    let renderer: VideoRenderer

    func makeUIView(context: Context) -> VideoRenderer.LayerView { renderer.view }
    func updateUIView(_ uiView: VideoRenderer.LayerView, context: Context) {}
}
