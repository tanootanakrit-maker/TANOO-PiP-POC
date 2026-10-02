import Foundation
import Combine
import QuartzCore
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Speech
import UIKit

enum TeleprompterMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case voice
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .voice: return "Voice"
        case .hybrid: return "Hybrid"
        }
    }
}

enum VoiceFocusLevel: String, Codable, CaseIterable, Identifiable {
    case low
    case normal
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "ต่ำ"
        case .normal: return "ปกติ"
        case .high: return "สูง"
        }
    }

    // Fixed recognition profiles. They never depend on the number of words spoken.
    var matchThreshold: Double {
        switch self {
        case .low: return 0.38
        case .normal: return 0.58
        case .high: return 0.78
        }
    }

    var anchorLength: Int {
        switch self {
        case .low: return 4
        case .normal: return 5
        case .high: return 6
        }
    }

    var maxLookAhead: Int {
        switch self {
        case .low: return 2
        case .normal: return 2
        case .high: return 1
        }
    }

    var lookAheadExtraThreshold: Double {
        switch self {
        case .low: return 0.10
        case .normal: return 0.12
        case .high: return 0.10
        }
    }
}

enum PromptAlignment: String, Codable, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "ซ้าย"
        case .center: return "กลาง"
        case .right: return "ขวา"
        }
    }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}

enum PromptTextColor: String, Codable, CaseIterable, Identifiable {
    case white
    case cream
    case gold
    case green

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "ขาว"
        case .cream: return "ครีม"
        case .gold: return "ทอง"
        case .green: return "เขียว"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .white:
            return .white
        case .cream:
            return UIColor(red: 1.0, green: 0.96, blue: 0.84, alpha: 1)
        case .gold:
            return UIColor(red: 0.95, green: 0.78, blue: 0.36, alpha: 1)
        case .green:
            return UIColor(red: 0.70, green: 0.82, blue: 0.63, alpha: 1)
        }
    }
}

struct SavedProject: Codable, Identifiable {
    let id: UUID
    var name: String
    var script: String
    var mode: TeleprompterMode
    var fontSize: Double
    var lineSpacing: Double
    var autoSpeed: Double
    var verticalPosition: Double
    var backgroundOpacity: Double
    var textAlignment: PromptAlignment
    var textColorStyle: PromptTextColor
    var voiceSensitivity: Double?
    var voiceFocusLevel: VoiceFocusLevel?
    var updatedAt: Date
}

struct TeleprompterSnapshot {
    var segments: [String]
    var currentIndex: Int
    var progress: Double
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var verticalPosition: Double
    var backgroundOpacity: Double
    var alignment: PromptAlignment
    var textColor: PromptTextColor
    var isRunning: Bool
}

@MainActor
final class PiPController: NSObject, ObservableObject {
    @Published var projectName = "TANOO Script"
    @Published var scriptText = """
    สวัสดีครับ นี่คือ TANOO Teleprompter

    ข้อความจะเลื่อนไปทีละช่วงอย่างต่อเนื่อง
    คุณสามารถเลือก Auto, Voice หรือ Hybrid ได้

    เมื่อพร้อม ให้เปิด Live PiP แล้วสลับไปที่แอป Camera ของ Apple
    """
    @Published var mode: TeleprompterMode = .auto
    @Published var fontSize: CGFloat = 44
    @Published var lineSpacing: CGFloat = 10
    @Published var autoSpeed: Double = 1.0
    @Published var voiceSensitivity: Double = 0.40
    @Published var voiceFocusLevel: VoiceFocusLevel = .normal
    @Published var verticalPosition: Double = 0.18
    @Published var backgroundOpacity: Double = 0.78
    @Published var textAlignment: PromptAlignment = .center
    @Published var textColorStyle: PromptTextColor = .cream

    @Published private(set) var currentIndex = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var isControllerReady = false
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var statusText = "กำลังเตรียม Live PiP…"
    @Published private(set) var speechStatus = "Voice ยังไม่เริ่ม"
    @Published private(set) var savedProjects: [SavedProject] = []
    @Published var exportStatus = ""

    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    private var segments: [String] = []
    private var progress: Double = 0
    private var lastTick = CACurrentMediaTime()
    private var segmentStartTime = CACurrentMediaTime()
    private var settingsCancellables = Set<AnyCancellable>()

    private weak var sourceView: TeleprompterVideoView?
    private weak var cameraOverlayView: TeleprompterVideoView?
    private var pipContentView: TeleprompterVideoView?
    private var pipVideoCallViewController: AVPictureInPictureVideoCallViewController?
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var engineTimer: Timer?

    private let speechTracker = SpeechTracker()
    private var lastMatchedTranscript = ""
    private var usesExternalSpeech = false
    private var voiceConsumedCharacters = 0
    private var lastVoiceAdvanceAt: CFTimeInterval = 0

    private let projectsKey = "TANOO.savedProjects.v1"

    override init() {
        super.init()
        loadCurrentSettings()
        rebuildSegments(reset: true)
        loadSavedProjects()
        observeCurrentSettings()
        startEngineTimer()
    }

    var segmentCount: Int { segments.count }

