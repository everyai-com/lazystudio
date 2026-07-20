import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var recorder: RecorderEngine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Microphone", isOn: $recorder.includeMicrophone)
                Toggle("System Audio", isOn: $recorder.includeSystemAudio)
                Toggle("Camera Bubble", isOn: $recorder.showCamera)
                Toggle("Cursor Spotlight & Click Ripples", isOn: $recorder.clickEffects)
                LabeledContent("Recordings folder") {
                    Text(recorder.recordingsDirectory.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }

            Section("AI Polish") {
                Toggle("Auto-polish after recording", isOn: $recorder.autoPolish)
                if recorder.agents.isEmpty {
                    Text("No AI agent found. Install Claude Code (`npm i -g @anthropic-ai/claude-code`) or Codex — LazyStudio detects them automatically and uses your existing subscription. No API keys needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recorder.agents) { agent in
                        LabeledContent(agent.displayName) {
                            Text(agent.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Transcription runs on-device with Apple Speech. The first detected agent plans the edit: silence cuts, retake removal, YouTube title & description.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Start at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Updates") {
                LabeledContent("Version", value: recorder.updater.currentVersion)
                HStack {
                    Button("Check for Updates") {
                        Task { await recorder.updater.check() }
                    }
                    Text(recorder.updater.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
    }
}
