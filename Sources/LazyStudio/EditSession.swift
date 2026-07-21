import Foundation
@preconcurrency import AVFoundation

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