    var safeExportFilename: String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let parts = projectName.components(separatedBy: invalid)
        let cleaned = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "TANOO-Script" : cleaned
    }

    func snapshot() -> TeleprompterSnapshot {
        TeleprompterSnapshot(
            segments: segments,
            currentIndex: currentIndex,
            progress: progress,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            verticalPosition: verticalPosition,
            backgroundOpacity: backgroundOpacity,
            alignment: textAlignment,
            textColor: textColorStyle,
            isRunning: isRunning
        )
    }

    func attach(to sourceView: TeleprompterVideoView) {
        guard self.sourceView !== sourceView else { return }
        self.sourceView = sourceView
        sourceView.render(snapshot: snapshot())

        guard isSupported else {
            statusText = "อุปกรณ์นี้ไม่รองรับ Picture in Picture"
            isControllerReady = false
            return
        }

        preparePlaybackAudioSession()

        let pipView = TeleprompterVideoView()
        pipView.translatesAutoresizingMaskIntoConstraints = false
        pipView.render(snapshot: snapshot())

        let videoCallVC = AVPictureInPictureVideoCallViewController()
        videoCallVC.preferredContentSize = CGSize(width: 960, height: 420)
        videoCallVC.view.backgroundColor = .clear
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
                    ? "พร้อมใช้งาน — เปิด Live PiP ได้"
                    : "PiP Controller พร้อมแล้ว กำลังรอระบบอนุญาต…"
            }
        }

        renderViews()
    }

    func attachCameraOverlay(_ view: TeleprompterVideoView) {
        cameraOverlayView = view
        view.render(snapshot: snapshot())
    }

    func setUsesExternalSpeech(_ enabled: Bool) {
        usesExternalSpeech = enabled
        if enabled {
            speechTracker.stop()
            if mode != .auto {
                speechStatus = "Voice ใช้เสียงจาก TANOO Camera"
            }
        } else if isRunning {
            configureSpeechForCurrentMode()
        }
    }

    func receiveExternalTranscript(_ transcript: String) {
        guard usesExternalSpeech else { return }
        handleTranscript(transcript)
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

        renderViews()

        guard controller.isPictureInPicturePossible else {
            statusText = "PiP ยังไม่พร้อม ลองรอ 1–2 วินาทีแล้วกดอีกครั้ง"
            return
        }

        controller.startPictureInPicture()
    }

    func scriptDidChange() {
        rebuildSegments(reset: false)
        renderViews()
    }

    func modeDidChange() {
        if isRunning {
            configureSpeechForCurrentMode()
        } else {
            speechTracker.stop()
            speechStatus = mode == .auto ? "Auto ไม่ใช้ไมโครโฟน" : "Voice พร้อมเมื่อกด Start"
        }
    }

    func toggleRunning() {
        isRunning ? pause() : start()
    }

    func start() {
        guard !segments.isEmpty else {
            statusText = "กรุณาใส่สคริปต์ก่อน"
            return
        }
        isRunning = true
        voiceConsumedCharacters = 0
        lastVoiceAdvanceAt = 0
        let now = CACurrentMediaTime()
        lastTick = now
        segmentStartTime = now - progress * currentLineDuration(for: segments.indices.contains(currentIndex) ? segments[currentIndex] : "")
        configureSpeechForCurrentMode()
        statusText = "กำลังทำงาน: \(mode.title)"
        renderViews()
    }

    func pause() {
        isRunning = false
        speechTracker.stop()
        speechStatus = "หยุด Voice แล้ว"
        if !usesExternalSpeech {
            preparePlaybackAudioSession()
        }
        statusText = "Pause"
        renderViews()
    }

    func previous() {
        currentIndex = max(0, currentIndex - 1)
        progress = 0
        segmentStartTime = CACurrentMediaTime()
        lastMatchedTranscript = ""
        renderViews()
    }

    func next() {
        advanceOneSegment(source: "manual")
    }

    struct RecordingCheckpoint {
        let index: Int
        let fraction: Double
    }

    func recordingCheckpoint() -> RecordingCheckpoint {
        RecordingCheckpoint(index: currentIndex, fraction: progress)
    }

    func restoreRecordingCheckpoint(_ checkpoint: RecordingCheckpoint) {
        pause()
        currentIndex = min(max(0, checkpoint.index), max(0, segments.count - 1))
        progress = min(max(0, checkpoint.fraction), 0.999)
        let now = CACurrentMediaTime()
        lastTick = now
        let line = segments.indices.contains(currentIndex) ? segments[currentIndex] : ""
        segmentStartTime = now - progress * currentLineDuration(for: line)
        lastMatchedTranscript = ""
        voiceConsumedCharacters = 0
        lastVoiceAdvanceAt = 0
        speechStatus = "ย้อนกลับจุดเริ่มช็อตแล้ว"
        renderViews()
    }

    func resetPosition() {
        currentIndex = 0
        progress = 0
        segmentStartTime = CACurrentMediaTime()
        lastMatchedTranscript = ""
        voiceConsumedCharacters = 0
        lastVoiceAdvanceAt = 0
        renderViews()
    }

    func autoFormatScriptLines() {
        let normalized = scriptText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let targetLength = max(
            18,
            min(54, Int(34.0 * (44.0 / max(Double(fontSize), 12.0))))
        )

        let sourceLines = normalized.components(separatedBy: "\n")
        var output: [String] = []

        for sourceLine in sourceLines {
            let line = sourceLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                output.append("")
                continue
            }

            let sentences = Self.splitSentencesPreservingText(line)

            for sentence in sentences {
                output.append(
                    contentsOf: Self.wrapOnlyAtExistingSpaces(
                        sentence,
                        targetLength: targetLength
                    )
                )
            }
        }

        // Only whitespace/newlines are reorganized. Characters, words,
        // punctuation, numbers and spelling are never rewritten.
        scriptText = output.joined(separator: "\n")
        rebuildSegments(reset: true)
        exportStatus = "Auto แบ่งบรรทัดแล้ว — ไม่แก้คำในสคริปต์"
        renderViews()
    }

    func saveCurrentProject() {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "TANOO Script"
            : projectName.trimmingCharacters(in: .whitespacesAndNewlines)

        let project = SavedProject(
            id: UUID(),
            name: name,
            script: scriptText,
            mode: mode,
            fontSize: Double(fontSize),
            lineSpacing: Double(lineSpacing),
            autoSpeed: autoSpeed,
            verticalPosition: verticalPosition,
            backgroundOpacity: backgroundOpacity,
            textAlignment: textAlignment,
            textColorStyle: textColorStyle,
            voiceSensitivity: voiceSensitivity,
            voiceFocusLevel: voiceFocusLevel,
            updatedAt: Date()
        )

        if let index = savedProjects.firstIndex(where: { $0.name == name }) {
            var updated = project
            updated = SavedProject(
                id: savedProjects[index].id,
                name: project.name,
                script: project.script,
                mode: project.mode,
                fontSize: project.fontSize,
                lineSpacing: project.lineSpacing,
                autoSpeed: project.autoSpeed,
                verticalPosition: project.verticalPosition,
                backgroundOpacity: project.backgroundOpacity,
                textAlignment: project.textAlignment,
                textColorStyle: project.textColorStyle,
                voiceSensitivity: project.voiceSensitivity,
                voiceFocusLevel: project.voiceFocusLevel,
                updatedAt: project.updatedAt
            )
            savedProjects[index] = updated
        } else {
            savedProjects.insert(project, at: 0)
        }

        persistProjects()
        statusText = "บันทึกโปรเจกต์ “\(name)” แล้ว"
    }

    func loadProject(_ id: UUID) {
        guard let project = savedProjects.first(where: { $0.id == id }) else { return }
        projectName = project.name
        scriptText = project.script
        mode = project.mode
        fontSize = CGFloat(project.fontSize)
        lineSpacing = CGFloat(project.lineSpacing)
        autoSpeed = project.autoSpeed
        verticalPosition = project.verticalPosition
        backgroundOpacity = project.backgroundOpacity
        textAlignment = project.textAlignment
        textColorStyle = project.textColorStyle
        voiceSensitivity = project.voiceSensitivity ?? 0.40
        voiceFocusLevel = project.voiceFocusLevel ?? .normal
        rebuildSegments(reset: true)
        modeDidChange()
        statusText = "โหลดโปรเจกต์ “\(project.name)” แล้ว"
        renderViews()
    }

    func deleteProjects(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard savedProjects.indices.contains(index) else { continue }
            savedProjects.remove(at: index)
        }
        persistProjects()
    }

    private enum CurrentSettingKey {
        static let projectName = "TANOO.current.projectName"
        static let scriptText = "TANOO.current.scriptText"
        static let mode = "TANOO.current.mode"
        static let fontSize = "TANOO.current.fontSize"
        static let lineSpacing = "TANOO.current.lineSpacing"
        static let autoSpeed = "TANOO.current.autoSpeed"
        static let voiceSensitivity = "TANOO.current.voiceSensitivity"
        static let voiceFocusLevel = "TANOO.current.voiceFocusLevel"
        static let verticalPosition = "TANOO.current.verticalPosition"
        static let backgroundOpacity = "TANOO.current.backgroundOpacity"
        static let alignment = "TANOO.current.alignment"
        static let textColor = "TANOO.current.textColor"
    }

    private func loadCurrentSettings() {
        let defaults = UserDefaults.standard

        if let value = defaults.string(forKey: CurrentSettingKey.projectName), !value.isEmpty {
            projectName = value
        }
        if let value = defaults.string(forKey: CurrentSettingKey.scriptText) {
            scriptText = value
        }
        if let raw = defaults.string(forKey: CurrentSettingKey.mode),
           let value = TeleprompterMode(rawValue: raw) {
            mode = value
        }
        if defaults.object(forKey: CurrentSettingKey.fontSize) != nil {
            fontSize = CGFloat(defaults.double(forKey: CurrentSettingKey.fontSize))
        }
        if defaults.object(forKey: CurrentSettingKey.lineSpacing) != nil {
            lineSpacing = CGFloat(defaults.double(forKey: CurrentSettingKey.lineSpacing))
        }
        if defaults.object(forKey: CurrentSettingKey.autoSpeed) != nil {
            autoSpeed = defaults.double(forKey: CurrentSettingKey.autoSpeed)
        }
        if defaults.object(forKey: CurrentSettingKey.voiceSensitivity) != nil {
            voiceSensitivity = defaults.double(forKey: CurrentSettingKey.voiceSensitivity)
        }
        if let raw = defaults.string(forKey: CurrentSettingKey.voiceFocusLevel),
           let value = VoiceFocusLevel(rawValue: raw) {
            voiceFocusLevel = value
        }
        if defaults.object(forKey: CurrentSettingKey.verticalPosition) != nil {
            verticalPosition = defaults.double(forKey: CurrentSettingKey.verticalPosition)
        }
        if defaults.object(forKey: CurrentSettingKey.backgroundOpacity) != nil {
            backgroundOpacity = defaults.double(forKey: CurrentSettingKey.backgroundOpacity)
        }
        if let raw = defaults.string(forKey: CurrentSettingKey.alignment),
           let value = PromptAlignment(rawValue: raw) {
            textAlignment = value
        }
        if let raw = defaults.string(forKey: CurrentSettingKey.textColor),
           let value = PromptTextColor(rawValue: raw) {
            textColorStyle = value
        }
    }

    private func observeCurrentSettings() {
        let defaults = UserDefaults.standard

        $projectName
            .dropFirst()
            .sink { defaults.set($0, forKey: CurrentSettingKey.projectName) }
            .store(in: &settingsCancellables)

        $scriptText
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] value in
                defaults.set(value, forKey: CurrentSettingKey.scriptText)
                self?.rebuildSegments(reset: false)
                self?.renderViews()
            }
            .store(in: &settingsCancellables)

        $mode
            .dropFirst()
            .sink { defaults.set($0.rawValue, forKey: CurrentSettingKey.mode) }
            .store(in: &settingsCancellables)

        $fontSize
            .dropFirst()
            .sink { [weak self] value in
                defaults.set(Double(value), forKey: CurrentSettingKey.fontSize)
                self?.rebuildSegments(reset: false)
                self?.progress = 0
                self?.segmentStartTime = CACurrentMediaTime()
                self?.renderViews()
            }
            .store(in: &settingsCancellables)

        $lineSpacing
            .dropFirst()
            .sink { [weak self] value in
                defaults.set(Double(value), forKey: CurrentSettingKey.lineSpacing)
                self?.renderViews()
            }
            .store(in: &settingsCancellables)

        $autoSpeed
            .dropFirst()
            .sink { [weak self] value in
                defaults.set(value, forKey: CurrentSettingKey.autoSpeed)
                guard let self else { return }
                let current = self.segments.indices.contains(self.currentIndex) ? self.segments[self.currentIndex] : ""
                self.segmentStartTime = CACurrentMediaTime() - self.progress * self.currentLineDuration(for: current)
            }
            .store(in: &settingsCancellables)

        $voiceSensitivity
            .dropFirst()
            .sink { defaults.set($0, forKey: CurrentSettingKey.voiceSensitivity) }
            .store(in: &settingsCancellables)

        $voiceFocusLevel
            .dropFirst()
            .sink { defaults.set($0.rawValue, forKey: CurrentSettingKey.voiceFocusLevel) }
            .store(in: &settingsCancellables)

        $verticalPosition
            .dropFirst()
            .sink { [weak self] value in
                defaults.set(value, forKey: CurrentSettingKey.verticalPosition)
                self?.renderViews()
            }
            .store(in: &settingsCancellables)

        $backgroundOpacity
            .dropFirst()
            .sink { [weak self] value in
                defaults.set(value, forKey: CurrentSettingKey.backgroundOpacity)
                self?.renderViews()
            }
            .store(in: &settingsCancellables)

        $textAlignment
            .dropFirst()
            .sink { [weak self] value in
                defaults.set(value.rawValue, forKey: CurrentSettingKey.alignment)
                self?.renderViews()
            }
            .store(in: &settingsCancellables)

        $textColorStyle
            .dropFirst()
            .sink { [weak self] value in
                defaults.set(value.rawValue, forKey: CurrentSettingKey.textColor)
                self?.renderViews()
            }
            .store(in: &settingsCancellables)
    }

    private func loadSavedProjects() {
        guard let data = UserDefaults.standard.data(forKey: projectsKey),
              let projects = try? JSONDecoder().decode([SavedProject].self, from: data) else {
            return
        }
        savedProjects = projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persistProjects() {
        guard let data = try? JSONEncoder().encode(savedProjects) else { return }
        UserDefaults.standard.set(data, forKey: projectsKey)
    }

    private func startEngineTimer() {
        engineTimer?.invalidate()
        engineTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        if let engineTimer {
            RunLoop.main.add(engineTimer, forMode: .common)
        }
    }

    private func currentLineDuration(for segment: String? = nil) -> Double {
        let normal = max(0.65, 3.4 / max(autoSpeed, 0.1))
        let isBlank = (segment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // In Auto, blank lines keep exactly the same pacing as text lines.
        // In Voice/Hybrid, once Voice reaches an intentional blank line,
        // glide through it quickly but smoothly to bring the next spoken line to EyeLine.
        if isBlank && mode != .auto {
            return max(0.45, min(0.85, normal * 0.24))
        }

        return normal
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lastTick = now

        if isRunning && !segments.isEmpty {
            let current = segments[min(currentIndex, segments.count - 1)]
            let isBlankLine = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let shouldAutoAdvance = mode == .auto || mode == .hybrid || isBlankLine

            if shouldAutoAdvance {
                let duration = currentLineDuration(for: current)
                var elapsed = max(0, now - segmentStartTime)

                while elapsed >= duration {
                    if currentIndex < segments.count - 1 {
                        currentIndex += 1
                        lastMatchedTranscript = ""
                        segmentStartTime += duration
                        elapsed = max(0, now - segmentStartTime)
                    } else {
                        progress = 0
                        isRunning = false
                        speechTracker.stop()
                        statusText = "จบสคริปต์"
                        break
                    }
                }

                if isRunning {
                    progress = min(max(elapsed / duration, 0), 0.999)
                }
            } else {
                progress = 0
                segmentStartTime = now
            }
        }

        if isPictureInPictureActive || isRunning {
            renderViews()
        }
    }

    private func configureSpeechForCurrentMode() {
        if mode == .auto {
            speechTracker.stop()
            speechStatus = "Auto ไม่ใช้ไมโครโฟน"
            // When TANOO Camera is active, never switch the shared
            // AVAudioSession back to playback: the camera needs recording audio.
            if !usesExternalSpeech {
                preparePlaybackAudioSession()
            }
            return
        }

        if usesExternalSpeech {
            speechTracker.stop()
            speechStatus = "Voice ใช้ไมโครโฟนจาก TANOO Camera"
            return
        }

        speechStatus = "กำลังขอสิทธิ์ Voice…"

        speechTracker.start(
            onStatus: { [weak self] message in
                Task { @MainActor in
                    self?.speechStatus = message
                }
            },
            onTranscript: { [weak self] transcript in
                Task { @MainActor in
                    self?.handleTranscript(transcript)
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.speechStatus = message
                    if self.mode == .hybrid {
                        self.statusText = "Voice ใช้ไม่ได้ชั่วคราว — Hybrid ทำ Auto ต่อ"
                        self.preparePlaybackAudioSession()
                    } else {
                        self.statusText = "Voice หยุด: \(message)"
                    }
                }
            }
        )
    }

    private struct VoiceMatchResult {
        let score: Double
        let startOffset: Int
        let endOffset: Int
    }

    private func handleTranscript(_ transcript: String) {
        guard isRunning, mode != .auto, currentIndex < segments.count else { return }

        speechStatus = "ได้ยิน: \(transcript.suffix(60))"

        let normalizedTranscript = normalizeForMatching(transcript)
        guard !normalizedTranscript.isEmpty else { return }

        // Speech partial results are cumulative and can be revised.
        if normalizedTranscript.count < voiceConsumedCharacters {
            voiceConsumedCharacters = 0
        }

        var consumed = min(voiceConsumedCharacters, normalizedTranscript.count)
        var advancesThisResult = 0
        let maxAdvancesPerResult = 3
        let now = CACurrentMediaTime()

        while currentIndex < segments.count,
              advancesThisResult < maxAdvancesPerResult {
            let currentRaw = segments[currentIndex]
            let currentTarget = normalizeForMatching(currentRaw)

            // Intentional blank lines are animated by the fast smooth blank timer.
            if currentTarget.isEmpty {
                break
            }

            let startIndex = normalizedTranscript.index(
                normalizedTranscript.startIndex,
                offsetBy: consumed
            )
            var fresh = String(normalizedTranscript[startIndex...])

            // Bound fuzzy work without losing recent speech.
            if fresh.count > 260 {
                fresh = String(fresh.suffix(260))
                consumed = max(0, normalizedTranscript.count - fresh.count)
            }

            guard !fresh.isEmpty else { break }

            let currentMatch = bestVoiceMatch(
                transcript: fresh,
                target: currentTarget
            )

            if currentMatch.score >= voiceFocusLevel.matchThreshold,
               now - lastVoiceAdvanceAt >= 0.35 {
                consumed += currentMatch.endOffset
                voiceConsumedCharacters = min(consumed, normalizedTranscript.count)
                lastMatchedTranscript = normalizedTranscript
                lastVoiceAdvanceAt = now

                advanceOneSegment(source: "voice")
                advancesThisResult += 1
                continue
            }

            // If the speaker is faster than the displayed script, allow
            // catching up to a clearly recognized NEXT line. This is stricter
            // than current-line matching and never performs an unverified jump.
            var catchUp: (index: Int, match: VoiceMatchResult)?

            if voiceFocusLevel.maxLookAhead > 0 {
                let lastIndex = min(
                    segments.count - 1,
                    currentIndex + voiceFocusLevel.maxLookAhead
                )

                if currentIndex < lastIndex {
                    for index in (currentIndex + 1)...lastIndex {
                        let candidateTarget = normalizeForMatching(segments[index])
                        if candidateTarget.isEmpty { continue }

                        let candidate = bestVoiceMatch(
                            transcript: fresh,
                            target: candidateTarget
                        )

                        let distance = index - currentIndex
                        let required = min(
                            0.96,
                            voiceFocusLevel.matchThreshold
                                + voiceFocusLevel.lookAheadExtraThreshold
                                + Double(max(0, distance - 1)) * 0.04
                        )

                        if candidate.score >= required,
                           candidate.score >= currentMatch.score + 0.12 {
                            if catchUp == nil || candidate.score > catchUp!.match.score {
                                catchUp = (index, candidate)
                            }
                        }
                    }
                }
            }

            guard let catchUp,
                  now - lastVoiceAdvanceAt >= 0.35 else {
                break
            }

            consumed += catchUp.match.endOffset
            voiceConsumedCharacters = min(consumed, normalizedTranscript.count)
            lastMatchedTranscript = normalizedTranscript
            lastVoiceAdvanceAt = now

            // The recognized line was already spoken, so move EyeLine to
            // the line immediately after it. This is deliberate catch-up.
            currentIndex = min(catchUp.index + 1, segments.count - 1)
            progress = 0
            segmentStartTime = CACurrentMediaTime()
            statusText = "Voice: ตามคำพูดที่เร็วกว่า Script แล้ว"
            renderViews()

            advancesThisResult += 1
            break
        }
    }

    private func bestVoiceMatch(
        transcript: String,
        target: String
    ) -> VoiceMatchResult {
        guard !transcript.isEmpty, !target.isEmpty else {
            return VoiceMatchResult(score: 0, startOffset: 0, endOffset: 0)
        }

        if let range = transcript.range(of: target) {
            return VoiceMatchResult(
                score: 1,
                startOffset: transcript.distance(
                    from: transcript.startIndex,
                    to: range.lowerBound
                ),
                endOffset: transcript.distance(
                    from: transcript.startIndex,
                    to: range.upperBound
                )
            )
        }

        let source = Array(transcript)
        let targetChars = Array(target)
        let targetCount = targetChars.count

        guard targetCount >= 2 else {
            return VoiceMatchResult(score: transcript.contains(target) ? 1 : 0, startOffset: 0, endOffset: transcript.count)
        }

        let minimumWindow = max(2, Int(Double(targetCount) * 0.62))
        let maximumWindow = min(
            source.count,
            max(minimumWindow, Int(Double(targetCount) * 1.42) + 4)
        )

        guard source.count >= minimumWindow else {
            let score = fuzzySimilarity(
                Array(source),
                targetChars
            )
            return VoiceMatchResult(
                score: score,
                startOffset: 0,
                endOffset: source.count
            )
        }

        var best = VoiceMatchResult(score: 0, startOffset: 0, endOffset: 0)

        for windowLength in minimumWindow...maximumWindow {
            let maxStart = source.count - windowLength
            if maxStart < 0 { continue }

            for start in 0...maxStart {
                let end = start + windowLength
                let window = Array(source[start..<end])
                let score = fuzzySimilarity(window, targetChars)

                if score > best.score {
                    best = VoiceMatchResult(
                        score: score,
                        startOffset: start,
                        endOffset: end
                    )
                }
            }
        }

        return best
    }

    private func fuzzySimilarity(
        _ source: [Character],
        _ target: [Character]
    ) -> Double {
        guard !source.isEmpty, !target.isEmpty else { return 0 }

        let lcs = longestCommonSubsequenceLength(source, target)
        let lcsCoverage = Double(lcs) / Double(target.count)

        let sourceBigrams = characterNGrams(source, size: 2)
        let targetBigrams = characterNGrams(target, size: 2)

        let bigramCoverage: Double
        if targetBigrams.isEmpty {
            bigramCoverage = lcsCoverage
        } else {
            bigramCoverage = Double(
                targetBigrams.intersection(sourceBigrams).count
            ) / Double(targetBigrams.count)
        }

        let lengthDifference = abs(source.count - target.count)
        let lengthPenalty = max(
            0.76,
            1.0 - Double(lengthDifference) / Double(max(source.count, target.count)) * 0.28
        )

        return min(
            1,
            (lcsCoverage * 0.64 + bigramCoverage * 0.36) * lengthPenalty
        )
    }

    private func longestCommonSubsequenceLength(
        _ a: [Character],
        _ b: [Character]
    ) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var previous = Array(repeating: 0, count: b.count + 1)

        for charA in a {
            var current = Array(repeating: 0, count: b.count + 1)

            for j in 1...b.count {
                if charA == b[j - 1] {
                    current[j] = previous[j - 1] + 1
                } else {
                    current[j] = max(previous[j], current[j - 1])
                }
            }

            previous = current
        }

        return previous[b.count]
    }

    private func characterNGrams(
        _ characters: [Character],
        size: Int
    ) -> Set<String> {
        guard size > 0, characters.count >= size else { return [] }

        var grams = Set<String>()
        for start in 0...(characters.count - size) {
            grams.insert(String(characters[start..<(start + size)]))
        }
        return grams
    }

    private func normalizeForMatching(_ text: String) -> String {
        let numberCanonical = canonicalizeNumbers(in: text.lowercased())
        let allowed = numberCanonical.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        return String(String.UnicodeScalarView(allowed))
    }

    private func canonicalizeNumbers(in text: String) -> String {
        let thaiDigits: [Character: Character] = [
            "๐": "0", "๑": "1", "๒": "2", "๓": "3", "๔": "4",
            "๕": "5", "๖": "6", "๗": "7", "๘": "8", "๙": "9"
        ]

        let digitNormalized = String(text.map { thaiDigits[$0] ?? $0 })
        let pattern = #"[0-9][0-9,]*(?:\.[0-9]+)?"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return digitNormalized
        }

        let ns = digitNormalized as NSString
        let matches = regex.matches(
            in: digitNormalized,
            range: NSRange(location: 0, length: ns.length)
        )

        var output = digitNormalized

        for match in matches.reversed() {
            let token = ns.substring(with: match.range)
            let replacement = thaiWordsForNumberToken(token)
            let range = Range(match.range, in: output)!

            output.replaceSubrange(range, with: replacement)
        }

        return output
    }

    private func thaiWordsForNumberToken(_ token: String) -> String {
        let clean = token.replacingOccurrences(of: ",", with: "")
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)

        guard let integer = Int(parts.first ?? "0") else {
            return token
        }

        var result = thaiIntegerWords(integer)

        if parts.count > 1 {
            let decimalDigits = String(parts[1])
            let digitWords = [
                "0": "ศูนย์", "1": "หนึ่ง", "2": "สอง", "3": "สาม", "4": "สี่",
                "5": "ห้า", "6": "หก", "7": "เจ็ด", "8": "แปด", "9": "เก้า"
            ]

            result += "จุด"
            for character in decimalDigits {
                result += digitWords[String(character)] ?? String(character)
            }
        }

        return result
    }

    private func thaiIntegerWords(_ value: Int) -> String {
        if value == 0 { return "ศูนย์" }
        if value < 0 { return "ลบ" + thaiIntegerWords(abs(value)) }

        if value >= 1_000_000 {
            let millions = value / 1_000_000
            let remainder = value % 1_000_000
            return thaiIntegerWords(millions)
                + "ล้าน"
                + (remainder == 0 ? "" : thaiIntegerWords(remainder))
        }

        let digits = [
            100_000: "แสน",
            10_000: "หมื่น",
            1_000: "พัน",
            100: "ร้อย"
        ]

        var remainder = value
        var result = ""

        for (place, unit) in digits.sorted(by: { $0.key > $1.key }) {
            let digit = remainder / place
            if digit > 0 {
                result += thaiDigitWord(digit)
                result += unit
                remainder %= place
            }
        }

        let tens = remainder / 10
        let ones = remainder % 10

        if tens > 0 {
            if tens == 1 {
                result += "สิบ"
            } else if tens == 2 {
                result += "ยี่สิบ"
            } else {
                result += thaiDigitWord(tens) + "สิบ"
            }
        }

        if ones > 0 {
            if ones == 1 && value > 10 {
                result += "เอ็ด"
            } else {
                result += thaiDigitWord(ones)
            }
        }

        return result
    }

    private func thaiDigitWord(_ value: Int) -> String {
        switch value {
        case 0: return "ศูนย์"
        case 1: return "หนึ่ง"
        case 2: return "สอง"
        case 3: return "สาม"
        case 4: return "สี่"
        case 5: return "ห้า"
        case 6: return "หก"
        case 7: return "เจ็ด"
        case 8: return "แปด"
        case 9: return "เก้า"
        default: return String(value)
        }
    }


    private func advanceOneSegment(source: String) {
        guard !segments.isEmpty else { return }

        if currentIndex < segments.count - 1 {
            currentIndex += 1
            progress = 0
            segmentStartTime = CACurrentMediaTime()
            lastMatchedTranscript = ""

            if source == "voice" {
                statusText = mode == .hybrid
                    ? "Hybrid: Voice จับบรรทัดถัดไป"
                    : "Voice: จับบรรทัดถัดไป"
            }
        } else {
            progress = 0
            segmentStartTime = CACurrentMediaTime()
            isRunning = false
            speechTracker.stop()
            statusText = "จบสคริปต์"
        }

        renderViews()
    }

    private func rebuildSegments(reset: Bool) {
        let oldIndex = currentIndex
        segments = segmentScript(scriptText)

        if reset {
            currentIndex = 0
            progress = 0
            segmentStartTime = CACurrentMediaTime()
        } else {
            currentIndex = min(oldIndex, max(segments.count - 1, 0))
        }
    }

    private static func splitSentencesPreservingText(_ text: String) -> [String] {
        var result: [String] = []
        var buffer = ""

        for character in text {
            buffer.append(character)

            if character == "." ||
               character == "!" ||
               character == "?" ||
               character == "。" ||
               character == "！" ||
               character == "？" {
                let sentence = buffer.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty {
                    result.append(sentence)
                }
                buffer = ""
            }
        }

        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            result.append(tail)
        }

        return result.isEmpty ? [text] : result
    }

    private static func wrapOnlyAtExistingSpaces(
        _ text: String,
        targetLength: Int
    ) -> [String] {
        let words = text.split(
            whereSeparator: { $0.isWhitespace }
        ).map(String.init)

        // Thai text often has no spaces between words. Never cut the text
        // arbitrarily because that could split a real word.
        guard words.count > 1 else {
            return [text.trimmingCharacters(in: .whitespaces)]
        }

        var result: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word

            if candidate.count > targetLength && !current.isEmpty {
                result.append(current)
                current = word
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            result.append(current)
        }

        return result
    }

    private func segmentScript(_ script: String) -> [String] {
        let normalized = script
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Important: each explicit empty line in the editor becomes an empty
        // teleprompter segment. This preserves the user's speaking rhythm.
        let lines = normalized.components(separatedBy: "\n")
        var result: [String] = []

        let targetLength = max(12, min(88, Int(30.0 * (44.0 / max(Double(fontSize), 12.0)))))

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.isEmpty {
                result.append("")
                continue
            }

            var sentenceBuffer = ""
            var sentenceParts: [String] = []

            for character in trimmedLine {
                sentenceBuffer.append(character)

                if character == "." || character == "!" || character == "?" ||
                    character == "。" || character == "！" || character == "？" {
                    let part = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty {
                        sentenceParts.append(part)
                    }
                    sentenceBuffer = ""
                }
            }

            let tail = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                sentenceParts.append(tail)
            }

            if sentenceParts.isEmpty {
                sentenceParts.append(trimmedLine)
            }

            for part in sentenceParts {
                result.append(contentsOf: Self.chunk(part, targetLength: targetLength))
            }
        }

        return result.isEmpty ? [""] : result
    }

    private static func chunk(_ text: String, targetLength: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > targetLength else { return trimmed.isEmpty ? [] : [trimmed] }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        if words.count > 1 {
            var chunks: [String] = []
            var current = ""

            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if candidate.count > targetLength && !current.isEmpty {
                    chunks.append(current)
                    current = word
                } else {
                    current = candidate
                }
            }

            if !current.isEmpty {
                chunks.append(current)
            }
            return chunks
        }

        // No safe whitespace boundary exists. Keep the wording intact and
        // let SwiftUI wrap it visually instead of cutting through Thai words.
        return [trimmed]
    }

    private func renderViews() {
        let state = snapshot()
        sourceView?.render(snapshot: state)
        cameraOverlayView?.render(snapshot: state)
        pipContentView?.render(snapshot: state)
    }

    private func preparePlaybackAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            statusText = "เตรียมระบบเสียงสำหรับ PiP ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }
}

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.renderViews()
            self.statusText = "กำลังเปิด Live PiP…"
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isPictureInPictureActive = true
            self.renderViews()
            self.statusText = "Live PiP ทำงานแล้ว — เปิด Camera ได้"
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
        backgroundColor = .clear
        isOpaque = false
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(snapshot: TeleprompterSnapshot) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        let width = 960
        let height = 420

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

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(UIColor.black.withAlphaComponent(snapshot.backgroundOpacity).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = snapshot.alignment.nsAlignment
        paragraph.lineSpacing = snapshot.lineSpacing

        let blockHeight = max(snapshot.fontSize * 1.75 + snapshot.lineSpacing, 72)
        let startY = CGFloat(height) * CGFloat(snapshot.verticalPosition) - CGFloat(snapshot.progress) * blockHeight

        let current = max(0, min(snapshot.currentIndex, snapshot.segments.count - 1))

        if !snapshot.segments.isEmpty {
            for offset in 0..<4 {
                let index = current + offset
                guard index < snapshot.segments.count else { break }

                let alpha: CGFloat = offset == 0 ? 1.0 : max(0.42, 0.78 - CGFloat(offset) * 0.12)
                let weight: UIFont.Weight = offset == 0 ? .semibold : .regular

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: snapshot.fontSize, weight: weight),
                    .foregroundColor: snapshot.textColor.uiColor.withAlphaComponent(alpha),
                    .paragraphStyle: paragraph
                ]

                let attributed = NSAttributedString(string: snapshot.segments[index], attributes: attributes)
                let y = startY + CGFloat(offset) * blockHeight

                attributed.draw(
                    with: CGRect(x: 48, y: y, width: CGFloat(width) - 96, height: blockHeight * 1.35),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            }
        }

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
            duration: CMTime(value: 1, timescale: 20),
            presentationTimeStamp: CMTime(value: frameCounter, timescale: 20),
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

