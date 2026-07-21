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
        // The studio is always dark — it's a look, not a preference.
        w.appearance = NSAppearance(named: .darkAqua)
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
    static let lsAdoptSession = Notification.Name("lazystudio.adoptSession")
}

/// Closing the panel turns off the camera preview (unless recording) —
/// no phantom green light, no idle CPU.
private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let recorder = MainWindow.recorder, !recorder.isRecording else { return }
        recorder.hideBubblePreview()
    }
}

/// AI Edit pane: chat editor (Lovable-style) with a Batch mode tab.
private struct AIEditPane: View {
    let recorder: RecorderEngine
    @State private var mode = "chat"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("Chat").tag("chat")
                Text("Batch").tag("batch")
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(.top, 10)
            if mode == "chat" {
                ChatEditorView(recorder: recorder)
            } else {
                BatchEditView(recorder: recorder)
            }
        }
        .studioStage()
    }
}

/// Full app shell: sidebar navigation like Loom's desktop app.
private struct AppShellView: View {
    let recorder: RecorderEngine
    @State private var pane: Pane = .record

    enum Pane: String, CaseIterable, Identifiable {
        case record = "Record"
        case videos = "My Videos"
        case edit = "AI Edit"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .record: "record.circle.fill"
            case .videos: "film.stack.fill"
            case .edit: "wand.and.stars"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label {
                    Text(p.rawValue)
                } icon: {
                    Image(systemName: p.icon)
                        .foregroundStyle(pane == p ? Theme.purple : Color.secondary)
                }
                .tag(p)
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.brandGradient)
                            .frame(width: 30, height: 30)
                        Image(systemName: "sparkles.tv.fill")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                    Text("LazyStudio")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
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
            case .edit:
                AIEditPane(recorder: recorder)
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
        ZStack {
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 54, height: 54)
                            .shadow(color: Theme.purple.opacity(0.5), radius: 12, y: 4)
                        Image(systemName: "sparkles.tv.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    Text("LazyStudio")
                        .font(.title2.bold())
                    Text("Record lazily. Ship polished.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)

                VStack(spacing: 8) {
                    sourceRow("display", "Full screen", nil)
                    sourceRow("video.fill", "Camera", $recorder.showCamera)
                    sourceRow("mic.fill", "Microphone", $recorder.includeMicrophone)
                    sourceRow("speaker.wave.2.fill", "Computer sound", $recorder.includeSystemAudio)
                    sourceRow("cursorarrow.rays", "Highlight clicks", $recorder.clickEffects)
                    if recorder.showCamera {
                        sourceRow("arrow.left.arrow.right", "Mirror camera", $mirrorCamera)
                    }
                }

                Button {
                    Task { await recorder.start() }
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                }
                .buttonStyle(RecordButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(editor.isPolishing || recorder.isRecording)
                .padding(.top, 8)

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
            .padding(22)
            .frame(width: 320)
            .lsCard(radius: 22)
            .overlay(alignment: .topTrailing) {
                Button { openSettings() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(12)
            }
        }
        .studioStage()
        .onChange(of: recorder.showCamera) { _, _ in
            recorder.updateBubblePreview()
        }
        .onChange(of: mirrorCamera) { _, _ in
            recorder.cameraMirrorChanged()
        }
    }

    /// Loom-style pill row. Pass nil binding for a fixed label row.
    private func sourceRow(_ icon: String, _ name: String, _ on: Binding<Bool>?) -> some View {
        let active = on?.wrappedValue ?? true
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(active ? Theme.purple.opacity(0.15) : Color.gray.opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(active ? Theme.purple : .secondary)
            }
            Text(name)
                .font(.callout.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)
            Spacer()
            if let on {
                Toggle("", isOn: on)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Theme.purple)
            } else {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.purple)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .animation(.lsSnappy(0.15), value: active)
    }
}
