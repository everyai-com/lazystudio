import SwiftUI
import AppKit
import AVFoundation

/// Loom-style library: thumbnail list on the left, player + AI edit panel
/// on the right (like Loom's video page with its purple "Loom AI" card).
@MainActor
enum LibraryWindow {
    private static var window: NSWindow?

    static func show(recorder: RecorderEngine) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingController(rootView: LibraryView(recorder: recorder))
        let w = NSWindow(contentViewController: hosting)
        w.title = "My Videos"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 960, height: 620))
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

struct VideoItem: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isPolished: Bool { url.lastPathComponent.contains("polished") }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var selected: VideoItem?
    @Published var thumbnails: [URL: NSImage] = [:]

    func refresh(dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        items = files
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .map {
                let d = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return VideoItem(url: $0, date: d)
            }
            .sorted { $0.date > $1.date }
        if selected == nil || !items.contains(where: { $0.id == selected?.id }) {
            selected = items.first
        }
        for item in items where thumbnails[item.url] == nil {
            loadThumbnail(item.url)
        }
    }

    private func loadThumbnail(_ url: URL) {
        Task.detached(priority: .utility) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 480, height: 480)
            guard let cg = try? await gen.image(at: CMTime(seconds: 0.4, preferredTimescale: 600)).image
            else { return }
            let img = NSImage(cgImage: cg, size: .zero)
            await MainActor.run { [weak self] in self?.thumbnails[url] = img }
        }
    }
}

struct LibraryView: View {
    @ObservedObject var recorder: RecorderEngine
    @ObservedObject var editor: AIEditor
    @StateObject private var model = LibraryModel()
    @State private var session: EditSession?
    @State private var instruction = ""
    @State private var confirmDelete: VideoItem?
    @State private var errorText = ""
    @State private var exportedURL: URL?

