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
    func export(burnCaptions: Bool = false) async throws -> URL {
        isExporting = true
        defer { isExporting = false }
        let comp = try await Self.composition(asset: AVURLAsset(url: url), keep: keptRanges)
        let output = url.deletingPathExtension().appendingPathExtension("edited.mp4")
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(
            asset: comp, presetName: AVAssetExportPresetHighestQuality
        ) else { throw AIEditor.PolishError.exportFailed }

        if burnCaptions, !transcript.isEmpty {
            exporter.videoComposition = try await captionComposition(for: comp)
        }
        try await exporter.export(to: output, as: .mp4)

        // Sidecar captions for YouTube either way.
        if !transcript.isEmpty {
            let srt = AIEditor.srt(segments: transcript, keep: keptRanges)
            try? srt.write(to: output.deletingPathExtension().appendingPathExtension("srt"),
                           atomically: true, encoding: .utf8)
        }
        return output
    }

    // MARK: - Tasteful burned-in subtitles

    /// Map a source timestamp into the edited timeline (nil if cut).
    private func remap(_ t: Double) -> Double? {
        var offset = 0.0
        for r in keptRanges {
            if t >= r.start && t <= r.end { return offset + (t - r.start) }
            if t > r.end { offset += r.end - r.start }
        }
        return nil
    }

    /// Short 3–4 word blocks, like good social captions — not paragraphs.
    private func captionBlocks() -> [(start: Double, end: Double, text: String)] {
        var blocks: [(Double, Double, String)] = []
        var words: [String] = []
        var s: Double?
        var e = 0.0
        for seg in transcript {
            guard let rs = remap(seg.start), let re = remap(seg.end) else { continue }
            if s == nil { s = rs }
            words.append(seg.text)
            e = re
            if words.count >= 4 || e - (s ?? e) >= 1.8 {
                blocks.append((s!, max(e, s! + 0.6), words.joined(separator: " ")))
                words = []; s = nil
            }
        }
        if let s, !words.isEmpty { blocks.append((s, max(e, s + 0.6), words.joined(separator: " "))) }
        return blocks.map { (start: $0.0, end: $0.1, text: $0.2.uppercased()) }
    }

    private func captionComposition(for comp: AVMutableComposition) async throws -> AVMutableVideoComposition {
        let videoComp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: comp)
        let size = videoComp.renderSize
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let fontSize = max(28, size.height * 0.045)
        for block in captionBlocks() {
            let text = CATextLayer()
            text.string = NSAttributedString(string: block.text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -3.0,
            ])
            text.alignmentMode = .center
            text.contentsScale = 2
            text.isWrapped = true
            let w = min(size.width * 0.86,
                        CGFloat(block.text.count) * fontSize * 0.62 + 48)
            let h = fontSize * 1.7
            text.cornerRadius = h / 4
            text.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            text.frame = CGRect(x: (size.width - w) / 2, y: size.height * 0.07,
                                width: w, height: h)
            text.opacity = 0

            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.12
            appear.beginTime = AVCoreAnimationBeginTimeAtZero + block.start
            appear.fillMode = .forwards
            appear.isRemovedOnCompletion = false
            let vanish = CABasicAnimation(keyPath: "opacity")
            vanish.fromValue = 1
            vanish.toValue = 0
            vanish.duration = 0.1
            vanish.beginTime = AVCoreAnimationBeginTimeAtZero + block.end
            vanish.fillMode = .forwards
            vanish.isRemovedOnCompletion = false
            text.add(appear, forKey: "in")
            text.add(vanish, forKey: "out")
            parent.addSublayer(text)
        }

        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent
        )
        return videoComp
    }
}
