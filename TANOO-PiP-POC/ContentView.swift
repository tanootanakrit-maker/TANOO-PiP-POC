import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct TeleprompterSetupView: View {
    @ObservedObject var teleprompter: PiPController
    var onOpenCamera: (() -> Void)? = nil
    @FocusState private var scriptEditorFocused: Bool
    @State private var showingProjects = false
    @State private var showingExporter = false
    @State private var exportDocument = TeleprompterTextDocument(text: "")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    projectCard
                    scriptCard
                    previewCard
                    runCard
                    appearanceCard
                    statusCard
                }
                .padding()
            }
            .navigationTitle("TANOO Teleprompter")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let onOpenCamera {
                        Button {
                            scriptEditorFocused = false
                            DispatchQueue.main.async {
                                onOpenCamera()
                            }
                        } label: {
                            Label("Camera", systemImage: "video.fill")
                        }
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Button("Camera") {
                        scriptEditorFocused = false
                        DispatchQueue.main.async {
                            onOpenCamera?()
                        }
                    }
                    Spacer()
                    Button("ปิดแป้นพิมพ์") {
                        scriptEditorFocused = false
                    }
                }
            }
            .sheet(isPresented: $showingProjects) {
                SavedProjectsView(controller: teleprompter)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .plainText,
                defaultFilename: teleprompter.safeExportFilename
            ) { result in
                teleprompter.exportStatus = result.isSuccess ? "ส่งออกไฟล์ .txt สำเร็จ" : "ยกเลิกการส่งออก"
            }
            .onChange(of: teleprompter.scriptText) { _ in
                teleprompter.scriptDidChange()
            }
            .onChange(of: teleprompter.mode) { _ in
                teleprompter.modeDidChange()
            }
        }
    }

    private var projectCard: some View {
        GroupBox {
            VStack(spacing: 12) {
                TextField("ชื่อโปรเจกต์", text: $teleprompter.projectName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button {
                        teleprompter.saveCurrentProject()
                    } label: {
                        Label("บันทึก", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingProjects = true
                    } label: {
                        Label("โหลด", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        exportDocument = TeleprompterTextDocument(text: teleprompter.scriptText)
                        showingExporter = true
                    } label: {
                        Label("Export .txt", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.subheadline)
            }
        } label: {
            Label("Project", systemImage: "doc.text")
        }
    }

    private var scriptCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $teleprompter.scriptText)
                    .focused($scriptEditorFocused)
                    .font(.body)
                    .frame(minHeight: 190)
                    .padding(6)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("ช่วงข้อความ \(min(teleprompter.currentIndex + 1, max(teleprompter.segmentCount, 1)))/\(max(teleprompter.segmentCount, 1))")
                    Spacer()
                    Button("ไปต้นสคริปต์") {
                        teleprompter.resetPosition()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } label: {
            Label("Script Editor", systemImage: "text.alignleft")
        }
    }

    private var previewCard: some View {
        GroupBox {
            VStack(spacing: 10) {
                TeleprompterPiPSourcePreview(controller: teleprompter)
                    .frame(height: 185)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.secondary.opacity(0.3), lineWidth: 1)
                    }

                Text("Preview นี้ใช้ renderer เดียวกับหน้าต่าง PiP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Preview", systemImage: "rectangle.inset.filled")
        }
    }

    private var runCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                Picker("โหมด", selection: $teleprompter.mode) {
                    ForEach(TeleprompterMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
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
                            teleprompter.isRunning ? "Pause" : "Start",
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

                Button {
                    teleprompter.togglePictureInPicture()
                } label: {
                    Label(
                        teleprompter.isPictureInPictureActive ? "หยุด PiP" : "เปิด Live PiP",
                        systemImage: teleprompter.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!teleprompter.isSupported || !teleprompter.isControllerReady)

                if teleprompter.mode != .auto {
                    Text(teleprompter.speechStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            Label("Run", systemImage: "play.rectangle")
        }
    }

    private var appearanceCard: some View {
        GroupBox {
            VStack(spacing: 14) {
                sliderRow(
                    title: "ขนาดตัวอักษร",
                    valueText: "\(Int(teleprompter.fontSize))",
                    value: $teleprompter.fontSize,
                    range: 12...68,
                    step: 1
                )

                sliderRow(
                    title: "ระยะบรรทัด",
                    valueText: "\(Int(teleprompter.lineSpacing))",
                    value: $teleprompter.lineSpacing,
                    range: 2...24,
                    step: 1
                )

                sliderRow(
                    title: "Auto Speed",
                    valueText: String(format: "%.1fx", teleprompter.autoSpeed),
                    value: $teleprompter.autoSpeed,
                    range: 0.5...2.5,
                    step: 0.1
                )

                if teleprompter.mode != .auto {
                    sliderRow(
                        title: "Voice Sensitivity",
                        valueText: "\(Int(teleprompter.voiceSensitivity * 100))%",
                        value: $teleprompter.voiceSensitivity,
                        range: 0.35...0.85,
                        step: 0.05
                    )
                }

                sliderRow(
                    title: "ตำแหน่งแนวตั้ง",
                    valueText: "\(Int(teleprompter.verticalPosition * 100))%",
                    value: $teleprompter.verticalPosition,
                    range: 0.08...0.55,
                    step: 0.01
                )

                sliderRow(
                    title: "ความทึบพื้นหลัง",
                    valueText: "\(Int(teleprompter.backgroundOpacity * 100))%",
                    value: $teleprompter.backgroundOpacity,
                    range: 0.0...1.0,
                    step: 0.05
                )

                Text("พื้นหลัง 0% = จางที่สุด • 100% = เข้มที่สุด")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("การจัดข้อความ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Alignment", selection: $teleprompter.textAlignment) {
                        ForEach(PromptAlignment.allCases) { alignment in
                            Text(alignment.title).tag(alignment)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("สีข้อความ")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("สีข้อความ", selection: $teleprompter.textColorStyle) {
                        ForEach(PromptTextColor.allCases) { color in
                            Text(color.title).tag(color)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        } label: {
            Label("Appearance", systemImage: "slider.horizontal.3")
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(teleprompter.statusText)
                    .font(.subheadline)
                if !teleprompter.exportStatus.isEmpty {
                    Text(teleprompter.exportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Hybrid: Auto ทำงานเป็นฐาน และ Voice จะข้ามไปช่วงถัดไปทันทีเมื่อตรวจพบว่าพูดถึงช่วงปัจจุบันแล้ว หาก Camera ใช้ไมโครโฟนจน Voice หยุด Auto จะยังทำงานต่อ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("สถานะ", systemImage: "info.circle")
        }
    }

    private func sliderRow(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range, step: step)
        }
    }

    private func sliderRow(
        title: String,
        valueText: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            Slider(value: value, in: range, step: step)
        }
    }
}

private struct TeleprompterPiPSourcePreview: UIViewRepresentable {
    let controller: PiPController

    func makeUIView(context: Context) -> TeleprompterVideoView {
        let view = TeleprompterVideoView()
        DispatchQueue.main.async {
            controller.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: TeleprompterVideoView, context: Context) {
        uiView.render(snapshot: controller.snapshot())
    }
}

private struct SavedProjectsView: View {
    @ObservedObject var controller: PiPController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if controller.savedProjects.isEmpty {
                    Text("ยังไม่มีโปรเจกต์ที่บันทึก")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.savedProjects) { project in
                        Button {
                            controller.loadProject(project.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                    .foregroundStyle(.primary)
                                Text(project.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        controller.deleteProjects(at: indexSet)
                    }
                }
            }
            .navigationTitle("Saved Projects")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("ปิด") { dismiss() }
                }
            }
        }
    }
}

struct TeleprompterTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = value
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
