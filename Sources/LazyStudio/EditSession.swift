import Foundation
@preconcurrency import AVFoundation
import AppKit

/// The recording IS the project: a list of keep/cut segments over the raw
/// file. The AI drafts the list, clicks revise it, nothing is destructive
/// until Export. Preview plays the live composition of kept segments.
@MainActor
final class EditSession: ObservableObject {
    struct Segment: Identifiable {
        let id = UUID()
        var start: Double
        var end: Double
        var kept: Bool
        /// Why the AI cut this piece ("silence", "retake"…), if it did.
        var note: String?
        var length: Double { end - start }
    }

    let url: URL
    let player = AVPlayer()
    @Published var duration: Double = 0
    /// Natural pixel size — the preview uses it to find where the video
    /// actually sits inside the letterboxed player.
    @Published var videoSize = CGSize(width: 16, height: 9)
    @Published var segments: [Segment] = []
    @Published var isExporting = false
    @Published var filmstrip: [NSImage] = []
    @Published var transcript: [TranscriptSegment] = []
    @Published var isTranscribing = false
    /// Playhead position in SOURCE time (pre-cut coordinates for the strip).
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    private var timeObserver: Any?

    var hasCuts: Bool { segments.contains { !$0.kept } }
    var keptRanges: [AIEditor.EditPlan.Range] {
        segments.filter(\.kept).map { .init(start: $0.start, end: $0.end) }
    }
    var keptDuration: Double { segments.filter(\.kept).reduce(0) { $0 + $1.length } }

    init(url: URL) { self.url = url }

    func load() async {
        let asset = AVURLAsset(url: url)
        duration = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let sz = try? await track.load(.naturalSize), sz.width > 0, sz.height > 0 {
            videoSize = sz
        }
        segments = [Segment(start: 0, end: max(duration, 0.1), kept: true)]
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        loadFilmstrip()
        installPlayheadObserver()
        // Auto-transcript: subtitles are just there, no button hunting.
        Task { await loadTranscript() }
    }

    // MARK: - Playhead / seek / play-pause

    private func installPlayheadObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.playhead = self.sourceTime(fromPlayer: t.seconds)
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    /// Player time (composition skips cuts) → source-video time.
    func sourceTime(fromPlayer t: Double) -> Double {
        guard hasCuts else { return t }
        var remaining = t
        for r in keptRanges {
            let len = r.end - r.start
            if remaining <= len { return r.start + remaining }
            remaining -= len
        }
        return duration
    }

    /// Source-video time → player time; nil if that moment is cut.
    func playerTime(fromSource t: Double) -> Double? {
        guard hasCuts else { return t }
        var acc = 0.0
        for r in keptRanges {
            if t >= r.start && t <= r.end { return acc + (t - r.start) }
            if t < r.start { return acc }   // inside a cut → snap to next kept
            acc += r.end - r.start
        }
        return nil
    }

    /// Click anywhere on the strip to jump there.
    func seek(toSource t: Double) {
        let target = playerTime(fromSource: min(max(t, 0), duration)) ?? 0
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        playhead = t
    }

    /// Spacebar.
    func togglePlay() {
        if player.rate != 0 { player.pause() } else { player.play() }
    }

