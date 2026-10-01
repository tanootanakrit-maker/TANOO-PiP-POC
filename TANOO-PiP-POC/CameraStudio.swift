import SwiftUI
import AVFoundation
import Photos
import Speech
import CoreMedia

enum CameraCaptureMode: String, CaseIterable, Identifiable {
    case cinematic
    case video
    case pro
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cinematic: return "CINE"
        case .video: return "VIDEO"
        case .pro: return "PRO"
        case .raw: return "RAW"
        }
    }
}

enum CameraResolution: String, CaseIterable, Identifiable {
    case hd1080 = "1080p"
    case uhd4K = "4K"
    var id: String { rawValue }

    var dimensions: CMVideoDimensions {
        switch self {
        case .hd1080: return CMVideoDimensions(width: 1920, height: 1080)
        case .uhd4K: return CMVideoDimensions(width: 3840, height: 2160)
        }
    }
}

// BEGIN CAMERA GEOMETRY
private enum CameraGeometry {
    static func exportTransform(naturalSize: CGSize, preferred: CGAffineTransform, target: CGSize) -> CGAffineTransform {
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        return preferred
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (target.width - bounds.width * scale) / 2,
                                           y: (target.height - bounds.height * scale) / 2))
    }

    static func countdown(configured: Int, resuming: Bool) -> Int {
        resuming ? max(3, configured) : max(0, configured)
    }
}
// END CAMERA GEOMETRY

