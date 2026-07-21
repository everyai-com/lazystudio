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

    /// Turn an AI keep-plan into visible kept/cut segments.
    func apply(keep: [AIEditor.EditPlan.Range]) async {
        var segs: [Segment] = []
        var cursor = 0.0
        for r in keep.sorted(by: { $0.start < $1.start }) {
            let s = max(cursor, min(r.start, duration))
            let e = max(s, min(r.end, duration))
            if s > cursor + 0.05 { segs.append(Segment(start: cursor, end: s, kept: false)) }
            if e > s { segs.append(Segment(start: s, end: e, kept: true)) }
            cursor = max(cursor, e)
        }
        if cursor < duration - 0.05 {
            segs.append(Segment(start: cursor, end: duration, kept: false))
        }
        if !segs.isEmpty { segments = segs }
        await rebuildPreview()
    }

    /// Click a segment to cut it or bring it back.
    func toggle(_ id: Segment.ID) async {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
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

    /// Render exactly what the strip shows → "(edited).mp4" next to the raw file.
    func export() async throws -> URL {
        isExporting = true
        defer { isExporting = false }
        let comp = try await Self.composition(asset: AVURLAsset(url: url), keep: keptRanges)
        let output = url.deletingPathExtension().appendingPathExtension("edited.mp4")
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(
            asset: comp, presetName: AVAssetExportPresetHighestQuality
        ) else { throw AIEditor.PolishError.exportFailed }
        try await exporter.export(to: output, as: .mp4)
        return output
    }
}
