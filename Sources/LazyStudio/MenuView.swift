import SwiftUI

/// One big button. Everything else is automatic.
struct MenuView: View {
    @EnvironmentObject var recorder: RecorderEngine
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 14) {
            // The button
            Button {
                Task {
                    if recorder.isRecording {
                        await recorder.stop()
                    } else {
                        await recorder.start()
                    }
                }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle.fill")
                        .font(.system(size: 34))
                    Text(recorder.isRecording ? "Stop" : "Record")
                        .font(.title3.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .keyboardShortcut("r")
            .disabled(recorder.aiEditor.isPolishing)

            // Status line
            if recorder.aiEditor.isPolishing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(recorder.aiEditor.stage)
                        .font(.callout)
                }
            } else if !recorder.statusMessage.isEmpty, recorder.statusMessage != "Ready" {
                Text(recorder.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // AI brain indicator — auto-detected, zero setup
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(recorder.agents.isEmpty ? .secondary : Color.purple)
                if let agent = recorder.activeAgent {
                    Text("Auto-polish with \(agent.displayName)")
                } else {
                    Text("Install Claude Code or Codex for AI polish")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !recorder.agents.isEmpty {
                    Toggle("", isOn: $recorder.autoPolish)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
            .font(.caption)

            if let version = recorder.updater.updateAvailable {
                Button {
                    Task { await recorder.updater.installUpdate() }
                } label: {
                    Label(
                        recorder.updater.isWorking
                            ? recorder.updater.status
                            : "Update to \(version)",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .tint(.green)
                .disabled(recorder.updater.isWorking)
            }

            Divider()

            HStack {
                if let url = recorder.lastRecordingURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Image(systemName: "folder") }
                    .help("Show recordings")

                    if let agent = recorder.activeAgent, !recorder.aiEditor.isPolishing {
                        Button {
                            Task { await recorder.aiEditor.polish(url: url, agent: agent) }
                        } label: { Image(systemName: "wand.and.stars") }
                        .help("Polish last recording")
                    }
                }
                Spacer()
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 250)
    }
}
