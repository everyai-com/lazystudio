import SwiftUI
import AVKit

/// SwiftUI's VideoPlayer (AVKit_SwiftUI) crashes at metadata setup in
/// SwiftPM-built apps — wrap AppKit's AVPlayerView instead.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Pops up the moment a recording stops: watch it, one-click AI clean-up,
/// find the file. Simple enough for a 10-year-old — no Finder digging.
@MainActor
enum ResultWindow {
    private static var window: NSWindow?

    static func show(url: URL, recorder: RecorderEngine) {
        close()
        let hosting = NSHostingController(
            rootView: ResultView(url: url, recorder: recorder)
        )
        let w = NSWindow(contentViewController: hosting)
        w.title = "Your video is ready! 🎉"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    static func close() {
        window?.close()
        window = nil
    }
}

private struct ResultView: View {
    let url: URL
    @ObservedObject var recorder: RecorderEngine
    @ObservedObject var editor: AIEditor
    @State private var player: AVPlayer

    init(url: URL, recorder: RecorderEngine) {
        self.url = url
        self.recorder = recorder
        self.editor = recorder.aiEditor
        _player = State(initialValue: AVPlayer(url: url))
    }

    /// Once polish finishes, show the polished cut instead.
    private var showingPolished: Bool { editor.lastPolishedURL != nil }

    var body: some View {
        VStack(spacing: 14) {
            PlayerView(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if editor.isPolishing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(editor.stage)
                        .font(.title3)
                }
                .padding(.vertical, 6)
            } else if showingPolished {
                VStack(spacing: 4) {
                    Text("✨ All cleaned up!")
                        .font(.title3.bold())
                    if !editor.lastTitle.isEmpty {
                        Text(editor.lastTitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                if !showingPolished, !editor.isPolishing {
                    Button {
                        guard let agent = recorder.activeAgent else { return }
                        Task { await editor.polish(url: url, agent: agent) }
                    } label: {
                        Label("Make it awesome", systemImage: "wand.and.stars")
                            .font(.title3.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(recorder.agents.isEmpty)
                    .help(recorder.agents.isEmpty
                          ? "Install Claude Code or Codex first"
                          : "AI removes silences and mistakes for you")
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [editor.lastPolishedURL ?? url]
                    )
                } label: {
                    Label("Show my video", systemImage: "folder")
                        .padding(.vertical, 6)
                }
                .controlSize(.large)

                Button {
                    ResultWindow.close()
                    MainWindow.show()
                } label: {
                    Text("Done")
                        .padding(.vertical, 6)
                }
                .controlSize(.large)
            }

            if recorder.agents.isEmpty {
                Text("Want magic clean-up? Ask a grown-up to install Claude Code or Codex 🙂")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onChange(of: editor.lastPolishedURL) { _, polished in
            if let polished {
                player.pause()
                player = AVPlayer(url: polished)
                player.play()
            }
        }
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
