import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var recorder: RecorderEngine
    @AppStorage("aiProvider") private var aiProvider = "claude"
    @AppStorage("aiAPIKey") private var aiAPIKey = ""

    var body: some View {
        TabView {
            Form {
                Toggle("Microphone", isOn: $recorder.includeMicrophone)
                Toggle("System Audio", isOn: $recorder.includeSystemAudio)
                Toggle("Camera Bubble", isOn: $recorder.showCamera)
                LabeledContent("Recordings folder") {
                    Text(recorder.recordingsDirectory.path)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Recording", systemImage: "record.circle") }

            Form {
                Picker("Provider", selection: $aiProvider) {
                    Text("Claude").tag("claude")
                    Text("OpenAI").tag("openai")
                    Text("Local (whisper.cpp)").tag("local")
                }
                SecureField("API Key", text: $aiAPIKey)
                Text("Used for the AI Polish pipeline: transcription, silence cuts, auto-zoom, chapters, and YouTube title generation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("AI", systemImage: "wand.and.stars") }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 260)
    }
}