private enum RecordingStopAction {
    case finish
    case pause
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var captureMode: CameraCaptureMode = .video
    @Published var resolution: CameraResolution = .hd1080 {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "TANOO.camera.resolution") }
    }
    @Published var frameRate: Double = 30 {
        didSet { UserDefaults.standard.set(frameRate, forKey: "TANOO.camera.frameRate") }
    }

    @Published private(set) var isConfigured = false
    @Published private(set) var isPreviewOnly = false
    @Published private(set) var diagnosticStage = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isStartingRecording = false
    @Published private(set) var isReconfiguring = false
    @Published private(set) var statusText = "กำลังเตรียมกล้อง…"
    @Published private(set) var recordingSeconds: TimeInterval = 0
    @Published private(set) var availableDiskGB: Double = 0
    @Published private(set) var recordPreflightMessage: String = ""

    @Published private(set) var isFinishingSegment = false
    @Published private(set) var isSaving = false
    @Published private(set) var completedShotCount = 0
    @Published private(set) var lastShotSeconds: Double = 0
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .front
    @Published private(set) var previewRevision = 0
    @Published private(set) var portraitSupported = false
    @Published private(set) var portraitActive = false
    @Published private(set) var cinematicAvailable = false
    @Published private(set) var proAvailable = false
    @Published private(set) var rawAvailable = false

    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var minZoomFactor: CGFloat = 1.0
    @Published private(set) var maxZoomFactor: CGFloat = 2.0

    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var minExposureBias: Float = -2
    @Published private(set) var maxExposureBias: Float = 2
    @Published private(set) var focusExposureLocked = false

    @Published var simulatedAperture: Float = 2.8
    @Published private(set) var minSimulatedAperture: Float = 1.4
    @Published private(set) var maxSimulatedAperture: Float = 16

    var onTranscript: ((String) -> Void)?
    var onRestorePrompt: ((PiPController.RecordingCheckpoint) -> Void)?
    var checkpointProvider: (() -> PiPController.RecordingCheckpoint)?
    private var pendingCheckpoint: PiPController.RecordingCheckpoint?
    private var shotCheckpoints: [PiPController.RecordingCheckpoint?] = []
    private var shotDurations: [Double] = []
    private var portraitObservation: NSKeyValueObservation?
    private var openPortraitControlsWhenReady = false

    private let sessionQueue = DispatchQueue(label: "com.tanoo.camera.session")
    private let audioQueue = DispatchQueue(label: "com.tanoo.camera.audio")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var recordingTimer: Timer?
    private var currentRecordingURL: URL?
    private var recordingSegments: [URL] = []
    private var stopAction: RecordingStopAction = .finish
    private var resetDurationOnNextSegment = false
    private let speechBridge = CameraSpeechBridge()

    override init() {
        if let raw = UserDefaults.standard.string(forKey: "TANOO.camera.resolution"),
           let savedResolution = CameraResolution(rawValue: raw) {
            resolution = savedResolution
        }

        if UserDefaults.standard.object(forKey: "TANOO.camera.frameRate") != nil {
            let savedFPS = UserDefaults.standard.double(forKey: "TANOO.camera.frameRate")
            frameRate = savedFPS > 0 ? savedFPS : 30
        }

        super.init()
        refreshDiskSpace()
    }

    func diagnosticDetectFrontCamera() {
        statusText = "STEP 1: กำลังค้นหากล้องหน้า…"
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Start with the ordinary front wide-angle camera only.
            // TrueDepth/Cinematic are intentionally excluded from this diagnostic.
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                Task { @MainActor in
                    self.statusText = "STEP 1 FAIL: ไม่พบ front wide-angle camera"
                }
                return
            }

            self.currentDevice = camera
            Task { @MainActor in
                self.diagnosticStage = 1
                self.statusText = "STEP 1 PASS: พบกล้องหน้า — กด STEP 2"
            }
        }
    }

    func diagnosticConfigureVideoOnly() {
        guard diagnosticStage >= 1 else {
            statusText = "กรุณาทำ STEP 1 ก่อน"
            return
        }

        statusText = "STEP 2: กำลังสร้าง Capture Session แบบ Video-only…"

        sessionQueue.async { [weak self] in
            guard let self, let camera = self.currentDevice else { return }

            self.session.beginConfiguration()
            var committed = false
            defer {
                if !committed {
                    self.session.commitConfiguration()
                }
            }

            self.session.sessionPreset = .high

            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                guard self.session.canAddInput(input) else {
                    Task { @MainActor in
                        self.statusText = "STEP 2 FAIL: session.canAddInput = false"
                    }
                    return
                }

                self.session.addInput(input)
                self.videoInput = input

                self.session.commitConfiguration()
                committed = true

                Task { @MainActor in
                    self.isConfigured = true
                    self.isPreviewOnly = true
                    self.diagnosticStage = 2
                    self.statusText = "STEP 2 PASS: Session configured — ยังไม่ได้ startRunning — กด STEP 3"
                }
            } catch {
                Task { @MainActor in
                    self.statusText = "STEP 2 FAIL: " + error.localizedDescription
                }
            }
        }
    }

    func diagnosticStartSession() {
        guard diagnosticStage >= 2 else {
            statusText = "กรุณาทำ STEP 2 ก่อน"
            return
        }

        statusText = "STEP 3: กำลัง startRunning โดยยังไม่ผูก PreviewLayer…"

        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            Task { @MainActor in
                self.isRunning = self.session.isRunning
                if self.session.isRunning {
                    self.diagnosticStage = 3
                    self.statusText = "STEP 3 PASS: Capture Session กำลังทำงาน — กด STEP 4 เพื่อแสดงภาพ"
                } else {
                    self.statusText = "STEP 3 FAIL: session ไม่เริ่มทำงาน"
                }
            }
        }
    }

    func diagnosticPreviewAttached() {
        guard diagnosticStage >= 3 else { return }
        diagnosticStage = 4
        statusText = "STEP 4: PreviewLayer ถูกผูกกับ Session แล้ว"
    }

    func resetDiagnostic() {
        stop()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            for input in self.session.inputs {
                self.session.removeInput(input)
            }
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }
            self.session.commitConfiguration()

            self.videoInput = nil
            self.audioInput = nil
            self.currentDevice = nil

            Task { @MainActor in
                self.isConfigured = false
                self.isPreviewOnly = false
                self.diagnosticStage = 0
                self.statusText = "Diagnostic reset — เริ่ม STEP 1 ได้"
            }
        }
    }

    func startPreviewOnly() {
        statusText = "กำลังเปิดกล้องแบบ Safe Preview…"

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        let configure = { [weak self] in
            guard let self else { return }
            self.sessionQueue.async {
                self.configurePreviewOnlySession()
            }
        }

        if cameraStatus == .authorized {
            configure()
        } else {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                guard granted else {
                    Task { @MainActor in
                        self.statusText = "ไม่ได้รับสิทธิ์ Camera"
                    }
                    return
                }
                configure()
            }
        }
    }

    func start() {
        requestPermissionsAndConfigure()
    }

    func stop() {
        stopSpeech()
        recordingTimer?.invalidate()
        recordingTimer = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            Task { @MainActor in
                self.isRunning = false
            }
        }
    }

    func reconfigure() {
        guard isConfigured, !isRecording, !isPaused, !isStartingRecording, !isReconfiguring, !isFinishingSegment, !isSaving else { return }

        isReconfiguring = true
        statusText = "กำลังเปลี่ยนคุณภาพกล้อง…"

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyCaptureSettings()
        }
    }

    func supportsMode(_ mode: CameraCaptureMode) -> Bool {
        switch mode {
        case .cinematic: return cinematicAvailable
        case .video: return true
        case .pro: return proAvailable
        case .raw: return rawAvailable
        }
    }

    func selectMode(_ mode: CameraCaptureMode) {
        guard !isRecording, !isPaused, !isStartingRecording, !isReconfiguring,
              !isFinishingSegment, !isSaving else { return }
        guard supportsMode(mode) else {
            statusText = mode.title + " ไม่รองรับกับกล้อง/Format ปัจจุบัน"
            return
        }
        captureMode = mode
        reconfigure()
    }

    func openPortraitControls() {
        guard !isRecording, !isPaused, !isStartingRecording, !isReconfiguring,
              !isFinishingSegment, !isSaving else { return }
        guard cameraPosition == .front else {
            statusText = "สลับเป็นกล้องหน้าก่อนเปิด Portrait"
            return
        }
        // Portrait is controlled by the user, not by a writable app toggle.
        // Select a supported 1080p30 format before opening Apple's controls.
        isReconfiguring = true
        captureMode = .video
        resolution = .hd1080
        frameRate = 30
        openPortraitControlsWhenReady = true
        sessionQueue.async { [weak self] in self?.applyCaptureSettings() }
    }

    func switchCamera() {
        guard isConfigured, !isRecording, !isStartingRecording, !isReconfiguring,
              !isFinishingSegment, !isSaving else { return }
        let target: AVCaptureDevice.Position = cameraPosition == .front ? .back : .front
        isReconfiguring = true
        stopSpeech()
        sessionQueue.async { [weak self] in
            guard let self, let oldInput = self.videoInput else { return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: target),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                Task { @MainActor in
                    self.isReconfiguring = false
                    self.statusText = "ไม่พบกล้องที่ต้องการ"
                }
                return
            }
            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            let changed = self.session.canAddInput(newInput)
            if changed {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.currentDevice = device
            } else {
                self.session.addInput(oldInput)
            }
            self.session.commitConfiguration()
            guard changed else {
                Task { @MainActor in
                    self.isReconfiguring = false
                    self.statusText = "สลับกล้องไม่ได้ — คงกล้องเดิม"
                }
                return
            }
            Task { @MainActor in
                self.cameraPosition = target
                self.captureMode = .video
                self.zoomFactor = 1
                self.focusExposureLocked = false
                self.sessionQueue.async { self.applyCaptureSettings() }
            }
        }
    }

    func setZoom(_ value: CGFloat) {
        let target = min(max(value, minZoomFactor), maxZoomFactor)
        zoomFactor = target
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(max(target, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in
                    self.statusText = "ปรับ Zoom ไม่สำเร็จ: " + error.localizedDescription
                }
            }
        }
    }

    func setExposureBias(_ value: Float) {
        let target = min(max(value, minExposureBias), maxExposureBias)
        exposureBias = target
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(target, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in
                    self.statusText = "ปรับแสงไม่สำเร็จ: " + error.localizedDescription
                }
            }
        }
    }

    func setAperture(_ value: Float) {
        simulatedAperture = value
        guard captureMode == .cinematic, !isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self, let input = self.videoInput else { return }
            if #available(iOS 26.0, *) {
                let minValue = input.device.activeFormat.minSimulatedAperture
                let maxValue = input.device.activeFormat.maxSimulatedAperture
                guard minValue > 0, maxValue >= minValue else { return }
                let target = min(max(value, minValue), maxValue)
                input.simulatedAperture = target
                Task { @MainActor in
                    self.simulatedAperture = target
                }
            }
        }
    }

    private var cinematicCaptureEnabled: Bool {
        if #available(iOS 26.0, *) { return videoInput?.isCinematicVideoCaptureEnabled ?? false }
        return false
    }

    func toggleFocusExposureLock() {
        focusExposureLocked.toggle()
        let shouldLock = focusExposureLocked

        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()

                if self.cinematicCaptureEnabled {
                    if #available(iOS 26.0, *) {
                        device.setCinematicVideoTrackingFocus(
                            at: CGPoint(x: 0.5, y: 0.5),
                            focusMode: .strong
                        )
                    }
                } else {
                    if shouldLock, device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    } else if !shouldLock, device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }

                if shouldLock, device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                } else if !shouldLock, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in
                    self.statusText = "ล็อก Focus/Exposure ไม่สำเร็จ: " + error.localizedDescription
                }
            }
        }
    }

    func enableAutoFocus() {
        focusExposureLocked = false

        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }

            do {
                try device.lockForConfiguration()

                if self.cinematicCaptureEnabled {
                    if #available(iOS 26.0, *) {
                        device.setCinematicVideoTrackingFocus(
                            at: CGPoint(x: 0.5, y: 0.5),
                            focusMode: .strong
                        )
                    }
                } else {
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    }
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }

                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }

                device.unlockForConfiguration()

                Task { @MainActor in
                    self.statusText = "AUTO FOCUS"
                }
            } catch {
                Task { @MainActor in
                    self.statusText = "เปิด Auto Focus ไม่สำเร็จ: " + error.localizedDescription
                }
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        focusExposureLocked = false

        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()

                if self.cinematicCaptureEnabled {
                    if #available(iOS 26.0, *) {
                        device.setCinematicVideoTrackingFocus(at: devicePoint, focusMode: .strong)
                    }
                } else {
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = devicePoint
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        } else if device.isFocusModeSupported(.autoFocus) {
                            device.focusMode = .autoFocus
                        }
                    }

                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = devicePoint
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                    }
                }

                device.unlockForConfiguration()

                Task { @MainActor in
                    self.statusText = "Focus จุดที่แตะแล้ว"
                }
            } catch {
                Task { @MainActor in
                    self.statusText = "แตะ Focus ไม่สำเร็จ: " + error.localizedDescription
                }
            }
        }
    }

    func lockFocus(at devicePoint: CGPoint) {
        focusExposureLocked = true

        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }

            do {
                try device.lockForConfiguration()

                if self.cinematicCaptureEnabled {
                    if #available(iOS 26.0, *) {
                        device.setCinematicVideoFixedFocus(at: devicePoint, focusMode: .strong)
                    }
                } else {
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = devicePoint
                    }
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }

                    if device.isExposurePointOfInterestSupported {
                        device.exposurePointOfInterest = devicePoint
                    }
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }

                device.unlockForConfiguration()

                if !self.cinematicCaptureEnabled {
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self, self.focusExposureLocked, let device = self.currentDevice else { return }
                        do {
                            try device.lockForConfiguration()
                            if device.isFocusModeSupported(.locked) {
                                device.focusMode = .locked
                            }
                            if device.isExposureModeSupported(.locked) {
                                device.exposureMode = .locked
                            }
                            device.unlockForConfiguration()

                            Task { @MainActor in
                                self.statusText = "AE/AF LOCK"
                            }
                        } catch {
                            Task { @MainActor in
                                self.statusText = "ล็อก Focus ไม่สำเร็จ: " + error.localizedDescription
                            }
                        }
                    }
                } else {
                    Task { @MainActor in
                        self.statusText = "Cinematic Focus LOCK"
                    }
                }
            } catch {
                Task { @MainActor in
                    self.statusText = "ล็อก Focus ไม่สำเร็จ: " + error.localizedDescription
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else if isPaused {
            resumeRecording()
        } else {
            startNewTake()
        }
    }

    func startNewTake() {
        guard !isRecording, !isPaused, !isStartingRecording, !isReconfiguring, !isFinishingSegment, !isSaving else {
            let message = isReconfiguring
                ? "REC ยังไม่เริ่ม: กล้องกำลังเปลี่ยนคุณภาพ"
                : "REC ยังไม่เริ่ม: กล้องยังไม่พร้อม"
            recordPreflightMessage = message
            statusText = message
            return
        }

        cleanupTemporaryRecordings()
        refreshDiskSpace()

        let freeGB = freeDiskSpaceGB()
        let minimumGB = resolution == .uhd4K ? 2.0 : 1.0

        guard freeGB >= minimumGB else {
            let message = String(
                format: "พื้นที่ไม่พอ: %@ ต้องเหลืออย่างน้อย %.1f GB • ตอนนี้ %.1f GB",
                resolution.rawValue,
                minimumGB,
                freeGB
            )
            availableDiskGB = freeGB
            recordPreflightMessage = message
            statusText = message
            return
        }

        recordPreflightMessage = ""
        recordingSegments.removeAll()
        shotCheckpoints.removeAll()
        shotDurations.removeAll()
        completedShotCount = 0
        lastShotSeconds = 0
        pendingCheckpoint = checkpointProvider?()
        currentRecordingURL = nil
        recordingSeconds = 0
        isPaused = false
        stopAction = .finish
        resetDurationOnNextSegment = true
        isStartingRecording = true
        statusText = "กำลังเตรียม REC…"

        // All AVCaptureSession / MovieFileOutput operations are serialized
        // on the same queue. This removes the race that could happen after
        // countdown, format changes or a previous take.
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            guard self.session.isRunning else {
                Task { @MainActor in
                    self.isStartingRecording = false
                    self.recordPreflightMessage = "REC ไม่เริ่ม: Capture Session ไม่ทำงาน"
                    self.statusText = self.recordPreflightMessage
                }
                return
            }

            self.startRecordingSegmentOnSessionQueue()
        }
    }

    func pauseRecording() {
        guard isRecording, !isFinishingSegment else { return }
        isFinishingSegment = true
        stopAction = .pause
        statusText = "กำลังเก็บช็อต…"
        sessionQueue.async { self.movieOutput.stopRecording() }
    }

    func resumeRecording() {
        guard isPaused, !isRecording, !isStartingRecording, !isReconfiguring,
              !isFinishingSegment, !isSaving else { return }
        refreshDiskSpace()
        let minimumGB = resolution == .uhd4K ? 2.0 : 1.0
        guard freeDiskSpaceGB() >= minimumGB else {
            recordPreflightMessage = "พื้นที่ไม่พอบันทึกต่อ — ช็อตเดิมยังอยู่ กด Stop เพื่อบันทึก"
            return
        }
        pendingCheckpoint = checkpointProvider?()
        isPaused = false
        stopAction = .finish
        resetDurationOnNextSegment = false
        isStartingRecording = true

        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            guard self.session.isRunning else {
                Task { @MainActor in
                    self.isStartingRecording = false
                    self.isPaused = true
                    self.recordPreflightMessage = "บันทึกต่อไม่ได้: Capture Session ไม่ทำงาน"
                    self.statusText = self.recordPreflightMessage
                }
                return
            }

            self.startRecordingSegmentOnSessionQueue()
        }
    }

    func deleteLastShot() {
        guard isPaused, !isFinishingSegment, !isStartingRecording, !isReconfiguring,
              !isSaving, let url = recordingSegments.last else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            statusText = "ลบช็อตไม่สำเร็จ: " + error.localizedDescription
            return
        }
        recordingSegments.removeLast()
        let checkpoint = shotCheckpoints.removeLast()
        shotDurations.removeLast()
        completedShotCount = recordingSegments.count
        lastShotSeconds = shotDurations.last ?? 0
        recordingSeconds = shotDurations.reduce(0, +)
        if let checkpoint { onRestorePrompt?(checkpoint) }
        // Stay paused even after deleting the first/only shot, allowing a retake.
        statusText = "ลบช็อตล่าสุดแล้ว • สคริปต์ย้อนจุดเริ่มช็อต • กด ▶ ถ่ายใหม่"
        refreshDiskSpace()
    }

    func finishRecording() {
        guard !isSaving, !isFinishingSegment, !isStartingRecording, !isReconfiguring else { return }
        stopSpeech()

        if isRecording {
            isFinishingSegment = true
            stopAction = .finish
            statusText = "กำลังหยุดและรวมคลิป…"
            sessionQueue.async { self.movieOutput.stopRecording() }
        } else if isPaused {
            isPaused = false
            finalizeRecordingSegments()
        }
    }

    func startSpeech() {
        guard captureMode != .raw || rawAvailable else { return }
        speechBridge.start(
            onStatus: { [weak self] message in
                Task { @MainActor in
                    if !message.isEmpty { self?.statusText = message }
                }
            },
            onTranscript: { [weak self] transcript in
                Task { @MainActor in
                    self?.onTranscript?(transcript)
                }
            }
        )
    }

    func stopSpeech() {
        speechBridge.stop()
    }

    private func configurePreviewOnlySession() {
        if session.isRunning {
            Task { @MainActor in
                self.isRunning = true
                self.statusText = "Safe Preview ทำงานแล้ว"
            }
            return
        }

        session.beginConfiguration()
        var committed = false
        defer {
            if !committed {
                session.commitConfiguration()
            }
        }

        session.sessionPreset = .hd1920x1080

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            Task { @MainActor in
                self.statusText = "ไม่พบกล้องหน้า"
            }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                Task { @MainActor in
                    self.statusText = "เพิ่มกล้องหน้าไม่ได้"
                }
                return
            }

            session.addInput(input)
            videoInput = input
            currentDevice = camera

            session.commitConfiguration()
            committed = true

            session.startRunning()

            Task { @MainActor in
                self.isConfigured = true
                self.isPreviewOnly = true
                self.isRunning = self.session.isRunning
                self.statusText = self.session.isRunning
                    ? "Safe Preview ทำงานแล้ว — ยังไม่ได้เปิดไมค์/บันทึก/Hybrid"
                    : "เปิด Safe Preview ไม่สำเร็จ"
            }
        } catch {
            Task { @MainActor in
                self.statusText = "Safe Preview ผิดพลาด: " + error.localizedDescription
            }
        }
    }

    private func prepareCameraAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            Task { @MainActor in
                self.statusText = "ตั้งค่าเสียงกล้องไม่สำเร็จ: " + error.localizedDescription
            }
        }
    }

    private func requestPermissionsAndConfigure() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        func continueAfterPermissions() {
            self.sessionQueue.async { [weak self] in
                self?.configureSessionIfNeeded()
            }
        }

        if cameraStatus == .authorized && micStatus == .authorized {
            continueAfterPermissions()
            return
        }

        AVCaptureDevice.requestAccess(for: .video) { cameraGranted in
            guard cameraGranted else {
                Task { @MainActor in self.statusText = "ไม่ได้รับสิทธิ์ Camera" }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                guard micGranted else {
                    Task { @MainActor in self.statusText = "ไม่ได้รับสิทธิ์ Microphone" }
                    return
                }
                continueAfterPermissions()
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else {
            if !session.isRunning {
                session.startRunning()
            }
            Task { @MainActor in
                self.isRunning = self.session.isRunning
            }
            return
        }

        prepareCameraAudioSession()
        session.automaticallyConfiguresApplicationAudioSession = false

        session.beginConfiguration()
        var configurationCommitted = false
        defer {
            if !configurationCommitted {
                session.commitConfiguration()
            }
        }

        session.sessionPreset = .inputPriority

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            Task { @MainActor in self.statusText = "ไม่พบกล้องหน้า" }
            return
        }

        do {
            let vInput = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(vInput) else {
                Task { @MainActor in self.statusText = "เพิ่มกล้องหน้าไม่ได้" }
                return
            }
            session.addInput(vInput)
            videoInput = vInput
            currentDevice = camera

            if let mic = AVCaptureDevice.default(for: .audio) {
                let aInput = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(aInput) {
                    session.addInput(aInput)
                    audioInput = aInput
                }
            }

            if session.canAddOutput(movieOutput) {
                session.addOutput(movieOutput)
            }

            audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioDataOutput) {
                session.addOutput(audioDataOutput)
            }

            // Important: never call startRunning while between
            // beginConfiguration() and commitConfiguration().
            session.commitConfiguration()
            configurationCommitted = true

            // Apply format/FPS/codec in a separate configuration transaction.
            applyCaptureSettings()
            updateCapabilities()

            if !session.isRunning {
                session.startRunning()
            }

            Task { @MainActor in
                self.isConfigured = true
                self.isPreviewOnly = false
                self.isRunning = self.session.isRunning
                self.statusText = "TANOO Camera พร้อมใช้งาน"
            }
        } catch {
            Task { @MainActor in
                self.statusText = "ตั้งค่ากล้องไม่สำเร็จ: " + error.localizedDescription
            }
        }
    }

    private func applyCaptureSettings(manageSessionConfiguration: Bool = true) {
        guard let device = currentDevice, let input = videoInput else {
            Task { @MainActor in
                self.isReconfiguring = false
            }
            return
        }

        let wasRunning = session.isRunning

        if manageSessionConfiguration && wasRunning {
            session.stopRunning()
        }

        if manageSessionConfiguration {
            session.beginConfiguration()
        }

        if #available(iOS 26.0, *) {
            if input.isCinematicVideoCaptureEnabled {
                input.isCinematicVideoCaptureEnabled = false
            }
        }

        var selectedResolution = resolution
        var selectedFPS = frameRate
        var configurationMessage: String?

        if captureMode == .video {
            let requestedPreset: AVCaptureSession.Preset =
                resolution == .uhd4K ? .hd4K3840x2160 : .hd1920x1080

            if session.canSetSessionPreset(requestedPreset) {
                session.sessionPreset = requestedPreset
            } else {
                selectedResolution = .hd1080
                if session.canSetSessionPreset(.hd1920x1080) {
                    session.sessionPreset = .hd1920x1080
                }
                configurationMessage = "4K ไม่รองรับกับ configuration นี้ — กลับเป็น 1080p"
            }

            do {
                try device.lockForConfiguration()

                if openPortraitControlsWhenReady {
                    let supported = device.formats.first { format in
                        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                        return d.width == 1920 && d.height == 1080 && format.isPortraitEffectSupported &&
                            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                    }
                    if let supported {
                        session.sessionPreset = .inputPriority
                        device.activeFormat = supported
                    }
                }
                device.videoZoomFactor = min(max(zoomFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                let ranges = device.activeFormat.videoSupportedFrameRateRanges
                let requestedSupported = ranges.contains {
                    selectedFPS >= $0.minFrameRate && selectedFPS <= $0.maxFrameRate
                }

                if !requestedSupported {
                    let thirtySupported = ranges.contains {
                        30 >= $0.minFrameRate && 30 <= $0.maxFrameRate
                    }
                    selectedFPS = thirtySupported ? 30 : (ranges.first?.maxFrameRate ?? 30)
                    configurationMessage = (configurationMessage ?? "") +
                        (configurationMessage == nil ? "" : " • ") +
                        "FPS ปรับเป็น " + String(Int(selectedFPS))
                }

                let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(selectedFPS))))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration

                if device.isExposureModeSupported(.continuousAutoExposure) && !focusExposureLocked {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isFocusModeSupported(.continuousAutoFocus) && !focusExposureLocked {
                    device.focusMode = .continuousAutoFocus
                }

                device.unlockForConfiguration()
            } catch {
                configurationMessage = "ตั้งค่า FPS ไม่สำเร็จ: " + error.localizedDescription
            }
        } else {
            // Explicit formats require inputPriority rather than a preset overriding them.
            session.sessionPreset = .inputPriority
            let dimensions = resolution.dimensions
            let candidates = device.formats.filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard d.width == dimensions.width, d.height == dimensions.height else { return false }

                if captureMode == .cinematic {
                    if #available(iOS 26.0, *) {
                        guard format.isCinematicVideoCaptureSupported,
                              let range = format.videoFrameRateRangeForCinematicVideo else { return false }
                        return frameRate >= range.minFrameRate && frameRate <= range.maxFrameRate
                    }
                    return false
                }

                return format.videoSupportedFrameRateRanges.contains {
                    frameRate >= $0.minFrameRate && frameRate <= $0.maxFrameRate
                }
            }

            if let selected = candidates.first {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = selected
                    let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(frameRate))))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                    device.unlockForConfiguration()
                } catch {
                    configurationMessage = "เลือก Format ไม่สำเร็จ: " + error.localizedDescription
                }
            } else {
                configurationMessage = "ไม่พบ Format ที่รองรับ"
            }

            if captureMode == .cinematic {
                if #available(iOS 26.0, *), input.isCinematicVideoCaptureSupported {
                    input.isCinematicVideoCaptureEnabled = true
                    let minA = device.activeFormat.minSimulatedAperture
                    let maxA = device.activeFormat.maxSimulatedAperture
                    if minA > 0, maxA >= minA {
                        input.simulatedAperture = min(max(simulatedAperture, minA), maxA)
                    }
                }
            }
        }

        configureVideoConnection()
        updateCapabilities()

        if manageSessionConfiguration {
            session.commitConfiguration()
        }

        if manageSessionConfiguration && wasRunning && !session.isRunning {
            session.startRunning()
        }

        Task { @MainActor in
            self.resolution = selectedResolution
            self.frameRate = selectedFPS
            self.isRunning = self.session.isRunning
            self.isReconfiguring = false
            self.previewRevision += 1
            if self.openPortraitControlsWhenReady {
                self.openPortraitControlsWhenReady = false
                if device.activeFormat.isPortraitEffectSupported {
                    AVCaptureDevice.showSystemUserInterface(.videoEffects)
                } else {
                    self.statusText = "กล้องนี้ไม่รองรับ Portrait ในรูปแบบ 1080p30"
                    return
                }
            }

            if let configurationMessage, !configurationMessage.isEmpty {
                self.statusText = configurationMessage
            } else {
                self.statusText = "พร้อม • " + selectedResolution.rawValue + " " + String(Int(selectedFPS)) + "fps"
            }
        }
    }

    private func configureVideoConnection() {
        guard let connection = movieOutput.connection(with: .video) else { return }

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = currentDevice?.position == .front
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }

        let available = movieOutput.availableVideoCodecTypes
        let codec: AVVideoCodecType?

        switch captureMode {
        case .cinematic, .video:
            codec = available.contains(.hevc) ? .hevc : (available.contains(.h264) ? .h264 : nil)
        case .pro:
            if available.contains(.proRes422HQ) {
                codec = .proRes422HQ
            } else if available.contains(.proRes422) {
                codec = .proRes422
            } else {
                codec = nil
            }
        case .raw:
            if #available(iOS 26.0, *) {
                if available.contains(.proResRAWHQ) {
                    codec = .proResRAWHQ
                } else if available.contains(.proResRAW) {
                    codec = .proResRAW
                } else {
                    codec = nil
                }
            } else {
                codec = nil
            }
        }

        if let codec {
            movieOutput.setOutputSettings([AVVideoCodecKey: codec.rawValue], for: connection)
        }
    }

    private func updateCapabilities() {
        guard let device = currentDevice else { return }

        portraitObservation = device.observe(\.isPortraitEffectActive, options: [.initial, .new]) { [weak self] device, _ in
            Task { @MainActor in self?.portraitActive = device.isPortraitEffectActive }
        }
        let portrait = device.formats.contains { $0.isPortraitEffectSupported }
        let availableCodecs = movieOutput.availableVideoCodecTypes

        var cine = false
        if #available(iOS 26.0, *) {
            cine = device.formats.contains { $0.isCinematicVideoCaptureSupported }
        }

        let pro = availableCodecs.contains(.proRes422) || availableCodecs.contains(.proRes422HQ)

        var raw = false
        if #available(iOS 26.0, *) {
            raw = availableCodecs.contains(.proResRAW) || availableCodecs.contains(.proResRAWHQ)
        }

        var minZoom = device.minAvailableVideoZoomFactor
        var maxZoom = min(device.maxAvailableVideoZoomFactor, 3.0)
        var minA: Float = 1.4
        var maxA: Float = 16
        var aperture = simulatedAperture

        if captureMode == .cinematic {
            if #available(iOS 26.0, *) {
                let format = device.activeFormat
                if format.isCinematicVideoCaptureSupported {
                    minZoom = format.videoMinZoomFactorForCinematicVideo
                    maxZoom = min(format.videoMaxZoomFactorForCinematicVideo, 3.0)
                    if format.minSimulatedAperture > 0 {
                        minA = format.minSimulatedAperture
                        maxA = format.maxSimulatedAperture
                        aperture = min(max(simulatedAperture, minA), maxA)
                    }
                }
            }
        }

        Task { @MainActor in
            self.portraitSupported = portrait
            self.cinematicAvailable = cine
            self.proAvailable = pro
            self.rawAvailable = raw
            self.minZoomFactor = minZoom
            self.maxZoomFactor = max(maxZoom, minZoom)
            self.zoomFactor = min(max(self.zoomFactor, minZoom), max(maxZoom, minZoom))
            self.minExposureBias = device.minExposureTargetBias
            self.maxExposureBias = device.maxExposureTargetBias
            self.exposureBias = device.exposureTargetBias
            self.minSimulatedAperture = minA
            self.maxSimulatedAperture = maxA
            self.simulatedAperture = aperture

            if self.captureMode == .cinematic && !cine {
                self.captureMode = .video
                self.statusText = "เครื่องนี้ไม่รองรับ Cinematic ผ่าน API ปัจจุบัน — ใช้ VIDEO แทน"
            } else if self.captureMode == .pro && !pro {
                self.captureMode = .video
                self.statusText = "กล้องหน้า/Format นี้ไม่รองรับ ProRes — ใช้ VIDEO แทน"
            } else if self.captureMode == .raw && !raw {
                self.captureMode = .video
                self.statusText = "กล้องหน้า/Format นี้ไม่รองรับ ProRes RAW — ใช้ VIDEO แทน"
            }
        }
    }

    private func freeDiskSpaceGB() -> Double {
        let path = FileManager.default.temporaryDirectory.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else {
            return 0
        }
        return free.doubleValue / 1_073_741_824.0
    }

    private func refreshDiskSpace() {
        let value = freeDiskSpaceGB()
        Task { @MainActor in
            self.availableDiskGB = value
        }
    }

    private func cleanupTemporaryRecordings() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let preserved = Set(recordingSegments + [currentRecordingURL].compactMap { $0 })
        let staleBefore = Date().addingTimeInterval(-300)

        for file in files
        where file.lastPathComponent.hasPrefix("TANOO-") &&
              file.pathExtension.lowercased() == "mov" &&
              !preserved.contains(file) {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < staleBefore {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func startRecordingSegmentOnSessionQueue() {
        guard !movieOutput.isRecording, !isReconfiguring, session.isRunning else {
            Task { @MainActor in
                self.isStartingRecording = false
                self.isPaused = !self.resetDurationOnNextSegment || !self.recordingSegments.isEmpty
                self.recordPreflightMessage = self.isReconfiguring
                    ? "REC ยังไม่เริ่ม: รอเปลี่ยนคุณภาพกล้องให้เสร็จก่อน"
                    : "REC ยังไม่เริ่ม: กล้องยังไม่พร้อมบันทึก"
                self.statusText = self.recordPreflightMessage
            }
            return
        }

        prepareCameraAudioSession()
        configureVideoConnection()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TANOO-" + UUID().uuidString)
            .appendingPathExtension("mov")

        currentRecordingURL = url

        Task { @MainActor in
            self.recordPreflightMessage = ""
            self.statusText = self.recordingSegments.isEmpty
                ? "กำลังเริ่ม REC…"
                : "กำลังบันทึกต่อ…"
        }

        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func finalizeRecordingSegments() {
        guard !recordingSegments.isEmpty else {
            statusText = "ไม่มีช็อตเหลือสำหรับบันทึก • เริ่มถ่ายใหม่ได้"
            completedShotCount = 0
            return
        }
        isSaving = true
        recordingTimer?.invalidate()
        recordingTimer = nil
        if recordingSegments.count == 1, let url = recordingSegments.first {
            saveVideoToPhotos(url)
            return
        }
        statusText = "กำลังรวมช็อต… กรุณารอ"
        let segments = recordingSegments
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TANOO-MERGED-" + UUID().uuidString + ".mov")
        let renderSize = resolution == .uhd4K ? CGSize(width: 2160, height: 3840) : CGSize(width: 1080, height: 1920)
        let fps = Int32(frameRate)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let composition = AVMutableComposition()
            guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                Task { @MainActor in self.exportFailed("สร้างแทร็กไม่ได้") }
                return
            }
            var cursor = CMTime.zero
            var instructions: [AVMutableVideoCompositionInstruction] = []
            var originalTransform: CGAffineTransform?
            var originalSize: CGSize?
            var requiresRendering = false
            do {
                for url in segments {
                    let asset = AVURLAsset(url: url)
                    guard let source = asset.tracks(withMediaType: .video).first else {
                        throw NSError(domain: "TANOO", code: 2001, userInfo: [NSLocalizedDescriptionKey: "ช็อตไม่มีวิดีโอ"])
                    }
                    if let originalTransform, let originalSize {
                        if originalTransform != source.preferredTransform || originalSize != source.naturalSize {
                            requiresRendering = true
                        }
                    } else {
                        originalTransform = source.preferredTransform
                        originalSize = source.naturalSize
                    }
                    let range = source.timeRange
                    try videoTrack.insertTimeRange(range, of: source, at: cursor)
                    if let audio = asset.tracks(withMediaType: .audio).first {
                        let overlap = CMTimeRangeGetIntersection(range, otherRange: audio.timeRange)
                        if overlap.duration > .zero {
                            try audioTrack.insertTimeRange(overlap, of: audio,
                                at: CMTimeAdd(cursor, CMTimeSubtract(overlap.start, range.start)))
                        }
                    }
                    let transform = CameraGeometry.exportTransform(naturalSize: source.naturalSize,
                                                                   preferred: source.preferredTransform,
                                                                   target: renderSize)
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    layer.setTransform(transform, at: cursor)
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
                    instruction.layerInstructions = [layer]
                    instructions.append(instruction)
                    cursor = CMTimeAdd(cursor, range.duration)
                }
                let videoComposition = AVMutableVideoComposition()
                videoComposition.renderSize = renderSize
                videoComposition.frameDuration = CMTime(value: 1, timescale: max(1, fps))
                videoComposition.instructions = instructions
                if !requiresRendering, let originalTransform { videoTrack.preferredTransform = originalTransform }
                let preset = requiresRendering ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough
                guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
                    throw NSError(domain: "TANOO", code: 2002, userInfo: [NSLocalizedDescriptionKey: "สร้างระบบรวมช็อตไม่ได้"])
                }
                if requiresRendering { exporter.videoComposition = videoComposition }
                exporter.outputURL = outputURL
                exporter.outputFileType = .mov
                exporter.exportAsynchronously {
                    Task { @MainActor in
                        if exporter.status == .completed {
                            self.saveVideoToPhotos(outputURL)
                        } else {
                            try? FileManager.default.removeItem(at: outputURL)
                            self.exportFailed(exporter.error?.localizedDescription ?? "รวมช็อตไม่สำเร็จ")
                        }
                    }
                }
            } catch {
                Task { @MainActor in self.exportFailed(error.localizedDescription) }
            }
        }
    }

    private func exportFailed(_ message: String) {
        isSaving = false
        isPaused = !recordingSegments.isEmpty
        statusText = message + " • ช็อตยังอยู่ กด Stop เพื่อลองบันทึกอีกครั้ง"
        recordPreflightMessage = statusText
    }

    private func saveVideoToPhotos(_ url: URL) {
        statusText = "กำลังบันทึกลง Photos…"
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    if !self.recordingSegments.contains(url) { try? FileManager.default.removeItem(at: url) }
                    self.exportFailed("กรุณาอนุญาตให้เพิ่มวิดีโอใน Photos ที่การตั้งค่า")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                Task { @MainActor in
                    if success {
                        for segment in self.recordingSegments { try? FileManager.default.removeItem(at: segment) }
                        try? FileManager.default.removeItem(at: url)
                        self.recordingSegments.removeAll()
                        self.shotCheckpoints.removeAll()
                        self.shotDurations.removeAll()
                        self.completedShotCount = 0
                        self.lastShotSeconds = 0
                        self.isSaving = false
                        self.recordPreflightMessage = ""
                        self.statusText = "บันทึกวิดีโอลง Photos แล้ว"
                    } else {
                        if !self.recordingSegments.contains(url) { try? FileManager.default.removeItem(at: url) }
                        self.exportFailed(error?.localizedDescription ?? "บันทึก Photos ไม่สำเร็จ")
                    }
                    self.refreshDiskSpace()
                }
            }
        }
    }

}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor in
            self.isStartingRecording = false
            self.isRecording = true
            self.isPaused = false
            self.recordPreflightMessage = ""

            if self.resetDurationOnNextSegment {
                self.recordingSeconds = 0
                self.resetDurationOnNextSegment = false
            }

            self.statusText = self.recordingSegments.isEmpty
                ? "REC • " + self.resolution.rawValue + " " + String(Int(self.frameRate)) + "fps"
                : "REC ต่อ • " + self.resolution.rawValue + " " + String(Int(self.frameRate)) + "fps"

            self.recordingTimer?.invalidate()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let current = CMTimeGetSeconds(self.movieOutput.recordedDuration)
                    self.recordingSeconds = self.shotDurations.reduce(0, +) + (current.isFinite ? max(0, current) : 0)
                }
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.isStartingRecording = false
            self.isFinishingSegment = false
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil

            self.currentRecordingURL = nil

            let nsError = error as NSError?
            let finishedSuccessfully = error == nil || (nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
            if !finishedSuccessfully, let error {
                try? FileManager.default.removeItem(at: outputFileURL)
                self.refreshDiskSpace()
                self.isPaused = true
                self.recordingSeconds = self.shotDurations.reduce(0, +)
                if let checkpoint = self.pendingCheckpoint { self.onRestorePrompt?(checkpoint) }
                self.recordPreflightMessage = "REC ERROR: " + error.localizedDescription
                self.statusText = self.recordPreflightMessage
            } else {
                self.recordingSegments.append(outputFileURL)
                self.shotCheckpoints.append(self.pendingCheckpoint)
                let duration = CMTimeGetSeconds(AVURLAsset(url: outputFileURL).duration)
                self.shotDurations.append(duration.isFinite ? max(0, duration) : 0)
                self.recordingSeconds = self.shotDurations.reduce(0, +)
                self.completedShotCount = self.recordingSegments.count
                self.lastShotSeconds = self.shotDurations.last ?? 0

                switch self.stopAction {
                case .pause:
                    self.isPaused = true
                    self.statusText = "PAUSE • กด ▶ เพื่อบันทึกต่อ"

                case .finish:
                    self.isPaused = false
                    self.finalizeRecordingSegments()
                }
            }

            self.stopAction = .finish

            self.sessionQueue.async { [weak self] in
                guard let self else { return }
                if !self.session.isRunning {
                    self.session.startRunning()
                    Task { @MainActor in
                        self.isRunning = self.session.isRunning
                    }
                }
            }
        }
    }
}

