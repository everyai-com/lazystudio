import SwiftUI
import AVFoundation
import Speech

/// Shown on launch until every permission is granted — otherwise a menu-bar-only
/// app looks like "nothing happened" when you open it.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static var allPermissionsGranted: Bool {
        CGPreflightScreenCaptureAccess()
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func showIfNeeded() {
        guard !allPermissionsGranted || !UserDefaults.standard.bool(forKey: "welcomed") else { return }
        show()
    }

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let hosting = NSHostingController(rootView: WelcomeView())
        let w = NSWindow(contentViewController: hosting)
        w.title = "Welcome to LazyStudio"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        UserDefaults.standard.set(true, forKey: "welcomed")
    }

    static func close() {
        window?.close()
        window = nil
    }
}

private struct WelcomeView: View {
    @State private var screenOK = CGPreflightScreenCaptureAccess()
    @State private var camOK = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechOK = SFSpeechRecognizer.authorizationStatus() == .authorized

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles.tv.fill")
                .font(.system(size: 44))
                .foregroundStyle(.purple)
            Text("LazyStudio lives in your menu bar")
                .font(.title2.bold())
            Text("Look for the ⏺ icon at the top-right of your screen.\nOne click to record — AI does the editing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                permissionRow("Screen Recording", ok: screenOK) {
                    if !CGRequestScreenCaptureAccess() {
                        openPrivacyPane("Privacy_ScreenCapture")
                    }
                    screenOK = CGPreflightScreenCaptureAccess()
                }
                permissionRow("Camera", ok: camOK) {
                    AVCaptureDevice.requestAccess(for: .video) { ok in
                        Task { @MainActor in camOK = ok }
                    }
                }
                permissionRow("Microphone", ok: micOK) {
                    AVCaptureDevice.requestAccess(for: .audio) { ok in
                        Task { @MainActor in micOK = ok }
                    }
                }
                permissionRow("Speech (for AI editing)", ok: speechOK) {
                    SFSpeechRecognizer.requestAuthorization { status in
                        Task { @MainActor in speechOK = status == .authorized }
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

            Text("Screen Recording needs a quit & reopen after granting — macOS rules, not ours.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Let's go") { WelcomeWindow.close() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(28)
        .frame(width: 420)
    }

    private func permissionRow(_ name: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? .green : .secondary)
            Text(name)
            Spacer()
            if !ok {
                Button("Grant", action: action)
                    .controlSize(.small)
            }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
