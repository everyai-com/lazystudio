import Foundation
@preconcurrency import AVFoundation
import AppKit

/// The "record lazily, ship polished" pipeline:
///   1. Transcribe on-device (Apple Speech — free, private)
///   2. Ask your installed agent CLI (Claude Code / Codex / Gemini) for an
///      edit plan: which ranges to keep, plus a YouTube title & description
///   3. Apply the cuts with AVFoundation and export "(Polished).mp4"
///
/// No API keys. Your existing Claude/Codex subscription does the thinking.
@MainActor
final class AIEditor: ObservableObject {
    @Published var isPolishing = false
    @Published var stage = ""

    struct EditPlan: Decodable {
        struct Range: Decodable { let start: Double; let end: Double }
        let keep: [Range]
        let title: String
        let description: String
    }

    func polish(url: URL, agent: AgentCLI) async {
        guard !isPolishing else { return }
        isPolishing = true
        defer { isPolishing = false; stage = "" }
        do {
            stage = "Transcribing…"
            let segments = try await Transcriber.transcribe(url: url)
            let transcript = Transcriber.promptText(from: segments)

            let duration = try await CMTimeGetSeconds(AVURLAsset(url: url).load(.duration))

            stage = "Asking \(agent.displayName)…"
            let plan = try await requestPlan(
                agent: agent, transcript: transcript, duration: duration
            )

            stage = "Cutting & exporting…"
            let output = try await applyCuts(source: url, plan: plan)

            let notes = """
            \(plan.title)

            \(plan.description)
            """
            let notesURL = output.deletingPathExtension().appendingPathExtension("txt")
            try notes.write(to: notesURL, atomically: true, encoding: .utf8)

            // Captions for YouTube (from the on-device transcript, remapped
            // through the cuts so timestamps match the polished video).
            let srtURL = output.deletingPathExtension().appendingPathExtension("srt")
            try Self.srt(segments: segments, keep: plan.keep)
                .write(to: srtURL, atomically: true, encoding: .utf8)

            stage = "Done"
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            stage = "Failed: \(error.localizedDescription)"
        }
    }

    private func requestPlan(agent: AgentCLI, transcript: String, duration: Double) async throws -> EditPlan {
        let prompt = """
        You are a video editor. Below is a timestamped transcript of a \(Int(duration))-second screen recording destined for YouTube.

        Decide which time ranges to KEEP: drop long silences (gaps between lines), false starts, filler, and obvious retakes (repeated sentences — keep the last take). Keep everything with real content; do not over-cut. Pad each kept range by 0.3s on both sides. Ranges must be within [0, \(duration)], non-overlapping, ascending.

        Also write a catchy YouTube title and a 2-3 sentence description.

        Reply with ONLY this JSON, no markdown fences, no commentary:
        {"keep": [{"start": 0.0, "end": 12.5}], "title": "...", "description": "..."}

        Transcript:
        \(transcript)
        """
        let raw = try await agent.run(prompt: prompt)
        guard let jsonStart = raw.firstIndex(of: "{"),
              let jsonEnd = raw.lastIndex(of: "}"),
              let data = String(raw[jsonStart...jsonEnd]).data(using: .utf8),
              let plan = try? JSONDecoder().decode(EditPlan.self, from: data),
              !plan.keep.isEmpty
        else {
            throw PolishError.badPlan(String(raw.prefix(300)))
        }
        return plan
    }

    private func applyCuts(source: URL, plan: EditPlan) async throws -> URL {
        let asset = AVURLAsset(url: source)
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
        for range in plan.keep {
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

        let output = source.deletingPathExtension()
            .appendingPathExtension("polished.mp4")
        try? FileManager.default.removeItem(at: output)

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else { throw PolishError.exportFailed }
        try await export.export(to: output, as: .mp4)
        return output
    }

    /// Build an SRT from word segments, mapping source timestamps into the
    /// polished timeline (source time minus everything cut before it).
    static func srt(segments: [TranscriptSegment], keep: [EditPlan.Range]) -> String {
        func remap(_ t: Double) -> Double? {
            var offset = 0.0
            for r in keep {
                if t >= r.start && t <= r.end { return offset + (t - r.start) }
                if t > r.end { offset += r.end - r.start }
            }
            return nil
        }
        func stamp(_ t: Double) -> String {
            let h = Int(t) / 3600, m = Int(t) % 3600 / 60, s = Int(t) % 60
            let ms = Int((t - t.rounded(.down)) * 1000)
            return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
        }

        // Group words into ~4s caption lines.
        var blocks: [(start: Double, end: Double, text: String)] = []
        var words: [String] = []
        var blockStart: Double?
        var blockEnd = 0.0
        for seg in segments {
            guard let s = remap(seg.start), let e = remap(seg.end) else { continue }
            if blockStart == nil { blockStart = s }
            words.append(seg.text)
            blockEnd = e
            if e - (blockStart ?? e) >= 4 || words.count >= 12 {
                blocks.append((blockStart!, blockEnd, words.joined(separator: " ")))
                words = []
                blockStart = nil
            }
        }
        if let blockStart, !words.isEmpty {
            blocks.append((blockStart, blockEnd, words.joined(separator: " ")))
        }

        return blocks.enumerated().map { i, b in
            "\(i + 1)\n\(stamp(b.start)) --> \(stamp(b.end))\n\(b.text)\n"
        }.joined(separator: "\n")
    }

    enum PolishError: LocalizedError {
        case badPlan(String), exportFailed
        var errorDescription: String? {
            switch self {
            case .badPlan(let raw): "Couldn't parse the agent's edit plan: \(raw)"
            case .exportFailed: "Video export failed."
            }
        }
    }
}
