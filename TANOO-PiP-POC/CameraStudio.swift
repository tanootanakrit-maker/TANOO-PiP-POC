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

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var captureMode: CameraCaptureMode = .video
    @Published var resolution: CameraResolution = .hd1080
    @Published var frameRate: Double = 30

    @Published private(set) var isConfigured = false
    @Published private(set) var isPreviewOnly = false
    @Published private(set) var diagnosticStage = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isStartingRecording = false
    @Published private(set) var isReconfiguring = false
    @Published private(set) var statusText = "กำลังเตรียมกล้อง…"
    @Published private(set) var recordingSeconds: TimeInterval = 0

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

    private let sessionQueue = DispatchQueue(label: "com.tanoo.camera.session")
    private let audioQueue = DispatchQueue(label: "com.tanoo.camera.audio")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var currentDevice: AVCaptureDevice?
    private var recordingTimer: Timer?
    private var currentRecordingURL: URL?
    private let speechBridge = CameraSpeechBridge()

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
        guard isConfigured, !isRecording, !isStartingRecording, !isReconfiguring else { return }

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
        guard supportsMode(mode) else {
            statusText = mode.title + " ไม่รองรับกับกล้อง/Format ปัจจุบัน"
            return
        }
        captureMode = mode
        reconfigure()
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

    func toggleFocusExposureLock() {
        focusExposureLocked.toggle()
        let shouldLock = focusExposureLocked

        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()

                if self.captureMode == .cinematic {
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

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()

                if self.captureMode == .cinematic {
                    if #available(iOS 26.0, *) {
                        device.setCinematicVideoTrackingFocus(at: devicePoint, focusMode: .strong)
                    }
                } else {
                    if device.isFocusPointOfInterestSupported {
                        device.focusPointOfInterest = devicePoint
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
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
            } catch {
                Task { @MainActor in
                    self.statusText = "แตะ Focus ไม่สำเร็จ: " + error.localizedDescription
                }
            }
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
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
            // Advanced modes keep format-specific capability checks.
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
            connection.isVideoMirrored = true
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
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

    private func startRecording() {
        guard isConfigured,
              !movieOutput.isRecording,
              !isStartingRecording,
              !isReconfiguring,
              session.isRunning else {
            statusText = isReconfiguring ? "รอเปลี่ยนคุณภาพกล้องให้เสร็จก่อน" : "กล้องยังไม่พร้อมบันทึก"
            return
        }

        prepareCameraAudioSession()
        configureVideoConnection()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TANOO-" + UUID().uuidString)
            .appendingPathExtension("mov")

        currentRecordingURL = url
        recordingSeconds = 0
        isStartingRecording = true
        statusText = "กำลังเริ่ม REC…"

        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    private func stopRecording() {
        guard movieOutput.isRecording else {
            isStartingRecording = false
            return
        }
        movieOutput.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil
        statusText = "กำลังปิดไฟล์วิดีโอ…"
    }

    private func saveVideoToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in
                    self?.statusText = "วิดีโอถ่ายสำเร็จ แต่ไม่ได้รับสิทธิ์บันทึกลง Photos"
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                Task { @MainActor in
                    if success {
                        self?.statusText = "บันทึกวิดีโอลง Photos แล้ว"
                    } else {
                        self?.statusText = "บันทึก Photos ไม่สำเร็จ: " + (error?.localizedDescription ?? "Unknown error")
                    }
                }
                try? FileManager.default.removeItem(at: url)
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
            self.recordingSeconds = 0
            self.statusText = "REC • " + self.captureMode.title + " " + self.resolution.rawValue + " " + String(Int(self.frameRate)) + "fps"

            self.recordingTimer?.invalidate()
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.recordingSeconds += 0.25
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
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil

            if let error {
                self.statusText = "REC ERROR: " + error.localizedDescription
            } else if self.recordingSeconds < 0.5 {
                self.statusText = "REC หยุดก่อน 1 วินาที — ตรวจระบบเสียง/Voice"
                try? FileManager.default.removeItem(at: outputFileURL)
            } else {
                self.saveVideoToPhotos(outputFileURL)
            }

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
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var active = false

    func start(
        onStatus: @escaping (String) -> Void,
        onTranscript: @escaping (String) -> Void
    ) {
        stop()

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self else { return }
            guard status == .authorized else {
                onStatus("ไม่ได้รับสิทธิ์ Speech Recognition")
                return
            }

            guard let recognizer = self.recognizer, recognizer.isAvailable else {
                onStatus("Speech Recognition ยังไม่พร้อม")
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation

            self.lock.lock()
            self.recognitionRequest = request
            self.active = true
            self.lock.unlock()

            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    onTranscript(result.bestTranscription.formattedString)
                }
                if error != nil {
                    self.lock.lock()
                    self.active = false
                    self.lock.unlock()
                }
            }

            onStatus("Hybrid/Voice ใช้เสียงจาก TANOO Camera")
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let request = active ? recognitionRequest : nil
        lock.unlock()
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    func stop() {
        lock.lock()
        active = false
        let request = recognitionRequest
        recognitionRequest = nil
        let task = recognitionTask
        recognitionTask = nil
        lock.unlock()

        request?.endAudio()
        task?.cancel()
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

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.didTap(_:))
        )
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
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        uiView.setSession(nil)
    }

    final class Coordinator: NSObject {
        let controller: CameraController
        weak var previewView: PreviewView?

        init(controller: CameraController) {
            self.controller = controller
        }

        @objc func didTap(_ gesture: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let point = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            controller.focus(at: devicePoint)
        }
    }
}

