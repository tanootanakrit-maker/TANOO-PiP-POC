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

    @Published var captureMode: CameraCaptureMode = .cinematic
    @Published var resolution: CameraResolution = .uhd4K
    @Published var frameRate: Double = 30

    @Published private(set) var isConfigured = false
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
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
        guard isConfigured, !isRecording else { return }
        sessionQueue.async { [weak self] in
            self?.applyCaptureSettings()
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
            statusText = "(mode.title) ไม่รองรับกับกล้อง/Format ปัจจุบัน"
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
                    self.statusText = "ปรับ Zoom ไม่สำเร็จ: (error.localizedDescription)"
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
                    self.statusText = "ปรับแสงไม่สำเร็จ: (error.localizedDescription)"
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
                    self.statusText = "ล็อก Focus/Exposure ไม่สำเร็จ: (error.localizedDescription)"
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
                    self.statusText = "แตะ Focus ไม่สำเร็จ: (error.localizedDescription)"
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
            if !session.isRunning { session.startRunning() }
            Task { @MainActor in self.isRunning = self.session.isRunning }
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        guard let camera = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
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

            applyCaptureSettings(manageSessionConfiguration: false)

            updateCapabilities()

            if !session.isRunning {
                session.startRunning()
            }

            Task { @MainActor in
                self.isConfigured = true
                self.isRunning = self.session.isRunning
                self.statusText = "TANOO Camera พร้อมใช้งาน"
            }
        } catch {
            Task { @MainActor in
                self.statusText = "ตั้งค่ากล้องไม่สำเร็จ: (error.localizedDescription)"
            }
        }
    }

    private func applyCaptureSettings(manageSessionConfiguration: Bool = true) {
        guard let device = currentDevice, let input = videoInput else { return }

        if manageSessionConfiguration {
            session.beginConfiguration()
        }
        defer {
            if manageSessionConfiguration {
                session.commitConfiguration()
            }
        }

        if #available(iOS 26.0, *) {
            if input.isCinematicVideoCaptureEnabled {
                input.isCinematicVideoCaptureEnabled = false
            }
        }

        let requestedMode = captureMode
        let dimensions = resolution.dimensions

        let candidates = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard d.width == dimensions.width, d.height == dimensions.height else { return false }

            if requestedMode == .cinematic {
                if #available(iOS 26.0, *) {
                    guard format.isCinematicVideoCaptureSupported,
                          let range = format.videoFrameRateRangeForCinematicVideo else { return false }
                    return frameRate >= range.minFrameRate && frameRate <= range.maxFrameRate
                } else {
                    return false
                }
            }

            return format.videoSupportedFrameRateRanges.contains {
                frameRate >= $0.minFrameRate && frameRate <= $0.maxFrameRate
            }
        }

        if let selected = candidates.first {
            do {
                try device.lockForConfiguration()
                device.activeFormat = selected

                let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration

                if device.isExposureModeSupported(.continuousAutoExposure) && !focusExposureLocked {
                    device.exposureMode = .continuousAutoExposure
                }
                if captureMode != .cinematic,
                   device.isFocusModeSupported(.continuousAutoFocus),
                   !focusExposureLocked {
                    device.focusMode = .continuousAutoFocus
                }

                device.unlockForConfiguration()
            } catch {
                Task { @MainActor in
                    self.statusText = "เลือก (resolution.rawValue) (Int(frameRate))fps ไม่สำเร็จ"
                }
            }
        } else {
            Task { @MainActor in
                self.statusText = "ไม่พบ Format (resolution.rawValue) (Int(frameRate))fps สำหรับ (captureMode.title)"
            }
        }

        if captureMode == .cinematic {
            if #available(iOS 26.0, *) {
                if input.isCinematicVideoCaptureSupported {
                    input.isCinematicVideoCaptureEnabled = true
                    let minA = device.activeFormat.minSimulatedAperture
                    let maxA = device.activeFormat.maxSimulatedAperture
                    if minA > 0, maxA >= minA {
                        let aperture = min(max(simulatedAperture, minA), maxA)
                        input.simulatedAperture = aperture
                    }
                }
            }
        }

        configureVideoConnection()
        updateCapabilities()
    }

    private func configureVideoConnection() {
        guard let connection = movieOutput.connection(with: .video) else { return }

        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
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
        guard isConfigured, !movieOutput.isRecording else { return }

        configureVideoConnection()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TANOO-(UUID().uuidString)")
            .appendingPathExtension("mov")

        currentRecordingURL = url
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        recordingSeconds = 0
        statusText = "REC • (captureMode.title) (resolution.rawValue) (Int(frameRate))fps"

        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingSeconds += 0.25
            }
        }
    }

    private func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil
        statusText = "กำลังบันทึกลง Photos…"
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
                        self?.statusText = "บันทึก Photos ไม่สำเร็จ: (error?.localizedDescription ?? "Unknown error")"
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
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil

            if let error {
                self.statusText = "บันทึกวิดีโอผิดพลาด: (error.localizedDescription)"
            } else {
                self.saveVideoToPhotos(outputFileURL)
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
        view.previewLayer.session = controller.session
        view.previewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.previewView = view

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = controller.session
        if let connection = uiView.previewLayer.connection {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
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
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CameraTeleprompterOverlayView: UIViewRepresentable {
    let controller: PiPController

    func makeUIView(context: Context) -> TeleprompterVideoView {
        let view = TeleprompterVideoView()
        DispatchQueue.main.async {
            controller.attachCameraOverlay(view)
        }
        return view
    }

    func updateUIView(_ uiView: TeleprompterVideoView, context: Context) {
        uiView.render(snapshot: controller.snapshot())
    }

    static func dismantleUIView(_ uiView: TeleprompterVideoView, coordinator: ()) {
    }
}

struct CameraStudioView: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var teleprompter: PiPController

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    cameraSurface
                    controlsPanel
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
                camera.start()
                syncSpeech()
            }
            .onDisappear {
                camera.stopSpeech()
                camera.stop()
                teleprompter.setUsesExternalSpeech(false)
            }
            .onChange(of: teleprompter.isRunning) { _ in syncSpeech() }
            .onChange(of: teleprompter.mode) { _ in syncSpeech() }
            .onChange(of: camera.resolution) { _ in camera.reconfigure() }
            .onChange(of: camera.frameRate) { _ in camera.reconfigure() }
        }
    }

    private var cameraSurface: some View {
        ZStack {
            CameraPreview(controller: camera)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .clipped()

            VStack {
                HStack(spacing: 8) {
                    badge(camera.captureMode.title)
                    badge(camera.resolution.rawValue)
                    badge("(Int(camera.frameRate)) FPS")
                    Spacer()
                    badge(String(format: "%.1fx", camera.zoomFactor))
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                CameraTeleprompterOverlayView(controller: teleprompter)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                    .padding(.top, 18)

                Spacer()

                if camera.isRecording {
                    Text("● REC  (formatDuration(camera.recordingSeconds))")
                        .font(.system(.headline, design: .monospaced).bold())
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var controlsPanel: some View {
        ScrollView {
            VStack(spacing: 14) {
                modeSelector

                HStack {
                    Picker("Resolution", selection: $camera.resolution) {
                        ForEach(CameraResolution.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("FPS", selection: $camera.frameRate) {
                        Text("30").tag(30.0)
                        Text("60").tag(60.0)
                    }
                    .pickerStyle(.segmented)
                }

                if camera.captureMode == .cinematic && camera.cinematicAvailable {
                    controlSlider(
                        title: "Background Blur",
                        valueText: String(format: "f/%.1f", camera.simulatedAperture),
                        value: Binding(
                            get: { Double(camera.simulatedAperture) },
                            set: { camera.setAperture(Float($0)) }
                        ),
                        range: Double(camera.minSimulatedAperture)...Double(max(camera.maxSimulatedAperture, camera.minSimulatedAperture + 0.1))
                    )
                    .disabled(camera.isRecording)
                }

                controlSlider(
                    title: "Zoom",
                    valueText: String(format: "%.1fx", camera.zoomFactor),
                    value: Binding(
                        get: { Double(camera.zoomFactor) },
                        set: { camera.setZoom(CGFloat($0)) }
                    ),
                    range: Double(camera.minZoomFactor)...Double(max(camera.maxZoomFactor, camera.minZoomFactor + 0.1))
                )

                controlSlider(
                    title: "Exposure",
                    valueText: String(format: "%+.1f EV", camera.exposureBias),
                    value: Binding(
                        get: { Double(camera.exposureBias) },
                        set: { camera.setExposureBias(Float($0)) }
                    ),
                    range: Double(camera.minExposureBias)...Double(max(camera.maxExposureBias, camera.minExposureBias + 0.1))
                )

                HStack(spacing: 10) {
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

                HStack(spacing: 10) {
                    Button {
                        teleprompter.autoSpeed = max(0.5, teleprompter.autoSpeed - 0.1)
                    } label: {
                        Label("Speed −", systemImage: "minus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        camera.toggleFocusExposureLock()
                    } label: {
                        Label(
                            camera.focusExposureLocked ? "AE/AF LOCK" : "Lock Focus",
                            systemImage: camera.focusExposureLocked ? "lock.fill" : "lock.open"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        teleprompter.autoSpeed = min(2.5, teleprompter.autoSpeed + 0.1)
                    } label: {
                        Label("Speed +", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    camera.toggleRecording()
                } label: {
                    HStack {
                        Circle()
                            .fill(camera.isRecording ? Color.white : Color.red)
                            .frame(width: 22, height: 22)
                        Text(camera.isRecording ? "STOP RECORDING" : "REC")
                            .font(.headline.bold())
                    }
                    .foregroundStyle(camera.isRecording ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(camera.isRecording ? Color.red : Color.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                }

                Text(camera.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("แตะบนภาพเพื่อ Focus/Track จุดนั้น • Teleprompter เป็น Overlay เท่านั้นและไม่ถูกบันทึกลงไฟล์วิดีโอ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var modeSelector: some View {
        HStack(spacing: 7) {
            ForEach(CameraCaptureMode.allCases) { mode in
                Button(mode.title) {
                    camera.selectMode(mode)
                }
                .buttonStyle(.borderedProminent)
                .tint(camera.captureMode == mode ? Color.accentColor : Color.gray)
                .disabled(!camera.supportsMode(mode))
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.65), in: Capsule())
    }

    private func controlSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func syncSpeech() {
        let shouldListen = teleprompter.isRunning && teleprompter.mode != .auto
        if shouldListen {
            camera.startSpeech()
        } else {
            camera.stopSpeech()
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct ContentView: View {
    @StateObject private var teleprompter = PiPController()
    @StateObject private var camera = CameraController()

    var body: some View {
        TabView {
            CameraStudioView(camera: camera, teleprompter: teleprompter)
                .tabItem {
                    Label("Camera", systemImage: "video.fill")
                }

            TeleprompterSetupView(teleprompter: teleprompter)
                .tabItem {
                    Label("Script", systemImage: "text.alignleft")
                }
        }
    }
}