extension CameraController: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        speechBridge.append(sampleBuffer)
    }
}

final class CameraSpeechBridge {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "th-TH"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var wantsSpeech = false
    private var statusHandler: ((String) -> Void)?
    private var transcriptHandler: ((String) -> Void)?

    func start(onStatus: @escaping (String) -> Void, onTranscript: @escaping (String) -> Void) {
        // Calls from the controller occur on main; recognition and audio callbacks do not.
        guard !wantsSpeech else { return }
        wantsSpeech = true
        generation = UUID()
        let token = generation
        statusHandler = onStatus
        transcriptHandler = onTranscript
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.wantsSpeech, self.generation == token else { return }
                guard status == .authorized else {
                    self.wantsSpeech = false
                    onStatus("ไม่ได้รับสิทธิ์ Speech Recognition")
                    return
                }
                self.begin(token: token)
            }
        }
    }

    private func begin(token: UUID) {
        guard wantsSpeech, generation == token, let recognizer, recognizer.isAvailable else { return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.taskHint = .dictation
        lock.lock()
        request = next
        lock.unlock()
        task = recognizer.recognitionTask(with: next) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.wantsSpeech, self.generation == token else { return }
                if let result { self.transcriptHandler?(result.bestTranscription.formattedString) }
                if result?.isFinal == true || error != nil {
                    // Invalidate this recognition before cancellation can invoke its callback again.
                    self.generation = UUID()
                    let nextToken = self.generation
                    self.clearRecognition()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.begin(token: nextToken)
                    }
                }
            }
        }
        statusHandler?("Voice กำลังฟังภาษาไทย")
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        request?.appendAudioSampleBuffer(sampleBuffer)
        lock.unlock()
    }

    private func clearRecognition() {
        lock.lock()
        let old = request
        request = nil
        lock.unlock()
        old?.endAudio()
        task?.cancel()
        task = nil
    }

    func stop() {
        wantsSpeech = false
        generation = UUID()
        clearRecognition()
        statusHandler = nil
        transcriptHandler = nil
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var controller: CameraController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.setSession(controller.session)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didLongPress(_:))
        )
        longPress.minimumPressDuration = 0.55

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didTap(_:))
        )
        tap.require(toFail: longPress)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didPan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(tap)
        context.coordinator.previewView = view

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Do not repeatedly mutate AVCaptureConnection while SwiftUI updates.
        // In the previous build the crash happened exactly when PreviewLayer
        // was attached. Let AVCaptureVideoPreviewLayer manage front-camera
        // mirroring automatically for this diagnostic.
        uiView.setSession(controller.session)
        uiView.configureConnection(revision: controller.previewRevision, mirrored: controller.cameraPosition == .front)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        uiView.setSession(nil)
    }

    final class Coordinator: NSObject {
        let controller: CameraController
        weak var previewView: PreviewView?
        private var exposureStart: Float = 0

        @objc func didPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = previewView else { return }
            if gesture.state == .began {
                exposureStart = controller.exposureBias
                let point = gesture.location(in: view)
                if !controller.focusExposureLocked {
                    controller.focus(at: view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
                }
            }
            if gesture.state == .began || gesture.state == .changed {
                let delta = Float(-gesture.translation(in: view).y / max(1, view.bounds.height))
                let bias = exposureStart + delta * (controller.maxExposureBias - controller.minExposureBias)
                controller.setExposureBias(bias)
                view.showExposureIndicator(value: controller.exposureBias)
            }
        }

        init(controller: CameraController) {
            self.controller = controller
        }

        @objc func didTap(_ gesture: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let point = gesture.location(in: view)
            view.showFocusIndicator(at: point, locked: false)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            controller.focus(at: devicePoint)
        }

        @objc func didLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view = previewView else { return }
            let point = gesture.location(in: view)
            view.showFocusIndicator(at: point, locked: true)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            controller.lockFocus(at: devicePoint)
        }
    }
}

