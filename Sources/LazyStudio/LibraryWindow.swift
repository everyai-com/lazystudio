import SwiftUI
import AppKit
import AVFoundation

/// Legacy standalone window (kept for compatibility) — the real UI lives in
/// LibraryView inside the app shell.
@MainActor
enum LibraryWindow {
    static func show(recorder: RecorderEngine) {
        MainWindow.showVideos()
    }
}

struct VideoItem: Identifiable, Hashable {
    let url: URL
    let date: Date
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isPolished: Bool {
        url.lastPathComponent.contains("polished") || url.lastPathComponent.contains("edited")
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var selected: VideoItem?
    @Published var thumbnails: [URL: NSImage] = [:]
    @Published var durations: [URL: Double] = [:]

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
        for item in items where thumbnails[item.url] == nil {
            loadMeta(item.url)
        }
    }

    private func loadMeta(_ url: URL) {
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let dur = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 640, height: 640)
            let cg = try? await gen.image(at: CMTime(seconds: min(0.4, dur / 2), preferredTimescale: 600)).image
            await MainActor.run { [weak self] in
                self?.durations[url] = dur
                if let cg { self?.thumbnails[url] = NSImage(cgImage: cg, size: .zero) }
            }
        }
    }
}

struct LibraryView: View {
    /// The session agents (MCP) talk to — mirrors what the UI shows.
    @MainActor static var activeSession: EditSession?
    @MainActor static func adopt(session: EditSession) {
        activeSession = session
        NotificationCenter.default.post(name: .lsAdoptSession, object: session)
    }

    @ObservedObject var recorder: RecorderEngine
    @ObservedObject var editor: AIEditor
    @StateObject private var model = LibraryModel()
    @State private var session: EditSession?
    @State private var confirmDelete: VideoItem?
    @State private var errorText = ""
    @State private var exportedURL: URL?
    @State private var adoptedSession: EditSession?
    @AppStorage("burnCaptions") private var burnCaptions = true
    @AppStorage("socialExport") private var socialExport = true
    @AppStorage("captionStyle") private var captionStyle = EditSession.CaptionStyle.boldPop.rawValue
    @AppStorage("captionSize") private var captionSize = "M"
    @State private var editingLineStart: Double?
    @State private var editingText = ""

    private var styleBlurb: String {
        switch EditSession.CaptionStyle(rawValue: captionStyle) ?? .boldPop {
        case .boldPop: "Dark rounded box, words pop in as spoken — the TikTok classic."
        case .hormozi: "Big bold text, the spoken word flashes yellow — Hormozi karaoke."
        case .outline: "Bold white with a thick black outline — works on any background."
        case .pill: "Black text on a yellow pill — the CapCut viral look."
        case .minimal: "Small, clean, lowercase — quiet captions for calm videos."
        }
    }

    init(recorder: RecorderEngine) {
        self.recorder = recorder
        self.editor = recorder.aiEditor
    }

