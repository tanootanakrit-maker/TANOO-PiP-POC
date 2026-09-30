import Foundation
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

@MainActor
final class PiPController: NSObject, ObservableObject {
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var canStartPictureInPicture = false
    @Published private(set) var statusText = "กำลังเตรียม PiP…"

    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    private weak var displayLayer: AVSampleBufferDisplayLayer?
    private var pipController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var renderTimer: Timer?
    private var frameCounter: Int64 = 0

    func attach(to layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else {
            refreshStatus()
            return
        }

        displayLayer = layer
        layer.videoGravity = .resizeAspect

        guard isSupported else {
            statusText = "อุปกรณ์นี้ไม่รองรับ Picture in Picture"
            canStartPictureInPicture = false
            return
        }

        // Apple requires PiP apps to be configured for background media playback.
        // The plist already contains the background audio mode; activate a playback
        // audio session here so iOS can mark PiP as possible.
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, options: [])
            try audio.setActive(true)
        } catch {
            statusText = "ตั้งค่าเสียงสำหรับ PiP ไม่สำเร็จ: \(error.localizedDescription)"
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pipController = controller

        // isPictureInPicturePossible is KVO-observable. Observe it instead of
        // relying only on polling so the button updates immediately when iOS
        // finishes preparing the content source.
        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] observed, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.canStartPictureInPicture = observed.isPictureInPicturePossible
                self.statusText = observed.isPictureInPicturePossible
                    ? "พร้อมทดสอบ — กด เปิด PiP แล้วเปิด Camera"
                    : "กำลังรอให้ PiP พร้อม…"
            }
        }

        startRendering()
        renderFrame()

        // Give AVSampleBufferDisplayLayer a moment to present its first frame,
        // then invalidate PiP playback state and re-check availability.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.pipController?.invalidatePlaybackState()
            self.renderFrame()
            self.refreshStatus()
        }
    }

    func refreshStatus() {
        guard isSupported else {
            statusText = "อุปกรณ์นี้ไม่รองรับ Picture in Picture"
            canStartPictureInPicture = false
            return
        }

        canStartPictureInPicture = pipController?.isPictureInPicturePossible ?? false
        statusText = canStartPictureInPicture
            ? "พร้อมทดสอบ — กด เปิด PiP แล้วเปิด Camera"
            : "กำลังรอให้ PiP พร้อม…"
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            renderFrame()
            pipController.startPictureInPicture()
        } else {
            refreshStatus()
        }
    }

    private func startRendering() {
        renderTimer?.invalidate()
        renderTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.renderFrame()
                self?.refreshStatus()
            }
        }
        RunLoop.main.add(renderTimer!, forMode: .common)
    }

    private func renderFrame() {
        guard let displayLayer else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        let width = 960
        let height = 540
        guard let pixelBuffer = makePixelBuffer(width: width, height: height) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else { return }

        context.setFillColor(UIColor.black.withAlphaComponent(0.88).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 10

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 42, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]

        let text = "TANOO TELEPROMPTER\nPiP TEST\nเปิด Camera แล้วดูว่ากล่องนี้ยังลอยอยู่หรือไม่"
        let attributed = NSAttributedString(string: text, attributes: attributes)
        attributed.draw(
            with: CGRect(x: 60, y: 110, width: width - 120, height: height - 180),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        UIGraphicsPopContext()
        context.restoreGState()

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return }

        frameCounter += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: CMTime(value: frameCounter, timescale: 2),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?

        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        displayLayer.enqueue(sampleBuffer)
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.statusText = "กำลังเปิด PiP…"
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPictureInPictureActive = true
            self.statusText = "PiP ทำงานแล้ว — เปิด Camera เพื่อทดสอบ"
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPictureInPictureActive = false
            self.statusText = "PiP หยุดแล้ว"
            self.refreshStatus()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isPictureInPictureActive = false
            self.statusText = "เปิด PiP ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        Task { @MainActor in
            self.renderFrame()
            pictureInPictureController.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        true
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping @Sendable () -> Void
    ) {
        completionHandler()
    }
}
