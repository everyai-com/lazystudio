import SwiftUI
import AppKit
import AVFoundation

/// Lovable-style AI editor: pick a video, chat on the left, and the agent
/// edits it live through LazyStudio's tools. History persists per video.
struct ChatEditorView: View {
    @ObservedObject var recorder: RecorderEngine
    @ObservedObject private var store = ChatStore.shared
    @StateObject private var model = LibraryModel()
    @State private var session: EditSession?
    @State private var pickedURL: URL?
    @State private var input = ""
    @State private var busy = false

    private let suggestions = ["Cut the silences", "Keep it under a minute",
                               "Make it punchy", "Write me a title"]

    init(recorder: RecorderEngine) {
        self.recorder = recorder
    }

    private var messages: [ChatStore.Msg] {
        pickedURL.map { store.thread(for: $0) } ?? []
    }

    var body: some View {
        HStack(spacing: 0) {
            chatColumn
                .frame(minWidth: 320, maxWidth: 400)
            Divider()
            previewColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            model.refresh(dir: recorder.recordingsDirectory)
            if pickedURL == nil {
                // Come back to the same conversation you left.
                let remembered = model.items.first { $0.url.lastPathComponent == store.lastVideo }
                if let target = remembered ?? model.items.first { pick(target.url) }
            }
        }
    }

    private func pick(_ url: URL) {
        pickedURL = url
        store.rememberVideo(url)
        session?.player.pause()
        let s = EditSession(url: url)
        session = s
        LibraryView.activeSession = s   // MCP tools edit THIS session
        Task { await s.load() }
    }

    // MARK: - Chat column

