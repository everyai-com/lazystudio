import SwiftUI
import AppKit

/// Floating teleprompter: paste a script, it auto-scrolls while you record.
/// The panel is excluded from screen capture (sharingType = .none), so the
/// viewer never sees it — founders stop forgetting their lines.
@MainActor
final class TeleprompterController: ObservableObject {
    static let shared = TeleprompterController()

    @Published var script: String =
        UserDefaults.standard.string(forKey: "prompterScript") ?? ""
    @Published var speed: Double =
        UserDefaults.standard.object(forKey: "prompterSpeed") as? Double ?? 30
    @Published var isScrolling = false

    private var window: NSPanel?

    var isVisible: Bool { window != nil }

    func toggle() {
        if window != nil { hide() } else { show() }
    }

    func show() {
        guard window == nil, let screen = NSScreen.main else { return }
        let hosting = NSHostingController(rootView: TeleprompterView(model: self))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.sharingType = .none          // invisible in the recording
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let width: CGFloat = 560
        let height: CGFloat = 210
        let f = screen.visibleFrame
        panel.setFrame(
            NSRect(x: f.midX - width / 2, y: f.maxY - height - 46,
                   width: width, height: height),
            display: true
        )
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        isScrolling = false
        window?.orderOut(nil)
        window = nil
    }

    func persist() {
        UserDefaults.standard.set(script, forKey: "prompterScript")
        UserDefaults.standard.set(speed, forKey: "prompterSpeed")
    }
}

private struct TeleprompterView: View {
    @ObservedObject var model: TeleprompterController
    @State private var offset: CGFloat = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 8) {
            // Controls
            HStack(spacing: 10) {
                Button {
                    model.isScrolling.toggle()
                    if model.isScrolling { startScroll() } else { stopScroll() }
                } label: {
                    Image(systemName: model.isScrolling ? "pause.fill" : "play.fill")
                }
                Button {
                    offset = 0
                } label: { Image(systemName: "arrow.counterclockwise") }
                Slider(value: $model.speed, in: 10...80) { _ in model.persist() }
                    .frame(width: 130)
                Text("Speed").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.hide()
                } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(0.8))

            if model.script.isEmpty {
                TextEditor(text: $model.script)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .background(.white.opacity(0.06))
                    .overlay(alignment: .topLeading) {
                        Text("Paste your script here…")
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
            } else if model.isScrolling {
                GeometryReader { geo in
                    Text(model.script)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                        .lineSpacing(7)
                        .frame(width: geo.size.width, alignment: .leading)
                        .offset(y: -offset)
                }
                .clipped()
            } else {
                TextEditor(text: $model.script)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.script) { _, _ in model.persist() }
            }
        }
        .padding(14)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.12))
        )
        .padding(4)
    }

    private func startScroll() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                offset += CGFloat(model.speed) / 60.0
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopScroll() {
        timer?.invalidate()
        timer = nil
    }
}
