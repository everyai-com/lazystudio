import SwiftUI
import AppKit
import AVFoundation

/// Loom-style recorder card: pill rows for sources, one big Start button.
/// The camera bubble floats live (like Loom) so you can position yourself
/// before and during the countdown.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    static weak var recorder: RecorderEngine?
    private static let delegate = MainWindowDelegate()

    /// Camera preview belongs to the Record screen only.
    static var paneIsRecord = true

    static func show() {
        guard let recorder else { return }
        if paneIsRecord { recorder.updateBubblePreview() }
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingController(rootView: AppShellView(recorder: recorder))
        let w = NSWindow(contentViewController: hosting)
        w.title = "LazyStudio"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.setContentSize(NSSize(width: 900, height: 600))
        w.minSize = NSSize(width: 760, height: 500)
        w.isReleasedWhenClosed = false
        w.delegate = delegate
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    static func hide() {
        window?.orderOut(nil)
    }

    /// Open the window on My Videos (used right after a recording stops).
    static func showVideos() {
        show()
        NotificationCenter.default.post(name: .lsShowVideos, object: nil)
    }
}

extension Notification.Name {
    static let lsShowVideos = Notification.Name("lazystudio.showVideos")
}

/// Closing the panel turns off the camera preview (unless recording) —
/// no phantom green light, no idle CPU.
private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let recorder = MainWindow.recorder, !recorder.isRecording else { return }
        recorder.hideBubblePreview()
    }
}

/// Full app shell: sidebar navigation like Loom's desktop app.
private struct AppShellView: View {
    let recorder: RecorderEngine
    @State private var pane: Pane = .record

    enum Pane: String, CaseIterable, Identifiable {
        case record = "Record"
        case videos = "My Videos"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .record: "record.circle.fill"
            case .videos: "film.stack.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.icon)
                    .tag(p)
            }
            .onChange(of: pane) { _, p in
                // Camera on only while you're on the Record screen.
                MainWindow.paneIsRecord = p == .record
                if p == .record { recorder.updateBubblePreview() }
                else { recorder.hideBubblePreview() }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .listStyle(.sidebar)
            .onReceive(NotificationCenter.default.publisher(for: .lsShowVideos)) { _ in
                pane = .videos
            }
        } detail: {
            let _ = pane
            switch pane {
            case .record:
                MainView(recorder: recorder)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .videos:
                LibraryView(recorder: recorder)
            }
        }
    }
}

private struct MainView: View {
    @ObservedObject var recorder: RecorderEngine
    @ObservedObject var editor: AIEditor
    @Environment(\.openSettings) private var openSettings
    @AppStorage(CameraOverlayController.mirrorKey) private var mirrorCamera = true

    init(recorder: RecorderEngine) {
        self.recorder = recorder
        self.editor = recorder.aiEditor
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.tv.fill")
                    .foregroundStyle(.purple)
                Text("lazystudio")
                    .font(.title3.bold())
                Spacer()
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            sourceRow("display", "Full screen", nil)
            sourceRow("video.fill", "Camera", $recorder.showCamera)
            sourceRow("mic.fill", "Microphone", $recorder.includeMicrophone)
            sourceRow("speaker.wave.2.fill", "Computer sound", $recorder.includeSystemAudio)
            sourceRow("cursorarrow.rays", "Highlight clicks", $recorder.clickEffects)
            if recorder.showCamera {
                sourceRow("arrow.left.arrow.right", "Mirror camera", $mirrorCamera)
            }

            Button {
                Task { await recorder.start() }
            } label: {
                Text("Start Recording")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Color(red: 0.92, green: 0.36, blue: 0.25))
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(editor.isPolishing || recorder.isRecording)
            .padding(.top, 6)

            // Status / polish progress
            if editor.isPolishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(editor.stage)
                }
                .font(.callout)
            } else if !recorder.statusMessage.isEmpty,
                      !["Ready", "Saved"].contains(recorder.statusMessage) {
                Text(recorder.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

        }
        .padding(16)
        .frame(width: 300)
        .onChange(of: recorder.showCamera) { _, _ in
            recorder.updateBubblePreview()
        }
        .onChange(of: mirrorCamera) { _, _ in
            recorder.cameraMirrorChanged()
        }
    }

    /// Loom-style pill row. Pass nil binding for a fixed label row.
    private func sourceRow(_ icon: String, _ name: String, _ on: Binding<Bool>?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle((on?.wrappedValue ?? true) ? .primary : .secondary)
            Text(name)
                .foregroundStyle((on?.wrappedValue ?? true) ? .primary : .secondary)
            Spacer()
            if let on {
                Button {
                    on.wrappedValue.toggle()
                } label: {
                    Text(on.wrappedValue ? "On" : "Off")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            on.wrappedValue ? Color.green.opacity(0.85) : Color.gray.opacity(0.35),
                            in: Capsule()
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }
}