    /// A row of thumbnails across the whole video, drawn under the strip.
    private func loadFilmstrip(count: Int = 14) {
        let url = url, duration = duration
        guard duration > 0 else { return }
        Task.detached(priority: .utility) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 160)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            var images: [NSImage] = []
            for i in 0..<count {
                let t = duration * (Double(i) + 0.5) / Double(count)
                if let cg = try? await gen.image(
                    at: CMTime(seconds: t, preferredTimescale: 600)
                ).image {
                    images.append(NSImage(cgImage: cg, size: .zero))
                }
            }
            let final = images
            await MainActor.run { [weak self] in self?.filmstrip = final }
        }
    }

    /// Mark [from, to] as cut, splitting whatever segments it crosses.
    /// Used by the trim handles and the transcript's per-line delete.
    func markCut(from s: Double, to e: Double) async {
        let s = max(0, min(s, duration)), e = max(s, min(e, duration))
        guard e - s > 0.05 else { return }
        pushUndo()
        var out: [Segment] = []
        for seg in segments {
            if seg.end <= s || seg.start >= e { out.append(seg); continue }
            if seg.start < s { out.append(Segment(start: seg.start, end: s, kept: seg.kept)) }
            out.append(Segment(start: max(seg.start, s), end: min(seg.end, e), kept: false))
            if seg.end > e { out.append(Segment(start: e, end: seg.end, kept: seg.kept)) }
        }
        segments = out.filter { $0.length > 0.05 }
        await rebuildPreview()
    }

    /// On-device transcript so lines can be deleted like text (Loom-style).
    func loadTranscript() async {
        guard transcript.isEmpty, !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }
        transcript = (try? await Transcriber.transcribe(url: url)) ?? []
    }

    /// Turn an AI keep-plan into visible kept/cut segments, labeling each
    /// cut with the AI's reason so the editor can show WHY.
    func apply(keep: [AIEditor.EditPlan.Range], cuts: [AIEditor.EditPlan.Cut]? = nil) async {
        pushUndo()
        var segs: [Segment] = []
        var cursor = 0.0
        func reason(for s: Double, _ e: Double) -> String? {
            let mid = (s + e) / 2
            return cuts?.first { mid >= $0.start && mid <= $0.end }?.reason
        }
        for r in keep.sorted(by: { $0.start < $1.start }) {
            let s = max(cursor, min(r.start, duration))
            let e = max(s, min(r.end, duration))
            if s > cursor + 0.05 {
                segs.append(Segment(start: cursor, end: s, kept: false, note: reason(for: cursor, s)))
            }
            if e > s { segs.append(Segment(start: s, end: e, kept: true)) }
            cursor = max(cursor, e)
        }
        if cursor < duration - 0.05 {
            segs.append(Segment(start: cursor, end: duration, kept: false, note: reason(for: cursor, duration)))
        }
        if !segs.isEmpty { segments = segs }
        await rebuildPreview()
    }

    // MARK: - Undo / redo (value-type snapshots — cheap, reliable)

    @Published var canUndo = false
    @Published var canRedo = false
    private var undoStack: [[Segment]] = []
    private var redoStack: [[Segment]] = []

    private func pushUndo() {
        undoStack.append(segments)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() async {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(segments)
        segments = prev
        canUndo = !undoStack.isEmpty
        canRedo = true
        await rebuildPreview()
    }

    func redo() async {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(segments)
        segments = next
        canUndo = true
        canRedo = !redoStack.isEmpty
        await rebuildPreview()
    }

    /// Split the segment under the playhead (OpenCut/CapCut "S") — then any
    /// piece can be cut or kept on its own.
    func splitAtPlayhead() async {
        let t = playhead
        guard let i = segments.firstIndex(where: { t > $0.start + 0.15 && t < $0.end - 0.15 })
        else { return }
        pushUndo()
        let seg = segments[i]
        segments[i] = Segment(start: seg.start, end: t, kept: seg.kept, note: seg.note)
        segments.insert(Segment(start: t, end: seg.end, kept: seg.kept, note: seg.note), at: i + 1)
        await rebuildPreview()
    }

    /// OpenCut "Q": cut everything from the previous boundary to the playhead.
    /// Park the playhead where the good take resumes, hit Q, dead air gone.
    func cutLeftOfPlayhead() async {
        let t = playhead
        guard let i = segments.firstIndex(where: { t > $0.start + 0.15 && t < $0.end - 0.15 })
        else { return }
        pushUndo()
        let seg = segments[i]
        segments[i] = Segment(start: seg.start, end: t, kept: false, note: "cut to here")
        segments.insert(Segment(start: t, end: seg.end, kept: seg.kept, note: seg.note), at: i + 1)
        await rebuildPreview()
    }

    /// OpenCut "W": cut from the playhead to the next boundary.
    func cutRightOfPlayhead() async {
        let t = playhead
        guard let i = segments.firstIndex(where: { t > $0.start + 0.15 && t < $0.end - 0.15 })
        else { return }
        pushUndo()
        let seg = segments[i]
        segments[i] = Segment(start: seg.start, end: t, kept: seg.kept, note: seg.note)
        segments.insert(Segment(start: t, end: seg.end, kept: false, note: "cut from here"), at: i + 1)
        await rebuildPreview()
    }

    /// J/K/L-style speed control: L cycles 1×→1.5×→2×, K pauses.
    func cyclePlaybackSpeed() {
        let next: Float = switch player.rate {
        case 0..<1.2: 1.5
        case 1.2..<1.8: 2.0
        default: 1.0
        }
        player.rate = next
    }

    func nudge(by seconds: Double) {
        seek(toSource: playhead + seconds)
    }

    /// Click a segment to cut it or bring it back.
    func toggle(_ id: Segment.ID) async {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        segments[i].kept.toggle()
        await rebuildPreview()
    }

    func revert() async {
        segments = [Segment(start: 0, end: max(duration, 0.1), kept: true)]
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: url)))
    }

    private func rebuildPreview() async {
        let asset = AVURLAsset(url: url)
        guard hasCuts else {
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            return
        }
        if let comp = try? await Self.composition(asset: asset, keep: keptRanges) {
            player.replaceCurrentItem(with: AVPlayerItem(asset: comp))
            player.play()
        }
    }

    static func composition(asset: AVURLAsset, keep: [AIEditor.EditPlan.Range]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var pairs: [(AVAssetTrack, AVMutableCompositionTrack)] = []
        for track in videoTracks + audioTracks {
            if let compTrack = composition.addMutableTrack(
                withMediaType: track.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                pairs.append((track, compTrack))
            }
        }
        var cursor = CMTime.zero
        for range in keep {
            let start = max(0, min(range.start, duration))
            let end = max(start, min(range.end, duration))
            guard end > start else { continue }
            let timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600)
            )
            for (src, dst) in pairs {
                try dst.insertTimeRange(timeRange, of: src, at: cursor)
            }
            cursor = cursor + timeRange.duration
        }
        return composition
    }

    /// Render exactly what the strip shows → "(edited).mp4" next to the raw
    /// file. Always writes an .srt; optionally burns styled subtitles in.
    func export(burnCaptions: Bool = false, social: Bool = false,
                to destination: URL? = nil) async throws -> URL {
        isExporting = true
        defer { isExporting = false }
        let comp = try await Self.composition(asset: AVURLAsset(url: url), keep: keptRanges)
        let output = destination ?? url.deletingPathExtension().appendingPathExtension("edited.mp4")
        try? FileManager.default.removeItem(at: output)
        // Export into a hidden temp file and move it into place when done —
        // a half-written mp4 sitting at the destination is a QuickTime
        // "file isn't compatible" error waiting for a double-click.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazystudio-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staging) }
        // Social: 1080p H.264 — retina captures are 4–5K wide and platforms
        // just re-compress them badly; a clean 1080p upload looks sharper on
        // YouTube/TikTok/Instagram and is a fraction of the size.
        let preset = social ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHighestQuality
        guard let exporter = AVAssetExportSession(
            asset: comp, presetName: preset
        ) else { throw AIEditor.PolishError.exportFailed }

        if burnCaptions, !transcript.isEmpty {
            exporter.videoComposition = try await captionComposition(for: comp)
        }
        try await exporter.export(to: staging, as: .mp4)
        do {
            try FileManager.default.moveItem(at: staging, to: output)
        } catch {
            // Cross-volume move can fail — fall back to copy.
            try FileManager.default.copyItem(at: staging, to: output)
        }

        // Sidecar captions for YouTube (.srt) and web players (.vtt) either way.
        if !transcript.isEmpty {
            let srt = AIEditor.srt(segments: transcript, keep: keptRanges)
            try? srt.write(to: output.deletingPathExtension().appendingPathExtension("srt"),
                           atomically: true, encoding: .utf8)
            // WebVTT is the same cue list with dot milliseconds and a header.
            let vtt = "WEBVTT\n\n" + srt.replacingOccurrences(
                of: #"(\d{2}:\d{2}:\d{2}),(\d{3})"#, with: "$1.$2", options: .regularExpression
            )
            try? vtt.write(to: output.deletingPathExtension().appendingPathExtension("vtt"),
                           atomically: true, encoding: .utf8)
        }
        return output
    }

    // MARK: - Tasteful burned-in subtitles

    /// The five caption looks that dominate social in 2026 — see export panel.
    enum CaptionStyle: String, CaseIterable, Identifiable {
        case boldPop   // dark rounded box, white heavy text, word pop-in (TikTok)
        case hormozi   // huge white + black stroke, active word yellow (karaoke)
        case outline   // classic bold white with thick black outline, no box
        case pill      // yellow pill background, black text (CapCut style)
        case minimal   // small clean lowercase, subtle, no animation

        var id: String { rawValue }
        var label: String {
            switch self {
            case .boldPop: "Bold Pop"
            case .hormozi: "Hormozi"
            case .outline: "Outline"
            case .pill: "Yellow Pill"
            case .minimal: "Minimal"
            }
        }
        var uppercased: Bool { self != .minimal }
        var weight: NSFont.Weight { self == .minimal ? .semibold : .heavy }
        var sizeFactor: CGFloat {
            switch self {
            case .hormozi: 0.055
            case .minimal: 0.032
            default: 0.045
            }
        }
        var strokes: Bool { self == .boldPop || self == .hormozi || self == .outline }
        var textColor: NSColor { self == .pill ? .black : .white }
        var boxColor: NSColor? {
            switch self {
            case .boldPop: NSColor.black.withAlphaComponent(0.55)
            case .pill: NSColor.systemYellow
            default: nil
            }
        }
        /// Words appear as they're spoken vs whole block at once.
        var popIn: Bool { self == .boldPop }
        /// Karaoke: the word being spoken flips to this color.
        var highlight: NSColor? { self == .hormozi ? .systemYellow : nil }

        static var current: CaptionStyle {
            CaptionStyle(rawValue: UserDefaults.standard.string(forKey: "captionStyle") ?? "") ?? .boldPop
        }

        /// User size choice (S/M/L) — scales both export burn and live preview.
        static var sizeMultiplier: CGFloat {
            switch UserDefaults.standard.string(forKey: "captionSize") {
            case "S": 0.75
            case "L": 1.3
            default: 1.0
            }
        }
    }

    /// Replace the spoken words between two source timestamps with new text —
    /// the new words share the same time span, spaced evenly. This is how
    /// "edit the subtitles" works without touching audio.
    func replaceTranscript(from start: Double, to end: Double, with text: String) {
        let newWords = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var kept = transcript.filter { $0.end <= start || $0.start >= end }
        guard !newWords.isEmpty else { transcript = kept; return }
        let span = max(end - start, 0.3)
        let per = span / Double(newWords.count)
        let inserted = newWords.enumerated().map { i, w in
            TranscriptSegment(start: start + per * Double(i),
                              end: start + per * Double(i + 1),
                              text: w)
        }
        kept.append(contentsOf: inserted)
        transcript = kept.sorted { $0.start < $1.start }
    }

    /// Map a source timestamp into the edited timeline (nil if cut).
    private func remap(_ t: Double) -> Double? {
        var offset = 0.0
        for r in keptRanges {
            if t >= r.start && t <= r.end { return offset + (t - r.start) }
            if t > r.end { offset += r.end - r.start }
        }
        return nil
    }

    struct CaptionWord { let start: Double; let text: String }
    struct CaptionBlock {
        let start: Double
        var end: Double
        let words: [CaptionWord]
    }

    /// What the caption looks like at this moment of playback — the editor
    /// overlays it live so picking a style shows instantly, before export.
    struct LiveCaption {
        /// (word, already spoken, is the word being spoken right now)
        let words: [(text: String, spoken: Bool, current: Bool)]
    }

    func liveCaption(at sourceT: Double) -> LiveCaption? {
        guard !transcript.isEmpty, let t = playerTime(fromSource: sourceT) else { return nil }
        guard let block = captionBlocks().first(where: { t >= $0.start && t < $0.end })
        else { return nil }
        let starts = block.words.map(\.start)
        return LiveCaption(words: block.words.enumerated().map { i, w in
            let next = i + 1 < starts.count ? starts[i + 1] : block.end
            return (w.text, w.start <= t, w.start <= t && t < next)
        })
    }

    /// Short 3–5 word blocks, like good social captions — not paragraphs.
    /// Splits on real pauses and sentence ends so blocks read naturally,
    /// and keeps per-word timing for the TikTok-style pop-in.
    func captionBlocks() -> [CaptionBlock] {
        var blocks: [CaptionBlock] = []
        var words: [CaptionWord] = []
        var s: Double?
        var e = 0.0
        func flush() {
            guard let bs = s, !words.isEmpty else { return }
            blocks.append(CaptionBlock(start: bs, end: max(e, bs + 0.9), words: words))
            words = []; s = nil
        }
        for seg in transcript {
            guard let rs = remap(seg.start), let re = remap(seg.end) else { continue }
            // A real pause ends the block — captions shouldn't linger over silence.
            if s != nil, rs - e > 0.8 { flush() }
            if s == nil { s = rs }
            let clean = seg.text.trimmingCharacters(in: .whitespaces)
            words.append(CaptionWord(
                start: rs,
                text: CaptionStyle.current.uppercased ? clean.uppercased() : clean
            ))
            e = re
            let endsSentence = seg.text.hasSuffix(".") || seg.text.hasSuffix("?")
                || seg.text.hasSuffix("!") || seg.text.hasSuffix(",")
            if words.count >= 5 || e - (s ?? e) >= 2.2 || endsSentence { flush() }
        }
        flush()
        // Never two blocks on screen at once.
        for i in blocks.indices.dropLast() where blocks[i].end > blocks[i + 1].start {
            blocks[i].end = blocks[i + 1].start
        }
        return blocks
    }

    private func captionComposition(for comp: AVMutableComposition) async throws -> AVMutableVideoComposition {
        let videoComp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: comp)
        let size = videoComp.renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let style = CaptionStyle.current
        let fontSize = max(18, size.height * style.sizeFactor * CaptionStyle.sizeMultiplier)
        let font = NSFont.systemFont(ofSize: fontSize, weight: style.weight)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor,
        ]
        if style.strokes {
            attrs[.strokeColor] = NSColor.black
            attrs[.strokeWidth] = -3.0
        }
        // Karaoke variant of the same word, in the highlight color.
        var highlightAttrs = attrs
        if let hi = style.highlight { highlightAttrs[.foregroundColor] = hi }
        let spaceW = ("  " as NSString).size(withAttributes: [.font: font]).width
        let lineH = fontSize * 1.35
        let maxLineW = size.width * 0.86
        let padX = fontSize * 0.7
        let padY = fontSize * 0.45

        func fade(_ from: Float, _ to: Float, at t: Double, dur: Double) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = to
            a.duration = dur
            a.beginTime = AVCoreAnimationBeginTimeAtZero + max(t, 0.001)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            return a
        }

        // CATextLayer silently renders nothing inside AVAssetExportSession, so
        // words are pre-rendered to bitmaps and shown via plain CALayers.
        func rasterize(_ string: String, _ attrs: [NSAttributedString.Key: Any]) -> (image: CGImage, size: CGSize)? {
            let str = NSAttributedString(string: string, attributes: attrs)
            var s = str.size()
            s = CGSize(width: ceil(s.width) + 8, height: ceil(s.height) + 8)
            let scale: CGFloat = 2
            guard let ctx = CGContext(
                data: nil, width: Int(s.width * scale), height: Int(s.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            str.draw(at: NSPoint(x: 4, y: 4))
            NSGraphicsContext.restoreGraphicsState()
            guard let img = ctx.makeImage() else { return nil }
            return (img, s)
        }

        for block in captionBlocks() {
            // Measure every word, wrap into up to two centered lines.
            let measured = block.words.map { w in
                (word: w, width: (w.text as NSString).size(withAttributes: attrs).width)
            }
            var lines: [[(word: CaptionWord, width: CGFloat)]] = [[]]
            var lineW: CGFloat = 0
            for m in measured {
                if lineW > 0, lineW + spaceW + m.width > maxLineW {
                    lines.append([]); lineW = 0
                }
                lines[lines.count - 1].append(m)
                lineW += (lineW > 0 ? spaceW : 0) + m.width
            }
            let lineWidths = lines.map { line in
                line.reduce(CGFloat(0)) { $0 + $1.width } + spaceW * CGFloat(max(0, line.count - 1))
            }
            let blockW = (lineWidths.max() ?? 0) + padX * 2
            let blockH = lineH * CGFloat(lines.count) + padY * 2

            // Container (a rounded backdrop when the style wants one)…
            let box = CALayer()
            box.frame = CGRect(x: (size.width - blockW) / 2, y: size.height * 0.07,
                               width: blockW, height: blockH)
            if let bg = style.boxColor {
                box.backgroundColor = bg.cgColor
                box.cornerRadius = min(blockH / 4, fontSize * 0.5)
            }
            box.opacity = 0
            box.add(fade(0, 1, at: block.start, dur: 0.12), forKey: "in")
            box.add(fade(1, 0, at: block.end, dur: 0.1), forKey: "out")
            parent.addSublayer(box)

            // …and each word pops in the moment it's spoken (TikTok-style).
            var wordIndex = 0
            for (li, line) in lines.enumerated() {
                var x = (blockW - lineWidths[li]) / 2
                // CALayer y grows upward: first line sits at the top.
                let y = blockH - padY - lineH * CGFloat(li + 1)
                for m in line {
                    defer { wordIndex += 1 }
                    guard let (img, imgSize) = rasterize(m.word.text, attrs) else { continue }
                    let text = CALayer()
                    text.contents = img
                    text.contentsScale = 2
                    // -4 offsets the rasterization padding so glyphs align.
                    let frame = CGRect(x: x - 4, y: y - 4 + (lineH - imgSize.height + 8) / 2,
                                       width: imgSize.width, height: imgSize.height)
                    text.frame = frame
                    text.opacity = 0
                    let inAt = style.popIn ? max(block.start, m.word.start) : block.start
                    text.add(fade(0, 1, at: inAt, dur: 0.08), forKey: "in")
                    text.add(fade(1, 0, at: block.end, dur: 0.1), forKey: "out")
                    box.addSublayer(text)

                    // Karaoke: yellow copy of the word on top while it's spoken.
                    if style.highlight != nil,
                       let (hiImg, _) = rasterize(m.word.text, highlightAttrs) {
                        let next = wordIndex + 1 < block.words.count
                            ? block.words[wordIndex + 1].start : block.end
                        let hi = CALayer()
                        hi.contents = hiImg
                        hi.contentsScale = 2
                        hi.frame = frame
                        hi.opacity = 0
                        hi.add(fade(0, 1, at: max(block.start, m.word.start), dur: 0.05), forKey: "in")
                        hi.add(fade(1, 0, at: next, dur: 0.08), forKey: "out")
                        box.addSublayer(hi)
                    }
                    x += m.width + spaceW
                }
            }
        }

        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent
        )
        return videoComp
    }
}
