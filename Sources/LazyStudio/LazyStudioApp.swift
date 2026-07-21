import SwiftUI

@main
struct LazyStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var recorder = RecorderEngine()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(recorder)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless caption test: `LazyStudio --test-captions <video>` runs the
        // real transcribe → burn → export pipeline and quits. Dev-only.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--test-captions"), args.count > i + 1 {
            NSApp.setActivationPolicy(.prohibited)
            let url = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                let session = EditSession(url: url)
                await session.load()
                var waited = 0
                while session.isTranscribing || session.transcript.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                    waited += 1
                    if waited > 600 { print("TEST FAILED: transcript timeout"); exit(1) }
                }
                print("TEST transcript words: \(session.transcript.count)")
                do {
                    let out = try await session.export(burnCaptions: true, social: true)
                    print("TEST exported: \(out.path)")
                } catch {
                    print("TEST FAILED: \(error)")
                }
                exit(0)
            }
            return
        }
        // Only one copy at a time — relaunching just pings the running one.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != .current }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }
        // Real app: Dock icon + menu bar ⏺, so it's always findable.
        NSApp.setActivationPolicy(.regular)
        // Recorder is created by the SwiftUI scene; open the home window
        // on the next runloop tick once it exists.
        DispatchQueue.main.async {
            if WelcomeWindow.allPermissionsGranted {
                MainWindow.show()
            } else {
                WelcomeWindow.showIfNeeded()
            }
        }
    }

    // Closing the window must not quit the app — it lives in the Dock
    // and menu bar until you actually hit Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Clicking the Dock icon brings up the home window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return true
    }
}