    private var chatColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI Editor", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button {
                    if let url = pickedURL { store.clear(for: url) }
                } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("New chat")
                .disabled(busy)
                Picker("", selection: Binding(
                    get: { pickedURL ?? model.items.first?.url },
                    set: { if let u = $0 { pick(u) } }
                )) {
                    ForEach(model.items) { item in
                        let d = model.durations[item.url].map { " · \(Int($0))s" } ?? ""
                        Text(item.name + d).tag(Optional(item.url))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text("Hi! I'm your editor. Tell me what you want — \"cut the silences\", \"keep only the demo part\", \"make it snappy\" — and I'll do it while you watch.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        ForEach(messages) { msg in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if msg.fromUser { Spacer(minLength: 30) }
                                    Text(msg.text)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .padding(10)
                                        .background(
                                            msg.fromUser ? Color.accentColor.opacity(0.13)
                                                         : Color.gray.opacity(0.09),
                                            in: RoundedRectangle(cornerRadius: 12)
                                        )
                                    if !msg.fromUser { Spacer(minLength: 30) }
                                }
                                if let activity = msg.activity {
                                    Label(activity, systemImage: "scissors")
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Theme.accent.opacity(0.1), in: Capsule())
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .id(msg.id)
                        }
                        if busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("✦ Editing — using LazyStudio tools…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) {
                            input = s
                            send()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(busy)
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.top, 8)
            HStack(spacing: 8) {
                TextField("Ask your editor…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { send() }
                Button {
                    send()
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            if let agent = recorder.activeAgent {
                Text("Powered by \(agent.displayName) + LazyStudio tools")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            } else {
                Text("Install Claude Code or Codex to chat-edit.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Sending

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy,
              let agent = recorder.activeAgent,
              let url = pickedURL, let session else { return }
        input = ""
        store.append(.init(fromUser: true, text: text), for: url)
        busy = true
        let followUp = messages.filter(\.fromUser).count > 1
        lslog("chat: send via \(agent.id) — \(text.prefix(80))")

        let state = session.segments.map {
            String(format: "%.1f-%.1f %@", $0.start, $0.end, $0.kept ? "KEEP" : "cut")
        }.joined(separator: "; ")

        let prompt = """
        You are the AI video editor inside the LazyStudio app. The user is editing the video file "\(url.lastPathComponent)" (duration \(Int(session.duration))s).
        Current timeline: \(state)

        Use the MCP tools from the "lazystudio" server to do the actual work: get_transcript to read the words, get_timeline to check state, capture_frame to look at the picture, set_keep_ranges to make cuts (this updates the app live), export_video only if the user asks to export.
        Work only on this video file. After making edits, reply to the user in 1-3 short friendly sentences describing exactly what you changed (times + reasons). If their request is unclear, make your best tasteful edit rather than asking questions.

        User request: \(text)
        """

        let keptBefore = session.keptDuration
        Task {
            var reply = ""
            var failure: String?
            if agent.id == "claude" {
                do {
                    reply = try await agent.chat(message: prompt, followUp: followUp)
                } catch {
                    lslog("chat: claude direct failed — \(error.localizedDescription.prefix(300))")
                    failure = error.localizedDescription
                }
            }
            // Planner mode: primary for codex/gemini, automatic fallback
            // when the direct path fails or comes back empty.
            if agent.id != "claude" || reply.isEmpty {
                do {
                    reply = try await plannerEdit(agent: agent, url: url,
                                                  session: session, request: text)
                    failure = nil
                } catch {
                    lslog("chat: planner failed — \(error.localizedDescription.prefix(300))")
                    failure = failure ?? error.localizedDescription
                }
            }

            if let failure, reply.isEmpty {
                store.append(.init(fromUser: false,
                    text: "That didn't work: \(failure)\n(Full details: ~/Library/Logs/LazyStudio.log)"),
                    for: url)
            } else {
                var msg = ChatStore.Msg(fromUser: false,
                    text: reply.isEmpty ? "Done — check the strip on the right." : reply)
                if abs(session.keptDuration - keptBefore) > 0.2 {
                    msg.activity = String(format: "Timeline updated — kept %.0fs of %.0fs",
                                          session.keptDuration, session.duration)
                }
                store.append(msg, for: url)
            }
            busy = false
        }
    }

    /// The agent plans, LazyStudio applies — reliable in every setup.
    private func plannerEdit(agent: AgentCLI, url: URL,
                             session: EditSession, request: String) async throws -> String {
        let plan = try await recorder.aiEditor.makePlan(
            url: url, agent: agent, instruction: request
        )
        await session.apply(keep: plan.keep, cuts: plan.cuts)
        var lines: [String] = []
        if let cuts = plan.cuts, !cuts.isEmpty {
            let described = cuts.prefix(6).map {
                String(format: "%d:%02d–%d:%02d %@",
                       Int($0.start) / 60, Int($0.start) % 60,
                       Int($0.end) / 60, Int($0.end) % 60, $0.reason)
            }.joined(separator: ", ")
            lines.append("Made \(cuts.count) cut\(cuts.count == 1 ? "" : "s"): \(described).")
        } else {
            lines.append("Trimmed it down.")
        }
        lines.append(String(format: "Now %.0fs instead of %.0fs.",
                            session.keptDuration, session.duration))
        if !plan.title.isEmpty { lines.append("Title idea: “\(plan.title)”") }
        lines.append("Happy? Hit Export in My Videos — or tell me what to change.")
        return lines.joined(separator: " ")
    }

    // MARK: - Live preview

    @ViewBuilder
    private var previewColumn: some View {
        if let session {
            SessionPreview(session: session)
                .padding(14)
        } else {
            Text("Pick a video to start")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Player + simple live strip that re-renders as the agent edits.
private struct SessionPreview: View {
    @ObservedObject var session: EditSession

    var body: some View {
        VStack(spacing: 10) {
            PlayerView(player: session.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            GeometryReader { geo in
                let w = geo.size.width
                let dur = max(session.duration, 0.1)
                ZStack(alignment: .leading) {
                    ForEach(session.segments) { seg in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(seg.kept ? Color.accentColor.opacity(0.8)
                                           : Color.gray.opacity(0.25))
                            .frame(width: max(3, w * seg.length / dur - 1), height: 22)
                            .offset(x: w * seg.start / dur)
                    }
                }
            }
            .frame(height: 22)
            if session.hasCuts {
                Text("\(Int(session.keptDuration))s of \(Int(session.duration))s kept — open My Videos for fine control")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
