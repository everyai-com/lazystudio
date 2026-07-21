import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var recorder: RecorderEngine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(CameraOverlayController.shapeKey) private var cameraShape = "circle"
    @AppStorage(CameraOverlayController.sizeKey) private var cameraSize = "medium"

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Microphone", isOn: $recorder.includeMicrophone)
                Toggle("System Audio", isOn: $recorder.includeSystemAudio)
                Toggle("Camera Bubble", isOn: $recorder.showCamera)
                if recorder.showCamera {
                    Picker("Bubble Shape", selection: $cameraShape) {
                        Text("Round").tag("circle")
                        Text("Square").tag("square")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: cameraShape) { _, _ in recorder.cameraShapeChanged() }
                    Picker("Bubble Size", selection: $cameraSize) {
                        Text("Small").tag("small")
                        Text("Medium").tag("medium")
                        Text("Large").tag("large")
                    }
                    .pickerStyle(.segmented)
                    Text("Tip: double-click the bubble while recording to switch shape; drag it anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Section("Agent access (MCP)") {
                Text("LazyStudio runs a local MCP server — your agents can edit your videos directly and the strip updates live. Connect once:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Server") {
                    Text("http://127.0.0.1:\(String(MCPServer.port))/mcp")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copy Claude Code command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "claude mcp add --transport http lazystudio http://127.0.0.1:\(String(MCPServer.port))/mcp",
                            forType: .string
                        )
                    }
                    Button("Copy Codex config") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "[mcp_servers.lazystudio]\nurl = \"http://127.0.0.1:\(String(MCPServer.port))/mcp\"",
                            forType: .string
                        )
                    }
                }
                Text("Then just say: “edit my last LazyStudio recording, keep it under 2 minutes.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