    init(recorder: RecorderEngine) {
        self.recorder = recorder
        self.editor = recorder.aiEditor
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, maxWidth: 320)
            detail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.refresh(dir: recorder.recordingsDirectory) }
        .onReceive(NotificationCenter.default.publisher(for: .lsShowVideos)) { _ in
            model.selected = nil
            model.refresh(dir: recorder.recordingsDirectory)
        }
        .onChange(of: model.selected) { _, item in
            session?.player.pause()
            errorText = ""
            exportedURL = nil
            guard let item else { session = nil; return }
            let s = EditSession(url: item.url)
            session = s
            Task { await s.load() }
        }
        .onChange(of: editor.isPolishing) { _, polishing in
            if !polishing { model.refresh(dir: recorder.recordingsDirectory) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Videos")
                    .font(.title3.bold())
                Spacer()
                Button {
                    model.refresh(dir: recorder.recordingsDirectory)
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            if model.items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("No videos yet.\nHit Record and make one!")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(model.items, selection: $model.selected) { item in
                    HStack(spacing: 10) {
                        Group {
                            if let thumb = model.thumbnails[item.url] {
                                Image(nsImage: thumb).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.quaternary)
                            }
                        }
                        .frame(width: 84, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                if item.isPolished {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                }
                                Text(item.isPolished ? "Polished" : "Recording")
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(item)
                    .padding(.vertical, 3)
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = model.selected, let session {
            HStack(alignment: .top, spacing: 0) {
                // Player + segment strip
                VStack(alignment: .leading, spacing: 10) {
                    PlayerView(player: session.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    segmentStrip(session)
                    transcriptPanel(session)

                    HStack {
                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                        if session.hasCuts {
                            Text("\(Int(session.keptDuration))s of \(Int(session.duration))s kept")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: { Label("Show in Finder", systemImage: "folder") }
                        Button(role: .destructive) {
                            confirmDelete = item
                        } label: { Image(systemName: "trash") }
                    }
                }
                .padding(14)

                // Loom-style AI card
                aiPanel(for: item)
                    .frame(width: 270)
                    .padding([.top, .trailing, .bottom], 14)
            }
            .confirmationDialog(
                "Move this video to the Trash?",
                isPresented: Binding(get: { confirmDelete != nil },
                                     set: { if !$0 { confirmDelete = nil } })
            ) {
                Button("Move to Trash", role: .destructive) {
                    if let item = confirmDelete {
                        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                        confirmDelete = nil
                        model.refresh(dir: recorder.recordingsDirectory)
                    }
                }
            }
        } else {
            VStack {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("Pick a video on the left")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Filmstrip timeline: thumbnails under keep/cut segments. Click a piece
    /// to flip it; drag the ends to trim the start/finish.
    private func segmentStrip(_ session: EditSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let dur = max(session.duration, 0.1)
                ZStack(alignment: .leading) {
                    // Filmstrip background
                    HStack(spacing: 0) {
                        ForEach(Array(session.filmstrip.enumerated()), id: \.offset) { _, img in
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: w / CGFloat(max(session.filmstrip.count, 1)),
                                       height: 44)
                                .clipped()
                        }
                    }
                    .frame(width: w, height: 44)

                    // Keep/cut overlays
                    ForEach(session.segments) { seg in
                        let x = w * seg.start / dur
                        let sw = max(4, w * seg.length / dur)
                        Rectangle()
                            .fill(seg.kept ? Color.clear : Color.black.opacity(0.62))
                            .overlay(
                                Rectangle()
                                    .strokeBorder(
                                        seg.kept ? Color.accentColor : Color.clear,
                                        lineWidth: session.hasCuts ? 2 : 0
                                    )
                            )
                            .overlay(alignment: .center) {
                                if !seg.kept, sw > 22 {
                                    Image(systemName: "scissors")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                            .frame(width: sw, height: 44)
                            .offset(x: x)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await session.toggle(seg.id) } }
                            .help(String(format: "%@ %.1fs–%.1fs — click to %@",
                                         seg.kept ? "Keeping" : "Cut",
                                         seg.start, seg.end,
                                         seg.kept ? "cut it" : "bring it back"))
                    }

                    // Trim handles at both ends
                    trimHandle(session, edge: .leading, width: w, duration: dur)
                    trimHandle(session, edge: .trailing, width: w, duration: dur)
                }
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Click a piece to cut it or bring it back · drag the yellow ends to trim")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private enum TrimEdge { case leading, trailing }

    @State private var trimDrag: CGFloat = 0

    private func trimHandle(_ session: EditSession, edge: TrimEdge,
                            width: CGFloat, duration: Double) -> some View {
        let isLeading = edge == .leading
        return RoundedRectangle(cornerRadius: 3)
            .fill(.yellow)
            .frame(width: 7, height: 44)
            .offset(x: isLeading ? max(0, trimDragFor(edge))
                                 : width - 7 + min(0, trimDragFor(edge)))
            .frame(maxWidth: .infinity, alignment: isLeading ? .leading : .trailing)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if edge == activeTrimEdge || activeTrimEdge == nil {
                            activeTrimEdge = edge
                            trimDrag = v.translation.width
                        }
                    }
                    .onEnded { v in
                        let dt = Double(abs(v.translation.width) / width) * duration
                        activeTrimEdge = nil
                        trimDrag = 0
                        Task {
                            if isLeading, v.translation.width > 0 {
                                await session.markCut(from: 0, to: dt)
                            } else if !isLeading, v.translation.width < 0 {
                                await session.markCut(from: duration - dt, to: duration)
                            }
                        }
                    }
            )
    }

    @State private var activeTrimEdge: TrimEdge?

    private func trimDragFor(_ edge: TrimEdge) -> CGFloat {
        activeTrimEdge == edge ? trimDrag : 0
    }

    /// Loom-style "edit by transcript": delete a sentence, the video cuts it.
    private func transcriptPanel(_ session: EditSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.isTranscribing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your words…").font(.caption)
                }
            } else if session.transcript.isEmpty {
                Button {
                    Task { await session.loadTranscript() }
                } label: {
                    Label("Edit by transcript", systemImage: "text.quote")
                }
                .font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(transcriptLines(session), id: \.start) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Text(String(format: "%d:%02d", Int(line.start) / 60, Int(line.start) % 60))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 32, alignment: .trailing)
                                Text(line.text)
                                    .font(.caption)
                                Spacer(minLength: 4)
                                Button {
                                    Task { await session.markCut(from: line.start, to: line.end) }
                                } label: {
                                    Image(systemName: "scissors")
                                }
                                .buttonStyle(.borderless)
                                .help("Cut this line from the video")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
    }

    /// Group word segments into readable lines for the transcript list.
    private func transcriptLines(_ session: EditSession) -> [(start: Double, end: Double, text: String)] {
        var lines: [(Double, Double, String)] = []
        var words: [String] = []
        var s: Double? = nil, e = 0.0
        for seg in session.transcript {
            if s == nil { s = seg.start }
            words.append(seg.text)
            e = seg.end
            if e - (s ?? e) >= 6 || words.count >= 14 {
                lines.append((s!, e, words.joined(separator: " ")))
                words = []; s = nil
            }
        }
        if let s, !words.isEmpty { lines.append((s, e, words.joined(separator: " "))) }
        return lines.map { (start: $0.0, end: $0.1, text: $0.2) }
    }

    private func aiPanel(for item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("LazyStudio AI", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.purple)

            if recorder.agents.isEmpty {
                Text("Connect an AI to edit your videos — it uses your existing subscription, no API keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Get Claude Code") {
                    NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
                }
                Button("Get Codex (ChatGPT)") {
                    NSWorkspace.shared.open(URL(string: "https://openai.com/codex")!)
                }
            } else {
                Picker("Editor brain", selection: $recorder.selectedAgentID) {
                    ForEach(recorder.agents) { agent in
                        Text(agent.displayName).tag(agent.id)
                    }
                }
                .onAppear {
                    if recorder.selectedAgentID.isEmpty {
                        recorder.selectedAgentID = recorder.agents.first?.id ?? ""
                    }
                }
                Button {
                    RecorderEngine.openLogin(for: recorder.selectedAgentID)
                } label: {
                    Label(
                        recorder.selectedAgentID == "codex"
                            ? "Log in with ChatGPT" : "Log in / check account",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .font(.caption)

                Divider()

                TextField("Tell the AI what you want…", text: $instruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Text("e.g. \"cut the first minute\", \"keep it under 2 minutes\", \"make the title funny\"")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    guard let agent = recorder.activeAgent, let session else { return }
                    let extra = instruction.isEmpty ? nil : instruction
                    errorText = ""
                    Task {
                        do {
                            let plan = try await editor.makePlan(
                                url: item.url, agent: agent, instruction: extra
                            )
                            await session.apply(keep: plan.keep)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Edit with AI", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(editor.isPolishing || session == nil)

                if editor.isPolishing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(editor.stage).font(.caption)
                    }
                }
                if !errorText.isEmpty {
                    Text(errorText).font(.caption2).foregroundStyle(.red)
                }

                if let session, session.hasCuts {
                    HStack {
                        Button {
                            Task {
                                do {
                                    let out = try await session.export()
                                    exportedURL = out
                                    model.refresh(dir: recorder.recordingsDirectory)
                                } catch { errorText = error.localizedDescription }
                            }
                        } label: {
                            Label(session.isExporting ? "Exporting…" : "Export video",
                                  systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isExporting)
                        Button("Undo all") { Task { await session.revert() } }
                            .disabled(session.isExporting)
                    }
                }

                // Post panel — everything you need to publish
                if !editor.lastTitle.isEmpty || exportedURL != nil {
                    Divider()
                    Text("Post it").font(.caption.bold())
                    if !editor.lastTitle.isEmpty {
                        Text(editor.lastTitle).font(.caption).textSelection(.enabled).lineLimit(3)
                        HStack {
                            Button("Copy title") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(editor.lastTitle, forType: .string)
                            }
                            Button("Copy description") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(editor.lastDescription, forType: .string)
                            }
                        }
                        .font(.caption)
                    }
                    if let exportedURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                        } label: { Label("Show edited video", systemImage: "folder") }
                        .font(.caption)
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://youtube.com/upload")!)
                    } label: { Label("Open YouTube upload", systemImage: "arrow.up.right.square") }
                    .font(.caption)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.purple.opacity(0.25)))
    }
}