final class PreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private var focusIndicator: UIView?
    private let exposureLabel = UILabel()
    private var connectionRevision = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect
        layer.addSublayer(previewLayer)
        exposureLabel.textColor = .systemYellow
        exposureLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        exposureLabel.textAlignment = .center
        exposureLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        exposureLabel.layer.cornerRadius = 12
        exposureLabel.clipsToBounds = true
        exposureLabel.isUserInteractionEnabled = false
        exposureLabel.alpha = 0
        addSubview(exposureLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        exposureLabel.frame = CGRect(x: max(8, bounds.width - 112), y: bounds.height * 0.48, width: 104, height: 40)
        CATransaction.commit()
    }

    func showExposureIndicator(value: Float) {
        exposureLabel.layer.removeAllAnimations()
        exposureLabel.text = String(format: "☀︎ %+.1f", value)
        exposureLabel.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 2, options: [.beginFromCurrentState]) { self.exposureLabel.alpha = 0 }
    }

    func configureConnection(revision: Int, mirrored: Bool) {
        guard connectionRevision != revision, let connection = previewLayer.connection else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        connectionRevision = revision
    }

    func setSession(_ session: AVCaptureSession?) {
        precondition(Thread.isMainThread)
        if previewLayer.session !== session {
            previewLayer.session = session
            connectionRevision = -1
        }
    }

    func showFocusIndicator(at point: CGPoint, locked: Bool) {
        focusIndicator?.removeFromSuperview()

        let box = UIView(frame: CGRect(x: 0, y: 0, width: 68, height: 68))
        box.center = point
        box.backgroundColor = .clear
        box.layer.borderColor = UIColor.systemYellow.cgColor
        box.layer.borderWidth = locked ? 2.2 : 1.6
        box.layer.cornerRadius = 5
        box.isUserInteractionEnabled = false

        let sun = UILabel(frame: CGRect(x: 72, y: 16, width: 30, height: 36))
        sun.text = "☀︎"
        sun.textColor = .systemYellow
        box.addSubview(sun)
        if locked {
            let label = UILabel(frame: CGRect(x: -22, y: 72, width: 112, height: 22))
            label.text = "AE/AF LOCK"
            label.textAlignment = .center
            label.textColor = .systemYellow
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            label.layer.cornerRadius = 6
            label.clipsToBounds = true
            box.addSubview(label)
        }

        addSubview(box)
        focusIndicator = box
        box.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        box.alpha = 0

        UIView.animate(withDuration: 0.18, animations: {
            box.alpha = 1
            box.transform = .identity
        }) { _ in
            UIView.animate(
                withDuration: 0.32,
                delay: locked ? 1.25 : 0.75,
                options: [.curveEaseOut]
            ) {
                box.alpha = 0
            } completion: { [weak self, weak box] _ in
                box?.removeFromSuperview()
                if self?.focusIndicator === box {
                    self?.focusIndicator = nil
                }
            }
        }
    }
}

