import AppKit
import SwiftUI

/// Floating "● REC 00:12  [Stop]" pill at the top of the screen while
/// recording — unmistakable feedback that recording is live.
@MainActor
final class RecordingHUDController {
    private var window: NSPanel?
    private var timer: Timer?
    private var startedAt = Date()
    private let model = HUDModel()

    func show(onStop: @escaping () -> Void) {
        hide()
        guard let screen = NSScreen.main else { return }
        startedAt = Date()
        model.elapsed = "00:00"
        model.onStop = onStop

        let hosting = NSHostingController(rootView: HUDView(model: model))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.setContentSize(hosting.view.fittingSize)

        // Just below the menu bar / notch, centered.
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: f.midX - hosting.view.fittingSize.width / 2,
            y: f.maxY - hosting.view.fittingSize.height - 8
        ))
        panel.orderFrontRegardless()
        window = panel

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = Int(Date().timeIntervalSince(self.startedAt))
                self.model.elapsed = String(format: "%02d:%02d", s / 60, s % 60)
            }
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var elapsed = "00:00"
    var onStop: () -> Void = {}
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
            Text(model.elapsed)
                .font(.system(.body, design: .monospaced).bold())
                .foregroundStyle(.white)
            Button {
                model.onStop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.callout.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.75), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .padding(6)
        .onAppear { pulse = true }
    }
}