    var body: some View {
        Group {
            if let item = model.selected, let session {
                editorScreen(item: item, session: session)
            } else {
                gridView
            }
        }
        .onAppear { model.refresh(dir: recorder.recordingsDirectory) }
        .onReceive(NotificationCenter.default.publisher(for: .lsShowVideos)) { _ in
            model.selected = nil
            model.refresh(dir: recorder.recordingsDirectory)
            // Fresh recording: drop straight into its editor.
            if let newest = model.items.first(where: { !$0.isPolished }) {
                model.selected = newest
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lsAdoptSession)) { note in
            // An agent (via MCP) started editing a video — show it.
            guard let s = note.object as? EditSession else { return }
            adoptedSession = s
            model.refresh(dir: recorder.recordingsDirectory)
            model.selected = model.items.first { $0.url == s.url }
        }
        .onChange(of: model.selected) { _, item in
            session?.player.pause()
            errorText = ""
            exportedURL = nil
            guard let item else { session = nil; Self.activeSession = nil; return }
            if let adopted = adoptedSession, adopted.url == item.url {
                session = adopted
                Self.activeSession = adopted
                adoptedSession = nil
                return
            }
            // The chat editor may already hold this video's timeline —
            // reuse it so AI edits made there are visible here.
            if let live = Self.activeSession, live.url == item.url {
                session = live
                return
            }
            let s = EditSession(url: item.url)
            session = s
            Self.activeSession = s
            Task { await s.load() }
        }
        .onChange(of: editor.isPolishing) { _, polishing in
            if !polishing { model.refresh(dir: recorder.recordingsDirectory) }
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
                    if model.selected == item { model.selected = nil }
                    model.refresh(dir: recorder.recordingsDirectory)
                }
            }
        }
    }

    // MARK: - Library grid (Loom-style)

    private var gridView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("My Videos")
                        .font(.title2.bold())
                    Spacer()
                    Button {
                        model.refresh(dir: recorder.recordingsDirectory)
                    } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                }
                if model.items.isEmpty {
                    // Empty state is rare — a touch of delight is allowed here.
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Theme.accent.opacity(0.1))
                                .frame(width: 84, height: 84)
                            Image(systemName: "film.stack")
                                .font(.system(size: 36))
                                .foregroundStyle(Theme.brandGradient)
                                .symbolEffect(.pulse, options: .repeat(3))
                        }
                        Text("No videos yet")
                            .font(.title3.bold())
                        Text("Hit Record — the AI takes it from there.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)],
                              spacing: 16) {
                        ForEach(model.items) { item in
                            videoCard(item)
                        }
                    }
                }
            }
            .padding(18)
        }
        .studioStage()
    }

    private func videoCard(_ item: VideoItem) -> some View {
        VideoCard(item: item, model: model)
    }

    // MARK: - Editor screen

    private struct VideoCard: View {
        let item: VideoItem
        @ObservedObject var model: LibraryModel
        @State private var hovering = false

        var body: some View {
            Button {
                model.selected = item
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Group {
                            if let thumb = model.thumbnails[item.url] {
                                Image(nsImage: thumb).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.quaternary)
                                    .overlay(Image(systemName: "film")
                                        .foregroundStyle(.tertiary))
                            }
                        }
                        .frame(height: 124)
                        .clipped()

                        // Hover: darken + play affordance
                        Rectangle()
                            .fill(.black.opacity(hovering ? 0.35 : 0))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.white)
                            .opacity(hovering ? 1 : 0)
                            .scaleEffect(hovering ? 1 : 0.7)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let d = model.durations[item.url], d > 0 {
                            Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))
                                .font(.caption2.bold().monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.7), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if item.isPolished {
                            Label("AI edited", systemImage: "sparkles")
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.brandGradient, in: Capsule())
                                .foregroundStyle(.white)
                                .padding(6)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(hovering ? Theme.accent.opacity(0.6) : .white.opacity(0.09),
                                      lineWidth: hovering ? 1.5 : 1)
                )
                .shadow(color: hovering ? Theme.accent.opacity(0.25) : .black.opacity(0.3),
                        radius: hovering ? 14 : 8, y: 4)
                .scaleEffect(hovering ? 1.015 : 1)
                // Hover fires constantly — keep it fast, no bounce.
                .animation(.lsSnappy(0.15), value: hovering)
            }
            .buttonStyle(PressableStyle())
            .onHover { hovering = $0 }
        }
    }

    private func editorScreen(item: VideoItem, session: EditSession) -> some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Button {
                    model.selected = nil
                } label: {
                    Label("Library", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                if session.hasCuts {
                    Text("\(Int(session.keptDuration))s of \(Int(session.duration))s kept")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: { Image(systemName: "folder") }
                .help("Show in Finder")
                Button(role: .destructive) {
                    confirmDelete = item
                } label: { Image(systemName: "trash") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                // Stage: dark background so any format (portrait, square,
                // widescreen) shows at its true shape, letterboxed.
                VStack(spacing: 10) {
                    PlayerView(player: session.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .overlay {
                            // Live subtitle preview: picking a style shows it
                            // right here, no export needed.
                            if burnCaptions {
                                CaptionPreviewOverlay(session: session)
                                    .allowsHitTesting(false)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    segmentStrip(session)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right rail: AI + what got cut + transcript
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        aiPanel(for: item)
                        if session.hasCuts { removedPanel(session) }
                        transcriptPanel(session)
                    }
                    .padding(12)
                }
                .frame(width: 290)
                .background(.white.opacity(0.03))
            }
        }
        .studioStage()
    }

    /// "What the AI removed" — every cut with its reason, restorable.
    private func removedPanel(_ session: EditSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What got cut", systemImage: "scissors")
                .font(.subheadline.bold())
            ForEach(session.segments.filter { !$0.kept }) { seg in
                HStack(spacing: 6) {
                    Text(String(format: "%d:%02d–%d:%02d",
                                Int(seg.start) / 60, Int(seg.start) % 60,
                                Int(seg.end) / 60, Int(seg.end) % 60))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(seg.note ?? "cut")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                    Spacer()
                    Button("Keep") {
                        Task { await session.toggle(seg.id) }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(12)
        .lsCard(radius: 12)
    }

    // MARK: - Segment strip (filmstrip + overlays + trim handles)

    private func segmentStrip(_ session: EditSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                let dur = max(session.duration, 0.1)
                ZStack(alignment: .leading) {
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

                    ForEach(session.segments) { seg in
                        let x = w * seg.start / dur
                        let sw = max(4, w * seg.length / dur)
                        Rectangle()
                            .fill(seg.kept ? Color.clear : Color.black.opacity(0.62))
                            // Cut/keep is a state change — ease it, don't jump.
                            .animation(.lsSnappy(0.2), value: seg.kept)
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
                            .contextMenu {
                                Button(seg.kept ? "Cut this piece" : "Bring it back") {
                                    Task { await session.toggle(seg.id) }
                                }
                                Button("Split here") {
                                    session.seek(toSource: (seg.start + seg.end) / 2)
                                    Task { await session.splitAtPlayhead() }
                                }
                                Button("Play from here") {
                                    session.seek(toSource: seg.start)
                                    session.player.play()
                                }
                            }
                            .help(String(format: "%@ %.1fs–%.1fs — click to %@",
                                         seg.kept ? "Keeping" : "Cut",
                                         seg.start, seg.end,
                                         seg.kept ? "cut it" : "bring it back"))
                    }

                    trimHandle(session, edge: .leading, width: w, duration: dur)
                    trimHandle(session, edge: .trailing, width: w, duration: dur)

                    // Playhead
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: 44)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .offset(x: w * session.playhead / dur - 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Seek bar: click or drag anywhere to jump. Separate from the
            // strip so seeking never fights with cut-toggling.
            GeometryReader { geo in
                let w = geo.size.width
                let dur = max(session.duration, 0.1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(3, w * session.playhead / dur))
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            session.seek(toSource: Double(v.location.x / w) * dur)
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Button {
                    session.togglePlay()
                } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])
                Button {
                    Task { await session.splitAtPlayhead() }
                } label: { Image(systemName: "square.split.diagonal") }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: [])
                .help("Split at playhead (S) — then click a piece to cut it")
                Button {
                    Task { await session.cutLeftOfPlayhead() }
                } label: { Image(systemName: "arrow.left.to.line.compact") }
                .buttonStyle(.borderless)
                .keyboardShortcut("q", modifiers: [])
                .help("Cut everything left of the playhead to the last boundary (Q)")
                Button {
                    Task { await session.cutRightOfPlayhead() }
                } label: { Image(systemName: "arrow.right.to.line.compact") }
                .buttonStyle(.borderless)
                .keyboardShortcut("w", modifiers: [])
                .help("Cut from the playhead to the next boundary (W)")

                // Hidden speed/step keys: L speed, K pause, arrows step.
                Group {
                    Button("") { session.cyclePlaybackSpeed() }
                        .keyboardShortcut("l", modifiers: [])
                    Button("") { session.player.pause() }
                        .keyboardShortcut("k", modifiers: [])
                    Button("") { session.nudge(by: -1.0 / 30.0) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { session.nudge(by: 1.0 / 30.0) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { session.nudge(by: -5) }
                        .keyboardShortcut(.leftArrow, modifiers: .shift)
                    Button("") { session.nudge(by: 5) }
                        .keyboardShortcut(.rightArrow, modifiers: .shift)
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                Button {
                    Task { await session.undo() }
                } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!session.canUndo)
                .help("Undo (⌘Z)")
                Button {
                    Task { await session.redo() }
                } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!session.canRedo)
                .help("Redo (⇧⌘Z)")
                Text(String(format: "%d:%02d / %d:%02d",
                            Int(session.playhead) / 60, Int(session.playhead) % 60,
                            Int(session.duration) / 60, Int(session.duration) % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Space play · S split · click a piece to cut/restore · ⌘Z undo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private enum TrimEdge { case leading, trailing }
    @State private var trimDrag: CGFloat = 0
    @State private var activeTrimEdge: TrimEdge?

    private func trimDragFor(_ edge: TrimEdge) -> CGFloat {
        activeTrimEdge == edge ? trimDrag : 0
    }

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

    // MARK: - Transcript

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
                Label("Transcript", systemImage: "text.quote")
                    .font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(transcriptLines(session), id: \.start) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(String(format: "%d:%02d", Int(line.start) / 60, Int(line.start) % 60))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, alignment: .trailing)
                            if editingLineStart == line.start {
                                TextField("Subtitle text", text: $editingText, axis: .vertical)
                                    .font(.caption)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        session.replaceTranscript(
                                            from: line.start, to: line.end, with: editingText)
                                        editingLineStart = nil
                                    }
                                Button {
                                    session.replaceTranscript(
                                        from: line.start, to: line.end, with: editingText)
                                    editingLineStart = nil
                                } label: { Image(systemName: "checkmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .help("Save — subtitles use your words")
                            } else {
                                Text(line.text)
                                    .font(.caption)
                                    .onTapGesture { session.seek(toSource: line.start) }
                                    .help("Click to jump here")
                                Spacer(minLength: 4)
                                Button {
                                    editingText = line.text
                                    editingLineStart = line.start
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Fix the words — subtitles and captions use your edit")
                                Button {
                                    Task { await session.markCut(from: line.start, to: line.end) }
                                } label: {
                                    Image(systemName: "scissors")
                                }
                                .buttonStyle(.borderless)
                                .help("Cut this line from the video")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(12)
        .lsCard(radius: 12)
    }

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

    // MARK: - AI panel

    private func aiPanel(for item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("LazyStudio AI", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(Theme.accent)

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
                let loggedIn = recorder.agentLoggedIn[recorder.selectedAgentID] ?? true
                HStack(spacing: 6) {
                    Circle()
                        .fill(loggedIn ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(loggedIn ? "Connected — ready to edit" : "Not logged in yet")
                        .font(.caption)
                        .foregroundStyle(loggedIn ? .secondary : .primary)
                }
                if !loggedIn {
                    Button {
                        RecorderEngine.openLogin(for: recorder.selectedAgentID)
                    } label: {
                        Label(recorder.selectedAgentID == "codex"
                              ? "Log in with ChatGPT" : "Log in",
                              systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Finish the login in Terminal, then come back — this turns green by itself.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                // One AI editing home: the chat. This jumps there with this
                // exact video and timeline — no second, worse edit box here.
                Button {
                    NotificationCenter.default.post(name: .lsOpenChat, object: item.url)
                } label: {
                    Label("Edit with AI", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(session == nil)
                Text("Opens the AI editor — chat your changes, watch them land live.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                // One-click tighten for the impatient — no chat needed.
                Button {
                    guard let agent = recorder.activeAgent, let session else { return }
                    errorText = ""
                    Task {
                        do {
                            let plan = try await editor.makePlan(url: item.url, agent: agent)
                            await session.apply(keep: plan.keep, cuts: plan.cuts)
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Quick tighten", systemImage: "bolt")
                        .frame(maxWidth: .infinity)
                }
                .disabled(editor.isPolishing || session == nil || recorder.activeAgent == nil)

                if editor.isPolishing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(editor.stage).font(.caption)
                    }
                }
                if !errorText.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                        Text(errorText)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                // Export is useful even with zero cuts — burning subtitles or
                // making a social-sized file is reason enough.
                if let session {
                    Toggle(isOn: $burnCaptions) {
                        Label("Stylish subtitles in the video", systemImage: "captions.bubble")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Text("Bold, punchy captions burned in — plus .srt/.vtt files for YouTube either way.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if burnCaptions {
                        // Wrapping chips, not a segmented control — five styles
                        // never fit 290pt side-by-side.
                        let columns = [GridItem(.adaptive(minimum: 78), spacing: 6)]
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                            ForEach(EditSession.CaptionStyle.allCases) { s in
                                let selected = captionStyle == s.rawValue
                                Button {
                                    captionStyle = s.rawValue
                                } label: {
                                    Text(s.label)
                                        .font(.caption2.weight(selected ? .bold : .regular))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(
                                            selected ? Theme.accent.opacity(0.35) : Color.white.opacity(0.07),
                                            in: Capsule()
                                        )
                                        .overlay(Capsule().strokeBorder(
                                            selected ? Theme.accent : .clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text(styleBlurb)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Text("Size").font(.caption2).foregroundStyle(.secondary)
                            Picker("", selection: $captionSize) {
                                Text("Small").tag("S")
                                Text("Medium").tag("M")
                                Text("Large").tag("L")
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.mini)
                            .labelsHidden()
                        }
                    }
                    Toggle(isOn: $socialExport) {
                        Label("Optimized for social (1080p)", systemImage: "sparkles.tv")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Text("1080p H.264 — what social platforms want; sharper after their re-compression, much faster uploads.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            Task {
                                do {
                                    let out = try await session.export(burnCaptions: burnCaptions, social: socialExport)
                                    exportedURL = out
                                    model.refresh(dir: recorder.recordingsDirectory)
                                    // Nudge when a long export finishes in the background.
                                    NSSound(named: "Glass")?.play()
                                    NSApp.requestUserAttention(.informationalRequest)
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
                    if session.isExporting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Exporting — you can keep working…").font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Unmissable "here's your file" card the moment export lands.
                    if let exportedURL {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Saved to Movies ▸ LazyStudio").font(.caption.bold())
                                Text(exportedURL.lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                                } label: {
                                    Label("Show in Finder", systemImage: "folder")
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

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
                        HStack {
                            if !editor.lastLinkedIn.isEmpty {
                                Button("Copy LinkedIn post") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(editor.lastLinkedIn, forType: .string)
                                }
                            }
                            if !editor.lastTweet.isEmpty {
                                Button("Copy tweet") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(editor.lastTweet, forType: .string)
                                }
                            }
                        }
                        .font(.caption)
                    }
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://youtube.com/upload")!)
                    } label: { Label("Open YouTube upload", systemImage: "arrow.up.right.square") }
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .lsCard(radius: 12)
    }
}

/// Live rendering of the burned-subtitle styles over the preview player —
/// same blocks, same pacing, same colors as the real export.
struct CaptionPreviewOverlay: View {
    @ObservedObject var session: EditSession
    @AppStorage("captionStyle") private var styleRaw = EditSession.CaptionStyle.boldPop.rawValue
    // Read so the preview redraws instantly when the size chip changes.
    @AppStorage("captionSize") private var sizeRaw = "M"

    var body: some View {
        // Find where the letterboxed video really is, and pin the caption
        // 7% up from ITS bottom edge — exactly where the export burns it.
        GeometryReader { geo in
            let style = EditSession.CaptionStyle(rawValue: styleRaw) ?? .boldPop
            let vs = session.videoSize
            let scale = min(geo.size.width / vs.width, geo.size.height / vs.height)
            let fitted = CGSize(width: vs.width * scale, height: vs.height * scale)
            let bottomInset = (geo.size.height - fitted.height) / 2 + fitted.height * 0.07

            if let cap = session.liveCaption(at: session.playhead) {
                let visible = cap.words.filter { !style.popIn || $0.spoken }
                if !visible.isEmpty {
                    VStack {
                        Spacer()
                        text(for: visible, style: style, videoHeight: fitted.height)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, style.boxColor != nil ? 12 : 0)
                            .padding(.vertical, style.boxColor != nil ? 6 : 0)
                            .background {
                                if let bg = style.boxColor {
                                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: bg))
                                }
                            }
                            .frame(maxWidth: fitted.width * 0.86)
                            .padding(.bottom, bottomInset)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func text(for words: [(text: String, spoken: Bool, current: Bool)],
                      style: EditSession.CaptionStyle, videoHeight: CGFloat) -> some View {
        let joined = words.reduce(Text("")) { acc, w in
            let color: Color = w.current && style.highlight != nil
                ? Color(nsColor: style.highlight!) : Color(nsColor: style.textColor)
            let piece = Text(w.text).foregroundColor(color)
            return acc == Text("") ? piece : acc + Text(" ") + piece
        }
        // Same proportions as the burn: fraction of video height × user size.
        let size = max(9, videoHeight * style.sizeFactor * EditSession.CaptionStyle.sizeMultiplier)
        return joined
            .font(.system(size: size, weight: style.weight == .heavy ? .heavy : .semibold))
            .shadow(color: style.strokes ? .black : .clear, radius: 1, x: 1, y: 1)
            .shadow(color: style.strokes ? .black : .clear, radius: 1, x: -1, y: -1)
    }
}