private extension PromptAlignment {
    var swiftUITextAlignment: TextAlignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    var swiftUIFrameAlignment: Alignment {
        switch self {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

private struct CameraPromptContent: View {
    let snapshot: TeleprompterSnapshot
    let size: CGSize

    var body: some View {
        let scale = max(0.70, min(1.18, size.width / 360.0))
        let fontSize = max(12, snapshot.fontSize * scale)
        let rowHeight = max(42, min(size.height / 3.15, fontSize * 1.55 + snapshot.lineSpacing))
        let eyeY = size.height * 0.43
        let current = max(0, min(snapshot.currentIndex, max(snapshot.segments.count - 1, 0)))

        ZStack(alignment: .topLeading) {
            Color.black.opacity(snapshot.backgroundOpacity)

            Rectangle()
                .fill(Color.white.opacity(0.52))
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: eyeY)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 4, height: 22)
                Spacer()
                Rectangle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 4, height: 22)
            }
            .position(x: size.width / 2, y: eyeY)

            VStack(spacing: 0) {
                ForEach(-1...2, id: \.self) { offset in
                    let index = current + offset
                    let isEyeLine = offset == 0

                    if index >= 0 && index < snapshot.segments.count {
                        let value = snapshot.segments[index]

                        Text(value.isEmpty ? " " : value)
                            .font(.system(
                                size: fontSize,
                                weight: isEyeLine ? .semibold : .regular
                            ))
                            .foregroundStyle(
                                Color(snapshot.textColor.uiColor)
                                    .opacity(isEyeLine ? 1.0 : 0.64)
                            )
                            .multilineTextAlignment(snapshot.alignment.swiftUITextAlignment)
                            .lineSpacing(snapshot.lineSpacing)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: rowHeight,
                                alignment: snapshot.alignment.swiftUIFrameAlignment
                            )
                            .padding(.horizontal, 14)
                    } else {
                        Color.clear.frame(height: rowHeight)
                    }
                }
            }
            .offset(
                y: eyeY
                    - rowHeight * 1.5
                    - CGFloat(snapshot.progress) * rowHeight
            )
        }
        .clipped()
    }
}