final class PreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func setSession(_ session: AVCaptureSession?) {
        precondition(Thread.isMainThread)
        if previewLayer.session !== session {
            previewLayer.session = session
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
        let scale = max(0.72, min(1.15, size.width / 360.0))
        let fontSize = max(20, snapshot.fontSize * scale)
        let rowHeight = max(48, fontSize * 1.55 + snapshot.lineSpacing)
        let current = max(0, min(snapshot.currentIndex, max(snapshot.segments.count - 1, 0)))
        let positionAdjustment = size.height * CGFloat(snapshot.verticalPosition - 0.18) * 0.35

        ZStack {
            Color.black.opacity(snapshot.backgroundOpacity)

            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { offset in
                    let index = current + offset

                    if index < snapshot.segments.count {
                        let value = snapshot.segments[index]
                        let alpha = offset == 0 ? 1.0 : max(0.42, 0.80 - Double(offset) * 0.12)

                        Text(value.isEmpty ? " " : value)
                            .font(.system(
                                size: fontSize,
                                weight: offset == 0 ? .semibold : .regular
                            ))
                            .foregroundStyle(Color(snapshot.textColor.uiColor).opacity(alpha))
                            .multilineTextAlignment(snapshot.alignment.swiftUITextAlignment)
                            .lineSpacing(snapshot.lineSpacing)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: rowHeight,
                                alignment: snapshot.alignment.swiftUIFrameAlignment
                            )
                            .padding(.horizontal, 12)
                    } else {
                        Color.clear
                            .frame(height: rowHeight)
                    }
                }
            }
            .offset(
                y: positionAdjustment - CGFloat(snapshot.progress) * rowHeight
            )
        }
        .clipped()
    }
}

private struct MovableResizableTeleprompter: View {
    @ObservedObject var controller: PiPController

    @State private var centerXRatio: CGFloat = 0.5
    @State private var centerYRatio: CGFloat = 0.30
    @State private var widthRatio: CGFloat = 0.92
    @State private var boxHeight: CGFloat = 190

    @State private var moveStart: CGPoint?
    @State private var resizeStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            let width = max(220, min(geo.size.width * widthRatio, geo.size.width - 16))
            let height = max(110, min(boxHeight, geo.size.height * 0.58))
            let centerX = clamp(
                centerXRatio * geo.size.width,
                lower: width / 2 + 8,
                upper: geo.size.width - width / 2 - 8
            )
            let centerY = clamp(
                centerYRatio * geo.size.height,
                lower: height / 2 + 8,
                upper: geo.size.height - height / 2 - 8
            )

            TimelineView(.periodic(from: Date(), by: 0.05)) { _ in
                CameraPromptContent(
                    snapshot: controller.snapshot(),
                    size: CGSize(width: width, height: height)
                )
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.32), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                Label("ย้าย", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.68), in: Capsule())
                    .padding(6)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if moveStart == nil {
                                    moveStart = CGPoint(x: centerXRatio, y: centerYRatio)
                                }

                                guard let moveStart else { return }
                                centerXRatio = clamp(
                                    moveStart.x + value.translation.width / max(geo.size.width, 1),
                                    lower: 0,
                                    upper: 1
                                )
                                centerYRatio = clamp(
                                    moveStart.y + value.translation.height / max(geo.size.height, 1),
                                    lower: 0,
                                    upper: 1
                                )
                            }
                            .onEnded { _ in
                                moveStart = nil
                            }
                    )
            }
            .overlay(alignment: .bottomTrailing) {
                Label("ขยาย", systemImage: "arrow.up.left.and.down.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.68), in: Capsule())
                    .padding(6)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if resizeStart == nil {
                                    resizeStart = CGSize(width: widthRatio, height: boxHeight)
                                }

                                guard let resizeStart else { return }
                                widthRatio = clamp(
                                    resizeStart.width + value.translation.width / max(geo.size.width, 1),
                                    lower: 0.55,
                                    upper: 0.98
                                )
                                boxHeight = clamp(
                                    resizeStart.height + value.translation.height,
                                    lower: 110,
                                    upper: geo.size.height * 0.58
                                )
                            }
                            .onEnded { _ in
                                resizeStart = nil
                            }
                    )
            }
            .position(x: centerX, y: centerY)
        }
        .allowsHitTesting(true)
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), max(lower, upper))
    }
}

