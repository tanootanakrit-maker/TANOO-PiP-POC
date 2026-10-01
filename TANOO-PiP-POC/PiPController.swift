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
        let now = CACurrentMediaTime()
        lastTick = now
        segmentStartTime = now - progress * currentLineDuration()
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

    func resetPosition() {
        currentIndex = 0
        progress = 0
        segmentStartTime = CACurrentMediaTime()
        lastMatchedTranscript = ""
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
                self.segmentStartTime = CACurrentMediaTime() - self.progress * self.currentLineDuration()
            }
            .store(in: &settingsCancellables)

        $voiceSensitivity
            .dropFirst()
            .sink { defaults.set($0, forKey: CurrentSettingKey.voiceSensitivity) }
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

    private func currentLineDuration() -> Double {
        // Every script line — including an intentionally blank line — uses
        // exactly the same duration. This removes speed changes caused by text length.
        max(0.65, 3.4 / max(autoSpeed, 0.1))
    }

    private func tick() {
        let now = CACurrentMediaTime()
        lastTick = now

        if isRunning && !segments.isEmpty {
            let current = segments[min(currentIndex, segments.count - 1)]
            let isBlankLine = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let shouldAutoAdvance = mode == .auto || mode == .hybrid || isBlankLine

            if shouldAutoAdvance {
                let duration = currentLineDuration()
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

    private func handleTranscript(_ transcript: String) {
        guard isRunning, mode != .auto, currentIndex < segments.count else { return }

        speechStatus = "ได้ยิน: \(transcript.suffix(60))"

        let normalizedTranscript = normalizeForMatching(transcript)
        guard !normalizedTranscript.isEmpty else { return }

        // Voice mode is intentionally tolerant. Thai speech recognition can
        // insert/remove spaces or slightly alter a few characters, so matching
        // only the beginning of a sentence was too strict.
        let searchEnd = min(currentIndex + 3, segments.count - 1)

        for index in currentIndex...searchEnd {
            let target = normalizeForMatching(segments[index])

            if target.isEmpty {
                continue
            }

            if voiceMatchScore(transcript: normalizedTranscript, target: target) >= voiceSensitivity {
                lastMatchedTranscript = normalizedTranscript

                // Jump to the segment after the best matched line. This lets
                // Voice recover even if recognition lagged behind by one line.
                currentIndex = min(index + 1, segments.count - 1)
                progress = 0

                if index >= segments.count - 1 {
                    isRunning = false
                    speechStatus = "จบสคริปต์"
                } else {
                    statusText = mode == .hybrid
                        ? "Hybrid: Voice จับตำแหน่งสคริปต์แล้ว"
                        : "Voice: ตามคำพูดแล้ว"
                }

                renderViews()
                return
            }
        }
    }

    private func voiceMatchScore(transcript: String, target: String) -> Double {
        guard !target.isEmpty else { return 0 }

        if transcript.contains(target) {
            return 1.0
        }

        let anchorLength = min(max(4, target.count / 5), 8)
        guard target.count >= anchorLength else {
            return transcript.contains(target) ? 1.0 : 0.0
        }

        let chars = Array(target)
        let starts = [
            0,
            max(0, chars.count / 4),
            max(0, chars.count / 2),
            max(0, (chars.count * 3) / 4),
            max(0, chars.count - anchorLength)
        ]

        var matchedAnchors = 0
        var uniqueStarts = Set<Int>()

        for start in starts where uniqueStarts.insert(start).inserted {
            let end = min(chars.count, start + anchorLength)
            guard end > start else { continue }
            let anchor = String(chars[start..<end])
            if transcript.contains(anchor) {
                matchedAnchors += 1
            }
        }

        let denominator = max(1, uniqueStarts.count)
        return Double(matchedAnchors) / Double(denominator)
    }

    private func normalizeForMatching(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }
        return String(String.UnicodeScalarView(allowed))
    }

    private func advanceOneSegment(source: String) {
        guard !segments.isEmpty else { return }

        if currentIndex < segments.count - 1 {
            currentIndex += 1
            progress = 0
            segmentStartTime = CACurrentMediaTime()
            lastMatchedTranscript = ""
            if source == "voice" {
                statusText = mode == .hybrid ? "Hybrid: Voice ข้ามไปช่วงถัดไป" : "Voice: ไปช่วงถัดไป"
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
        } else {
            currentIndex = min(oldIndex, max(segments.count - 1, 0))
        }
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
                result.append(contentsOf: chunk(part, targetLength: targetLength))
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

        var chunks: [String] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let end = trimmed.index(index, offsetBy: targetLength, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            chunks.append(String(trimmed[index..<end]))
            index = end
        }
        return chunks
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