private struct MovableResizableTeleprompter: View {
    @ObservedObject var controller: PiPController

    @AppStorage("TANOO.camera.prompt.centerX") private var storedCenterX = 0.5
    @AppStorage("TANOO.camera.prompt.centerY") private var storedCenterY = 0.18
    @AppStorage("TANOO.camera.prompt.width") private var storedWidth = 0.94
    @AppStorage("TANOO.camera.prompt.height") private var storedHeight = 190.0

    @State private var moveStart: CGPoint?
    @State private var resizeStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            let widthRatio = CGFloat(storedWidth)
            let boxHeight = CGFloat(storedHeight)
            let width = max(200, min(geo.size.width * widthRatio, geo.size.width))
            let height = max(120, min(boxHeight, geo.size.height * 0.68))
            let centerX = clamp(
                CGFloat(storedCenterX) * geo.size.width,
                lower: width / 2,
                upper: geo.size.width - width / 2
            )
            let centerY = clamp(
                CGFloat(storedCenterY) * geo.size.height,
                lower: height / 2,
                upper: geo.size.height - height / 2
            )

            TimelineView(.periodic(from: Date(), by: 0.05)) { _ in
                CameraPromptContent(
                    snapshot: controller.snapshot(),
                    size: CGSize(width: width, height: height)
                )
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.58), in: Circle())
                    .padding(3)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if moveStart == nil {
                                    moveStart = CGPoint(
                                        x: CGFloat(storedCenterX),
                                        y: CGFloat(storedCenterY)
                                    )
                                }

                                guard let moveStart else { return }
                                storedCenterX = Double(clamp(
                                    moveStart.x + value.translation.width / max(geo.size.width, 1),
                                    lower: 0,
                                    upper: 1
                                ))
                                storedCenterY = Double(clamp(
                                    moveStart.y + value.translation.height / max(geo.size.height, 1),
                                    lower: 0,
                                    upper: 1
                                ))
                            }
                            .onEnded { _ in
                                moveStart = nil
                            }
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.down.right")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.58), in: Circle())
                    .padding(3)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if resizeStart == nil {
                                    resizeStart = CGSize(
                                        width: CGFloat(storedWidth),
                                        height: CGFloat(storedHeight)
                                    )
                                }

                                guard let resizeStart else { return }
                                storedWidth = Double(clamp(
                                    resizeStart.width + value.translation.width / max(geo.size.width, 1),
                                    lower: 0.50,
                                    upper: 1.0
                                ))
                                storedHeight = Double(clamp(
                                    resizeStart.height + value.translation.height,
                                    lower: 120,
                                    upper: geo.size.height * 0.68
                                ))
                            }
                            .onEnded { _ in
                                resizeStart = nil
                            }
                    )
            }
            .position(x: centerX, y: centerY)
        }
        .ignoresSafeArea()
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

