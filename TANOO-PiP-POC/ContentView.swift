import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var pip = PiPController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text("TANOO PiP Proof of Concept")
                    .font(.title2.bold())

                VideoCallPiPSourcePreview(controller: pip)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(.secondary.opacity(0.35), lineWidth: 1)
                    }

                Text(pip.statusText)
                    .font(.subheadline)
                    .foregroundStyle(pip.isSupported ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)

                Button {
                    pip.togglePictureInPicture()
                } label: {
                    Label(
                        pip.isPictureInPictureActive ? "หยุด PiP" : "เปิด PiP",
                        systemImage: pip.isPictureInPictureActive ? "pip.exit" : "pip.enter"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!pip.isSupported || !pip.isControllerReady)

                VStack(alignment: .leading, spacing: 8) {
                    Text("วิธีทดสอบ")
                        .font(.headline)
                    Text("1. กด เปิด PiP\n2. ให้หน้าต่างลอยขึ้น\n3. เปิดแอป Camera ของ Apple\n4. ตรวจว่าข้อความ TANOO ยังอยู่ใน PiP\n5. รอบนี้จะไม่มีปุ่ม Play / 10 วินาทีแบบวิดีโอ")
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding()
            .navigationTitle("TANOO PiP Test")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct VideoCallPiPSourcePreview: UIViewRepresentable {
    let controller: PiPController

    func makeUIView(context: Context) -> TeleprompterVideoView {
        let view = TeleprompterVideoView()
        DispatchQueue.main.async {
            view.renderFrame()
            controller.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: TeleprompterVideoView, context: Context) {
        uiView.renderFrame()
    }
}
