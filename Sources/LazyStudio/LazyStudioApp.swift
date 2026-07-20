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
        // Menu bar app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        WelcomeWindow.showIfNeeded()
    }

    // Double-clicking the app in Finder again brings up the welcome window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WelcomeWindow.show()
        return true
    }
}