struct CameraStudioView: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var teleprompter: PiPController
    var onOpenScript: (() -> Void)? = nil

    @State private var cameraStarted = false
    @AppStorage("TANOO.camera.controlsExpanded.v31") private var controlsExpanded = false
    @AppStorage("TANOO.camera.countdownSeconds") private var countdownSeconds = 3
    @State private var countdownRemaining: Int?
    @State private var countdownToken = UUID()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if cameraStarted {
                GeometryReader { geometry in
                    let width = min(geometry.size.width, max(1, geometry.size.height - 140) * 9 / 16)
                    CameraPreview(controller: camera)
                        .frame(width: width, height: width * 16 / 9)
                        .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            } else {
                launchCameraView
            }

            if cameraStarted {
                MovableResizableTeleprompter(controller: teleprompter)
            }

            if let countdownRemaining {
                ZStack {
                    Color.black.opacity(0.30)
                        .ignoresSafeArea()

                    Text(String(countdownRemaining))
                        .font(.system(size: 110, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 10)
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 8) {
                Spacer()

                if controlsExpanded {
                    expandedControls
                } else {
                    collapsedTools
                }

                recordDock
            }
            .padding(.bottom, 4)
            .ignoresSafeArea(edges: .bottom)
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            teleprompter.setUsesExternalSpeech(true)
            camera.checkpointProvider = { teleprompter.recordingCheckpoint() }
            camera.onRestorePrompt = { checkpoint in teleprompter.restoreRecordingCheckpoint(checkpoint) }
            camera.onTranscript = { transcript in
                Task { @MainActor in
                    teleprompter.receiveExternalTranscript(transcript)
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            countdownToken = UUID()
            countdownRemaining = nil
            camera.stopSpeech()
            camera.stop()
            teleprompter.setUsesExternalSpeech(false)
            cameraStarted = false
        }
        .onChange(of: teleprompter.mode) { _ in
            syncSpeech()
        }
        .onChange(of: camera.isRecording) { recording in
            if recording {
                if !teleprompter.isRunning {
                    teleprompter.start()
                }
                syncSpeech()
            } else {
                camera.stopSpeech()
                if !camera.isStartingRecording && teleprompter.isRunning {
                    teleprompter.pause()
                }
            }
        }
        .onChange(of: camera.isPaused) { paused in
            if paused {
                camera.stopSpeech()
                if teleprompter.isRunning {
                    teleprompter.pause()
                }
            }
        }
        .onChange(of: camera.resolution) { _ in
            if cameraStarted { camera.reconfigure() }
        }
        .onChange(of: camera.frameRate) { _ in
            if cameraStarted { camera.reconfigure() }
        }
    }

    private var launchCameraView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white)

            Text("TANOO Camera")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Button("เปิดกล้อง") {
                cameraStarted = true
                camera.start()
            }
            .buttonStyle(.borderedProminent)

            Button("Script") {
                onOpenScript?()
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.white)
        }
    }

    private var recordInfoBar: some View {
        HStack(spacing: 7) {
            if camera.isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC " + formatDuration(camera.recordingSeconds))
                        .foregroundStyle(.red)
                        .fontWeight(.semibold)
                }
            } else if camera.isPaused {
                Text("PAUSE " + formatDuration(camera.recordingSeconds))
                    .foregroundStyle(.yellow)
                    .fontWeight(.semibold)
            } else if camera.isStartingRecording {
                Text("กำลังเริ่ม REC…")
                    .foregroundStyle(.orange)
            }

            Spacer()

            Text(camera.resolution.rawValue)
            Text("·")
            Text(String(Int(camera.frameRate)) + " FPS")
            Text("·")
            Text(String(format: "%.1f GB", camera.availableDiskGB))
        }
        .font(.caption2)
    }

    private var collapsedTools: some View {
        HStack(spacing: 12) {
            Button {
                onOpenScript?()
            } label: {
                Image(systemName: "doc.text")
            }
            .disabled(activeTake)

            Button {
                teleprompter.fontSize = max(12, teleprompter.fontSize - 2)
            } label: {
                Text("A−")
            }

            Text(String(Int(teleprompter.fontSize)))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 26)

            Button {
                teleprompter.fontSize = min(68, teleprompter.fontSize + 2)
            } label: {
                Text("A+")
            }

            Spacer()

            Button {
                controlsExpanded = true
            } label: {
                Label("เครื่องมือ", systemImage: "chevron.up")
            }
        }
        .disabled(activeTake)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 15))
        .padding(.horizontal, 8)
    }

    private var expandedControls: some View {
        ScrollView {
            VStack(spacing: 9) {
                HStack {
                    Button {
                        onOpenScript?()
                    } label: {
                        Label("Script", systemImage: "doc.text")
                    }
                    .disabled(activeTake)

                    Spacer()

                    Button {
                        controlsExpanded = false
                    } label: {
                        Label("ซ่อน", systemImage: "chevron.down")
                    }
                }

                HStack {
                    ForEach(CameraCaptureMode.allCases) { mode in
                        Button(mode.title) { camera.selectMode(mode) }
                            .font(.caption.bold())
                            .foregroundStyle(camera.captureMode == mode ? .yellow : .white)
                            .disabled(activeTake || !camera.supportsMode(mode) || camera.isReconfiguring)
                    }
                    Spacer()
                    Text("v3.1").font(.caption2)
                }
                if camera.captureMode == .cinematic {
                    slider(title: "Cinematic เบลอ", valueText: String(format: "f/%.1f", camera.simulatedAperture),
                           value: Binding(get: { Double(camera.simulatedAperture) }, set: { camera.setAperture(Float($0)) }),
                           range: Double(camera.minSimulatedAperture)...Double(camera.maxSimulatedAperture))
                        .disabled(activeTake)
                }
                Text("Portrait กล้องหน้าใช้ 1080p30 • เปิด/ปิดในแผงเอฟเฟ็กต์ของ iOS • CINE / PRO / RAW แสดงตามที่กล้องรองรับ")
                    .font(.caption2).foregroundStyle(.secondary)

                Picker("Mode", selection: $teleprompter.mode) {
                    ForEach(TeleprompterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if teleprompter.mode != .auto {
                    HStack(spacing: 8) {
                        Text("Focus Voice")
                            .font(.caption2)

                        Picker("Focus Voice", selection: $teleprompter.voiceFocusLevel) {
                            ForEach(VoiceFocusLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                HStack(spacing: 8) {
                    Picker("Resolution", selection: $camera.resolution) {
                        Text("1080p").tag(CameraResolution.hd1080)
                        Text("4K").tag(CameraResolution.uhd4K)
                    }
                    .pickerStyle(.segmented)

                    Picker("FPS", selection: $camera.frameRate) {
                        Text("30").tag(30.0)
                        Text("60").tag(60.0)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(
                    !cameraStarted ||
                    camera.isRecording ||
                    camera.isPaused ||
                    camera.isStartingRecording ||
                    camera.isReconfiguring
                )

                HStack(spacing: 8) {
                    Text("Countdown")
                        .font(.caption2)

                    Picker("Countdown", selection: $countdownSeconds) {
                        Text("Off").tag(0)
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("10").tag(10)
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 8) {
                    Button {
                        teleprompter.previous()
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        teleprompter.toggleRunning()
                    } label: {
                        Label(
                            teleprompter.isRunning ? "Pause Text" : "Start Text",
                            systemImage: teleprompter.isRunning ? "pause.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        teleprompter.next()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button {
                        teleprompter.autoSpeed = max(0.5, teleprompter.autoSpeed - 0.1)
                    } label: {
                        Text("Speed −")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        teleprompter.fontSize = max(12, teleprompter.fontSize - 2)
                    } label: {
                        Text("A−")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Text(String(Int(teleprompter.fontSize)))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 26)

                    Button {
                        teleprompter.fontSize = min(68, teleprompter.fontSize + 2)
                    } label: {
                        Text("A+")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        teleprompter.autoSpeed = min(2.5, teleprompter.autoSpeed + 0.1)
                    } label: {
                        Text("Speed +")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    slider(
                        title: "Zoom",
                        valueText: String(format: "%.1fx", camera.zoomFactor),
                        value: Binding(
                            get: { Double(camera.zoomFactor) },
                            set: { camera.setZoom(CGFloat($0)) }
                        ),
                        range: Double(camera.minZoomFactor)...Double(max(camera.maxZoomFactor, camera.minZoomFactor + 0.1))
                    )

                    slider(
                        title: "Exposure",
                        valueText: String(format: "%+.1f", camera.exposureBias),
                        value: Binding(
                            get: { Double(camera.exposureBias) },
                            set: { camera.setExposureBias(Float($0)) }
                        ),
                        range: Double(camera.minExposureBias)...Double(max(camera.maxExposureBias, camera.minExposureBias + 0.1))
                    )
                }
                .disabled(!cameraStarted)

                HStack(spacing: 8) {
                    Button {
                        camera.enableAutoFocus()
                    } label: {
                        Label("AF AUTO", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Text(camera.focusExposureLocked ? "AE/AF LOCK" : "Auto / Tap Focus")
                        .font(.caption2.bold())
                        .foregroundStyle(camera.focusExposureLocked ? .yellow : .secondary)
                        .frame(maxWidth: .infinity)
                }

                Text("แตะภาพ = Focus • ลากขึ้น/ลงบนภาพ = เพิ่ม/ลดแสง • กดค้าง = AE/AF LOCK • AF AUTO = ปลดล็อก")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(camera.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if teleprompter.mode != .auto {
                    Text(teleprompter.speechStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(11)
        }
        .disabled(activeTake)
        .frame(maxHeight: 370)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 6)
    }

    private var recordDock: some View {
        VStack(spacing: 7) {
            recordInfoBar
                .foregroundStyle(.white)
                .padding(.horizontal, 14)

            HStack(spacing: 16) {
                Button { camera.switchCamera() } label: {
                    Label(camera.cameraPosition == .front ? "กล้องหน้า" : "กล้องหลัง", systemImage: "arrow.triangle.2.circlepath.camera")
                }
                .disabled(camera.isRecording || camera.isStartingRecording || camera.isFinishingSegment || camera.isSaving || camera.isReconfiguring || countdownRemaining != nil)
                Spacer()
                Button { camera.openPortraitControls() } label: {
                    Label(camera.portraitActive ? "เบลอ: เปิด" : "หน้าชัดหลังเบลอ", systemImage: "person.crop.rectangle")
                }
                .disabled(activeTake || camera.isReconfiguring || !camera.portraitSupported || camera.cameraPosition != .front)
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)

            if camera.isPaused && countdownRemaining == nil {
                Button {
                    camera.deleteLastShot()
                } label: {
                    Label("ลบช็อตล่าสุด (" + String(format: "%.1f", camera.lastShotSeconds) + " วินาที) · เหลือ " + String(camera.completedShotCount) + " ช็อต", systemImage: "arrow.uturn.backward")
                }
                .font(.caption.bold())
                .foregroundStyle(.yellow)
                .disabled(camera.completedShotCount == 0 || camera.isReconfiguring || camera.isSaving)
            }

            Text(camera.isSaving ? "กำลังบันทึก… กรุณารอ" : camera.statusText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .padding(.horizontal, 14)

            if !camera.recordPreflightMessage.isEmpty {
                Text(camera.recordPreflightMessage)
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            } else if camera.isStartingRecording {
                Text("กำลังเตรียม REC…")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            ZStack {
                HStack {
                    Group {
                        if camera.isRecording {
                            Button {
                                pauseVideo()
                            } label: {
                                Image(systemName: "pause.fill")
                                    .font(.title3.bold())
                                    .frame(width: 52, height: 52)
                                    .background(.white.opacity(0.17), in: Circle())
                            }
                            .disabled(camera.isFinishingSegment)
                            .accessibilityLabel("Pause Recording")
                        } else if camera.isPaused {
                            Button {
                                resumeVideo()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.title3.bold())
                                    .frame(width: 52, height: 52)
                                    .background(.white.opacity(0.17), in: Circle())
                            }
                            .disabled(countdownRemaining != nil || camera.isReconfiguring || camera.isSaving)
                            .accessibilityLabel("Resume Recording")
                        } else {
                            Color.clear.frame(width: 52, height: 52)
                        }
                    }

                    Spacer()

                    Button {
                        controlsExpanded.toggle()
                    } label: {
                        Image(systemName: controlsExpanded ? "chevron.down" : "slider.horizontal.3")
                            .font(.headline.bold())
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                }

                Button {
                    shutterPressed()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white, lineWidth: 5)
                            .frame(width: 78, height: 78)

                        if countdownRemaining != nil {
                            Circle().fill(Color.orange).frame(width: 62, height: 62)
                        } else if camera.isRecording || camera.isPaused {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.red)
                                .frame(width: 34, height: 34)
                        } else if countdownRemaining != nil {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 62, height: 62)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 62, height: 62)
                        }
                    }
                    .contentShape(Circle())
                }
                .disabled(!shutterEnabled)
                .opacity(shutterEnabled ? 1 : 0.45)
                .accessibilityLabel(
                    countdownRemaining != nil ? "Cancel Countdown" :
                        (camera.isRecording || camera.isPaused ? "Stop Recording" : "Start Recording")
                )
            }
            .frame(height: 82)
            .padding(.horizontal, 26)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.black.opacity(0.86))
    }

    private var activeTake: Bool {
        camera.isRecording || camera.isPaused || camera.isStartingRecording || camera.isFinishingSegment || camera.isSaving || countdownRemaining != nil
    }

    private var shutterEnabled: Bool {
        if camera.isSaving || camera.isFinishingSegment || camera.isReconfiguring { return false }
        if camera.isRecording || camera.isPaused {
            return true
        }

        return cameraStarted &&
            camera.isConfigured &&
            !camera.isReconfiguring &&
            !camera.isStartingRecording
    }

    private func shutterPressed() {
        if countdownRemaining != nil {
            cancelCountdown()
            return
        }
        if camera.isRecording || camera.isPaused {
            camera.finishRecording()
            camera.stopSpeech()
            teleprompter.pause()
            return
        }
        runCountdown(resuming: false)
    }

    private func runCountdown(resuming: Bool) {
        guard countdownRemaining == nil, shutterEnabled else { return }
        camera.stopSpeech()
        teleprompter.pause()
        controlsExpanded = false
        // Resume always gets at least three seconds, even if initial countdown is Off.
        let seconds = CameraGeometry.countdown(configured: countdownSeconds, resuming: resuming)
        let token = UUID()
        countdownToken = token
        countdownRemaining = max(1, seconds)
        Task { @MainActor in
            if seconds > 0 {
                for value in stride(from: seconds, through: 1, by: -1) {
                    guard countdownToken == token else { return }
                    countdownRemaining = value
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            guard countdownToken == token else { return }
            countdownRemaining = nil
            if resuming { camera.resumeRecording() } else { beginRecording() }
        }
    }

    private func pauseVideo() {
        camera.stopSpeech()
        camera.pauseRecording()

        if teleprompter.isRunning {
            teleprompter.pause()
        }
    }

    private func resumeVideo() {
        runCountdown(resuming: true)
    }

    private func cancelCountdown() {
        countdownToken = UUID()
        countdownRemaining = nil
    }

    private func beginRecording() {
        guard shutterEnabled else { return }

        if teleprompter.isRunning {
            teleprompter.pause()
        }
        teleprompter.resetPosition()

        camera.startNewTake()

        // If recording never reaches didStartRecording, keep the prompt stopped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !camera.isRecording &&
               !camera.isStartingRecording &&
               !camera.isPaused &&
               teleprompter.isRunning {
                teleprompter.pause()
            }
        }
    }

    private func syncSpeech() {
        guard cameraStarted,
              camera.isConfigured,
              camera.isRecording,
              teleprompter.isRunning,
              teleprompter.mode != .auto else {
            camera.stopSpeech()
            return
        }

        camera.startSpeech()
    }

    private func slider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)

            Slider(value: value, in: range)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private enum TANOOAppTab: Hashable {
    case camera
    case script
}

struct ContentView: View {
    @StateObject private var teleprompter = PiPController()
    @StateObject private var camera = CameraController()
    @State private var selectedTab: TANOOAppTab = .camera

    var body: some View {
        TabView(selection: $selectedTab) {
            CameraStudioView(
                camera: camera,
                teleprompter: teleprompter,
                onOpenScript: {
                    selectedTab = .script
                }
            )
            .tag(TANOOAppTab.camera)
                .tabItem {
                    Label("Camera", systemImage: "video.fill")
                }

            TeleprompterSetupView(
                teleprompter: teleprompter,
                onOpenCamera: {
                    selectedTab = .camera
                }
            )
            .tag(TANOOAppTab.script)
            .tabItem {
                Label("Script", systemImage: "text.alignleft")
            }
        }
    }
}
