import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var pip = PiPController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Text("TANOO PiP Proof of Concept")
                    .font(.title2.bold())

                PiPPreview(controller: pip)
                    .frame(height: 220)
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
                .disabled(!pip.canStartPictureInPicture && !pip.isPictureInPictureActive)

                VStack(alignment: .leading, spacing: 8) {
                    Text("วิธีทดสอบ")
                        .font(.headline)
                    Text("1. กด เปิด PiP\n2. ให้หน้าต่างลอยขึ้น\n3. กด Home / ปัดออกจากแอป\n4. เปิดแอป Camera ของ Apple\n5. ดูว่า TANOO PiP ยังลอยอยู่เหนือ Camera หรือไม่")
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding()
            .navigationTitle("TANOO PiP Test")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            pip.refreshStatus()
        }
    }
}

private struct PiPPreview: UIViewRepresentable {
    let controller: PiPController

    func makeUIView(context: Context) -> SampleBufferPreviewView {
        SampleBufferPreviewView()
    }

    func updateUIView(_ uiView: SampleBufferPreviewView, context: Context) {
        uiView.sampleBufferLayer.frame = uiView.bounds

        // Wait until SwiftUI has actually placed the preview in a visible window.
        // PiP can remain unavailable if its source layer is configured too early.
        if uiView.window != nil, uiView.bounds.width > 0, uiView.bounds.height > 0 {
            controller.attach(to: uiView.sampleBufferLayer)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard uiView.window != nil,
                      uiView.bounds.width > 0,
                      uiView.bounds.height > 0 else { return }
                controller.attach(to: uiView.sampleBufferLayer)
            }
        }
    }
}

final class SampleBufferPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        sampleBufferLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sampleBufferLayer.frame = bounds
    }
}
