import SwiftUI

struct MenuView: View {
    @EnvironmentObject var recorder: RecorderEngine
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles.tv")
                Text("LazyStudio").font(.headline)
                Spacer()
                Text(recorder.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    if recorder.isRecording {
                        await recorder.stop()
                    } else {
                        await recorder.start()
                    }
                }
            } label: {
                Label(
                    recorder.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r")
            .controlSize(.large)
            .tint(recorder.isRecording ? .red : .accentColor)

            Divider()

            Toggle("Microphone", isOn: $recorder.includeMicrophone)
            Toggle("System Audio", isOn: $recorder.includeSystemAudio)
            Toggle("Camera Bubble", isOn: $recorder.showCamera)
                .disabled(recorder.isRecording)

            Divider()

            if let url = recorder.lastRecordingURL, !recorder.isRecording {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show Last Recording", systemImage: "folder")
                }
                Button {
                    // AI polish pipeline — see AIEditor.swift
                    Task { await AIEditor.shared.polish(url: url) }
                } label: {
                    Label("AI Polish (coming soon)", systemImage: "wand.and.stars")
                }
            }

            Button {
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }

            Button("Quit LazyStudio") {
                NSApp.terminate(nil)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 260)
    }
}
