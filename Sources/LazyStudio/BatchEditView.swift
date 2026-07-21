import SwiftUI
import AppKit

/// "AI Edit" sidebar screen: pick several videos, one instruction, and the
/// AI edits them all — cuts, title, description, captions — hands-off.
struct BatchEditView: View {
    @ObservedObject var recorder: RecorderEngine
    @ObservedObject var editor: AIEditor
    @StateObject private var model = LibraryModel()
    @State private var picked: Set<URL> = []
    @State private var instruction = ""
    @State private var status: [URL: String] = [:]
    @State private var running = false

    init(recorder: RecorderEngine) {
        self.recorder = recorder
        self.editor = recorder.aiEditor
    }

    private var rawItems: [VideoItem] { model.items.filter { !$0.isPolished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI Edit")
                .font(.title2.bold())
            Text("Tick the videos, say what you want once, and the AI edits every one of them — cuts, title, description, and captions. Files land next to the originals.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(picked.count == rawItems.count ? "Select none" : "Select all") {
                picked = picked.count == rawItems.count ? [] : Set(rawItems.map(\.url))
            }
            .font(.caption)
            .disabled(running)

            List(rawItems) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { picked.contains(item.url) },
                        set: { on in
                            if on { picked.insert(item.url) } else { picked.remove(item.url) }
                        }
                    ))
                    .labelsHidden()
                    .disabled(running)
                    Group {
                        if let thumb = model.thumbnails[item.url] {
                            Image(nsImage: thumb).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .frame(width: 74, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.callout).lineLimit(1)
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let s = status[item.url] {
                        Text(s)
                            .font(.caption)
                            .foregroundStyle(s.hasPrefix("Done") ? .green : s == "Editing…" ? .purple : .secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)

            TextField("Optional: tell the AI what you want for all of them…", text: $instruction)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    runBatch()
                } label: {
                    Label(running ? "Editing… (\(doneCount)/\(picked.count))" : "Edit \(picked.count) video\(picked.count == 1 ? "" : "s") with AI",
                          systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(picked.isEmpty || running || recorder.activeAgent == nil)
                if running {
                    ProgressView().controlSize(.small)
                }
            }
            if recorder.activeAgent == nil {
                Text("Install and log in to Claude Code or Codex first (see any video's editor).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .onAppear { model.refresh(dir: recorder.recordingsDirectory) }
    }

    private var doneCount: Int {
        status.values.filter { $0.hasPrefix("Done") || $0.hasPrefix("Failed") }.count
    }

    private func runBatch() {
        guard let agent = recorder.activeAgent, !running else { return }
        running = true
        let urls = rawItems.map(\.url).filter { picked.contains($0) }
        let extra = instruction.isEmpty ? nil : instruction
        Task {
            for url in urls {
                status[url] = "Editing…"
                await editor.polish(url: url, agent: agent, instruction: extra)
                status[url] = editor.lastPolishedURL != nil
                    ? "Done ✨"
                    : "Failed: \(editor.lastError.isEmpty ? "unknown" : editor.lastError)"
            }
            running = false
            model.refresh(dir: recorder.recordingsDirectory)
        }
    }
}
