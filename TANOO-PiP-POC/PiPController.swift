import Foundation
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import UIKit

@MainActor
final class PiPController: NSObject, ObservableObject {
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var isControllerReady = false
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var statusText = "กำลังเตรียม PiP แบบ Live…"

    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    private weak var sourceView: TeleprompterVideoView?
    private var pipContentView: TeleprompterVideoView?
    private var pipVideoCallViewController: AVPictureInPictureVideoCallViewController?
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var renderTimer: Timer?

    func attach(to sourceView: TeleprompterVideoView) {
        guard self.sourceView !== sourceView else { return }
        self.sourceView = sourceView

        guard isSupported else {
            statusText = "อุปกรณ์นี้ไม่รองรับ Picture in Picture"
            isControllerReady = false
            return
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            statusText = "เตรียมระบบ PiP ไม่สมบูรณ์: \(error.localizedDescription)"
        }

        let pipView = TeleprompterVideoView()
        pipView.translatesAutoresizingMaskIntoConstraints = false
        pipView.renderFrame()

        let videoCallVC = AVPictureInPictureVideoCallViewController()
        videoCallVC.preferredContentSize = CGSize(width: 960, height: 360)
        videoCallVC.view.backgroundColor = .black
        videoCallVC.view.addSubview(pipView)

        NSLayoutConstraint.activate([
            pipView.topAnchor.constraint(equalTo: videoCallVC.view.topAnchor),
            pipView.leadingAnchor.constraint(equalTo: videoCallVC.view.leadingAnchor),
            pipView.trailingAnchor.constraint(equalTo: videoCallVC.view.trailingAnchor),
            pipView.bottomAnchor.constraint(equalTo: videoCallVC.view.bottomAnchor)
        ])

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: videoCallVC
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false

        pipContentView = pipView
        pipVideoCallViewController = videoCallVC
        pipController = controller
        isControllerReady = true

        pipPossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPictureInPicturePossible = controller.isPictureInPicturePossible
                self.statusText = controller.isPictureInPicturePossible
                    ? "พร้อมทดสอบ Live PiP — กด เปิด PiP"
                    : "PiP Controller พร้อมแล้ว กำลังรอระบบอนุญาต…"
            }
        }

        startRendering()
        statusText = "PiP Controller พร้อมแล้ว กำลังรอระบบอนุญาต…"
    }

    func togglePictureInPicture() {
        guard let controller = pipController else {
            statusText = "PiP Controller ยังไม่พร้อม"
            return
        }

        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
            return
        }

        sourceView?.renderFrame()
        pipContentView?.renderFrame()

        guard controller.isPictureInPicturePossible else {
            statusText = "PiP ยังไม่พร้อม ลองรอ 1–2 วินาทีแล้วกดอีกครั้ง"
            return
        }

        controller.startPictureInPicture()
    }

    private func startRendering() {
        renderTimer?.invalidate()
        renderTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sourceView?.renderFrame()
                self?.pipContentView?.renderFrame()
            }
        }
        if let renderTimer {
            RunLoop.main.add(renderTimer, forMode: .common)
        }
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.pipContentView?.renderFrame()
            self.statusText = "กำลังเปิด Live PiP…"
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isPictureInPictureActive = true
            self.pipContentView?.renderFrame()
            self.statusText = "Live PiP ทำงานแล้ว — เปิด Camera เพื่อทดสอบ"
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isPictureInPictureActive = false
            self.statusText = "PiP หยุดแล้ว"
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isPictureInPictureActive = false
            self.statusText = "เปิด Live PiP ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

final class TeleprompterVideoView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    private var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    private var frameCounter: Int64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func renderFrame() {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        let width = 960
        let height = 360

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

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 8

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 48, weight: .bold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]

        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 34, weight: .medium),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph
        ]

        NSAttributedString(
            string: "TANOO TELEPROMPTER",
            attributes: titleAttributes
        ).draw(
            with: CGRect(x: 50, y: 72, width: width - 100, height: 70),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )

        NSAttributedString(
            string: "LIVE PiP TEST\nเปิด Camera แล้วข้อความนี้ต้องยังอยู่",
            attributes: bodyAttributes
        ).draw(
            with: CGRect(x: 50, y: 150, width: width - 100, height: 150),
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
