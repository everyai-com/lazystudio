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