struct CameraStudioView: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var teleprompter: PiPController
    @State private var cameraStarted = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    cameraArea
                    controlArea
                }
            }
            .navigationTitle("TANOO Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                teleprompter.setUsesExternalSpeech(true)
                camera.onTranscript = { transcript in
                    Task { @MainActor in
                        teleprompter.receiveExternalTranscript(transcript)
                    }
                }
            }
            .onDisappear {
                camera.stopSpeech()
                camera.stop()
                teleprompter.setUsesExternalSpeech(false)
                cameraStarted = false
            }
            .onChange(of: teleprompter.isRunning) { _ in
                syncSpeech()
            }
            .onChange(of: teleprompter.mode) { _ in
                syncSpeech()
            }
            .onChange(of: camera.resolution) { _ in
                if cameraStarted { camera.reconfigure() }
            }
            .onChange(of: camera.frameRate) { _ in
                if cameraStarted { camera.reconfigure() }
            }
        }
    }

    private var cameraArea: some View {
        ZStack {
            if cameraStarted {
                CameraPreview(controller: camera)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.black)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 14) {
                            Image(systemName: "video.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.white)

                            Text("TANOO Camera")
                                .font(.headline)
                                .foregroundStyle(.white)

                            Button("เปิดกล้อง") {
                                cameraStarted = true
                                camera.start()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
            }

            if cameraStarted {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        statusBadge(camera.captureMode.title)
                        statusBadge(camera.resolution.rawValue)
                        statusBadge(String(Int(camera.frameRate)) + " FPS")
                        Spacer()
                        statusBadge(String(format: "%.1fx", camera.zoomFactor))
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    Spacer()
                }

                MovableResizableTeleprompter(controller: teleprompter)

                VStack {
                    Spacer()

                    if camera.isRecording {
                        Text("● REC  " + formatDuration(camera.recordingSeconds))
                            .font(.system(.headline, design: .monospaced).bold())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private var controlArea: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Teleprompter Mode", selection: $teleprompter.mode) {
                    ForEach(TeleprompterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

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
                .disabled(!cameraStarted || camera.isRecording)

                slider(
                    title: "Zoom",
                    valueText: String(format: "%.1fx", camera.zoomFactor),
                    value: Binding(
                        get: { Double(camera.zoomFactor) },
                        set: { camera.setZoom(CGFloat($0)) }
                    ),
                    range: Double(camera.minZoomFactor)...Double(max(camera.maxZoomFactor, camera.minZoomFactor + 0.1))
                )
                .disabled(!cameraStarted)

                slider(
                    title: "Exposure",
                    valueText: String(format: "%+.1f EV", camera.exposureBias),
                    value: Binding(
                        get: { Double(camera.exposureBias) },
                        set: { camera.setExposureBias(Float($0)) }
                    ),
                    range: Double(camera.minExposureBias)...Double(max(camera.maxExposureBias, camera.minExposureBias + 0.1))
                )
                .disabled(!cameraStarted)

                HStack(spacing: 8) {
                    Button {
                        teleprompter.previous()
                    } label: {
                        Label("ย้อน", systemImage: "backward.end.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        teleprompter.toggleRunning()
                    } label: {
                        Label(
                            teleprompter.isRunning ? "Pause" : "Start",
                            systemImage: teleprompter.isRunning ? "pause.fill" : "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        teleprompter.next()
                    } label: {
                        Label("ถัดไป", systemImage: "forward.end.fill")
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
                        camera.toggleFocusExposureLock()
                    } label: {
                        Label(
                            camera.focusExposureLocked ? "AE/AF LOCK" : "Lock",
                            systemImage: camera.focusExposureLocked ? "lock.fill" : "lock.open"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!cameraStarted)

                    Button {
                        teleprompter.autoSpeed = min(2.5, teleprompter.autoSpeed + 0.1)
                    } label: {
                        Text("Speed +")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    recordButtonPressed()
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(camera.isRecording ? Color.white : Color.red)
                            .frame(width: 22, height: 22)

                        Text(camera.isRecording ? "STOP RECORDING" : "REC")
                            .font(.headline.bold())
                    }
                    .foregroundStyle(camera.isRecording ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!cameraStarted || !camera.isConfigured)

                Text(camera.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if teleprompter.mode != .auto {
                    Text(teleprompter.speechStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("กรอบ Teleprompter: ลาก “ย้าย” เพื่อเปลี่ยนตำแหน่ง และลาก “ขยาย” ที่มุมขวาล่างเพื่อปรับขนาด • ข้อความไม่ถูกฝังลงไฟล์วิดีโอ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func recordButtonPressed() {
        if camera.isRecording {
            camera.stopSpeech()
            camera.toggleRecording()

            if teleprompter.isRunning {
                teleprompter.pause()
            }
            return
        }

        if !teleprompter.isRunning {
            teleprompter.start()
        }

        camera.toggleRecording()

        if teleprompter.mode != .auto {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if camera.isRecording {
                    camera.startSpeech()
                }
            }
        }
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.7), in: Capsule())
    }

    private func slider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range)
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
            CameraStudioView(camera: camera, teleprompter: teleprompter)
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