final class SpeechTracker {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "th-TH"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func start(
        onStatus: @escaping (String) -> Void,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        stop()

        requestPermissions { [weak self] allowed, message in
            guard let self else { return }
            guard allowed else {
                onFailure(message)
                return
            }

            DispatchQueue.main.async {
                self.beginRecognition(
                    onStatus: onStatus,
                    onTranscript: onTranscript,
                    onFailure: onFailure
                )
            }
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func requestPermissions(completion: @escaping (Bool, String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                completion(false, "ไม่ได้รับสิทธิ์ Speech Recognition")
                return
            }

            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    completion(granted, granted ? "พร้อมใช้ไมโครโฟน" : "ไม่ได้รับสิทธิ์ไมโครโฟน")
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    completion(granted, granted ? "พร้อมใช้ไมโครโฟน" : "ไม่ได้รับสิทธิ์ไมโครโฟน")
                }
            }
        }
    }

    private func beginRecognition(
        onStatus: @escaping (String) -> Void,
        onTranscript: @escaping (String) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        guard let recognizer, recognizer.isAvailable else {
            onFailure("Speech Recognition ยังไม่พร้อม")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true

            audioEngine.prepare()
            try audioEngine.start()

            onStatus("Voice กำลังฟังภาษาไทย")

            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    onTranscript(result.bestTranscription.formattedString)
                }

                if let error {
                    onFailure("Voice หยุด: \(error.localizedDescription)")
                }
            }
        } catch {
            onFailure("เปิดไมโครโฟนไม่ได้: \(error.localizedDescription)")
        }
    }
}
