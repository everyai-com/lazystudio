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
    @Published var lastPolishedURL: URL?
    @Published var lastTitle = ""
    @Published var lastDescription = ""
    /// Sticky failure reason — `stage` gets cleared on exit, this doesn't.
    @Published var lastError = ""

    /// Plan-only path for the editor: transcribe + ask the agent, return the
    /// keep-ranges without exporting. The editor strip visualizes the plan.
    func makePlan(url: URL, agent: AgentCLI, instruction: String? = nil) async throws -> EditPlan {
        isPolishing = true
        defer { isPolishing = false; stage = "" }
        stage = "Listening to your video…"
        let segments: [TranscriptSegment]
        do {
            segments = try await Transcriber.transcribe(url: url)
        } catch let e as Transcriber.TranscriberError {
            throw e
        } catch {
            // Apple Speech throws a raw "no speech detected" error on
            // silent videos — translate it for humans.
            if error.localizedDescription.lowercased().contains("speech") {
                throw PolishError.noSpeech
            }
            throw error
        }
        guard !segments.isEmpty else { throw PolishError.noSpeech }
        let transcript = Transcriber.promptText(from: segments)
        let duration = try await CMTimeGetSeconds(AVURLAsset(url: url).load(.duration))
        stage = "Thinking about the best parts…"
        // Title/description/social run on Apple's on-device model in parallel
        // with the agent's edit plan — private, instant, and it still works
        // when no agent CLI is installed. Agent copy is the fallback.
        async let onDevice = OnDeviceWriter.socialPack(transcript: transcript)
        let plan = try await requestPlan(
            agent: agent, transcript: transcript, duration: duration,
            gaps: Self.gapReport(segments, duration: duration),
            markers: Self.retakeMarkers(for: url),
            instruction: instruction
        )
        adoptSocial(plan, preferring: await onDevice)
        return plan
    }

    private func adoptSocial(_ plan: EditPlan, preferring pack: OnDeviceWriter.SocialPack? = nil) {
        lastTitle = pack?.title.isEmpty == false ? pack!.title : plan.title
        lastDescription = pack?.description.isEmpty == false ? pack!.description : plan.description
        lastLinkedIn = pack?.linkedin.isEmpty == false ? pack!.linkedin : (plan.linkedin ?? "")
        lastTweet = pack?.tweet.isEmpty == false ? pack!.tweet : (plan.tweet ?? "")
    }

    struct EditPlan: Decodable {
        struct Range: Decodable { let start: Double; let end: Double }
        struct Cut: Decodable { let start: Double; let end: Double; let reason: String }
        let keep: [Range]
        let cuts: [Cut]?
        let title: String
        let description: String
        // Social pack: post the same video everywhere without writing a word.
        let linkedin: String?
        let tweet: String?
    }

    @Published var lastLinkedIn = ""
    @Published var lastTweet = ""

    /// Retake markers the founder stamped with ⌘⇧X while recording.
    static func retakeMarkers(for url: URL) -> [Double] {
        guard let data = try? Data(contentsOf: RecorderEngine.markersURL(for: url)),
              let times = try? JSONDecoder().decode([Double].self, from: data)
        else { return [] }
        return times
    }

    func polish(url: URL, agent: AgentCLI, instruction: String? = nil) async {
        guard !isPolishing else { return }
        isPolishing = true
        lastPolishedURL = nil
        lastTitle = ""
        lastError = ""
        defer { isPolishing = false; stage = "" }
        do {
            stage = "Listening to your video…"
            let segments = try await Transcriber.transcribe(url: url)
            let transcript = Transcriber.promptText(from: segments)

            let duration = try await CMTimeGetSeconds(AVURLAsset(url: url).load(.duration))

            stage = "Thinking about the best parts…"
            // On-device Apple model writes the copy while the agent plans cuts.
            async let onDevice = OnDeviceWriter.socialPack(transcript: transcript)
            let plan = try await requestPlan(
                agent: agent, transcript: transcript, duration: duration,
                gaps: Self.gapReport(segments, duration: duration),
                markers: Self.retakeMarkers(for: url),
                instruction: instruction
            )
            let pack = await onDevice
            adoptSocial(plan, preferring: pack)

            stage = "Snipping out the boring bits…"
            let output = try await applyCuts(source: url, plan: plan)

            // Post-everywhere pack: title, description, LinkedIn, tweet.
            var notes = """
            \(lastTitle)

            \(lastDescription)
            """
            if !lastLinkedIn.isEmpty {
                notes += "\n\n--- LinkedIn ---\n\(lastLinkedIn)"
            }
            if !lastTweet.isEmpty {
                notes += "\n\n--- X / Twitter ---\n\(lastTweet)"
            }
            let notesURL = output.deletingPathExtension().appendingPathExtension("txt")
            try notes.write(to: notesURL, atomically: true, encoding: .utf8)

            // Captions for YouTube (from the on-device transcript, remapped
            // through the cuts so timestamps match the polished video).
            let srtURL = output.deletingPathExtension().appendingPathExtension("srt")
            try Self.srt(segments: segments, keep: plan.keep)
                .write(to: srtURL, atomically: true, encoding: .utf8)

            stage = "Done"
            lastPolishedURL = output
        } catch {
            let msg = error.localizedDescription.lowercased().contains("speech")
                ? (PolishError.noSpeech.errorDescription ?? "No speech found")
                : error.localizedDescription
            stage = "Failed: \(msg)"
            lastError = msg
        }
    }

    /// List the speech-free gaps so the model doesn't have to infer them —
    /// this is what turns "one big cut" into many precise ones.
    static func gapReport(_ segs: [TranscriptSegment], duration: Double) -> String {
        var gaps: [(Double, Double)] = []
        var prev = 0.0
        for s in segs {
            if s.start - prev > 0.7 { gaps.append((prev, s.start)) }
            prev = max(prev, s.end)
        }
        if duration - prev > 0.7 { gaps.append((prev, duration)) }
        guard !gaps.isEmpty else { return "none" }
        return gaps.map { String(format: "%.1f–%.1f (%.1fs)", $0.0, $0.1, $0.1 - $0.0) }
            .joined(separator: ", ")
    }

    private func requestPlan(agent: AgentCLI, transcript: String, duration: Double,
                             gaps: String = "none", markers: [Double] = [],
                             instruction: String? = nil) async throws -> EditPlan {
        let extra = instruction.map { "\n\nThe creator also asks: \($0)\nFollow this while keeping the rules above." } ?? ""
        let markerNote = markers.isEmpty ? "" : """


        RETAKE MARKERS: while recording, the creator pressed the "bad take" key at these times: \(markers.map { String(format: "%.1fs", $0) }.joined(separator: ", ")). Each marker means the sentence or attempt IMMEDIATELY BEFORE it was a mistake — find and cut that flubbed passage (the creator usually repeats it right after). Treat these as strong signals, more reliable than your own guesses.
        """
        let prompt = """
        You are a sharp, tasteful video editor. Below is a timestamped transcript of a \(Int(duration))-second screen recording destined for YouTube.

        Detected silence gaps (no speech at all): \(gaps)

        Rules:
        1. CUT every silence gap longer than 1.2s — leave only ~0.25s of breathing room on each side.
        2. CUT false starts, filler ("um", "so like" openings that restart), and retakes (repeated sentences — keep the LAST take).
        3. Prefer MANY precise cuts over one big cut. A good edit of a talking video typically has 4–12 separate cuts.
        4. Keep every sentence with real content; never cut mid-sentence; do not over-cut.
        5. Pad each kept range by 0.25s on both sides. Ranges must be within [0, \(duration)], non-overlapping, ascending.

        Also write, based on the actual content:
        - a catchy YouTube title and a 2-3 sentence description
        - "linkedin": a short founder-voice LinkedIn post (2-4 lines, no hashtag spam, ends with a soft hook)
        - "tweet": one tweet under 280 chars, plain-spoken, no hashtags

        Reply with ONLY this JSON, no markdown fences, no commentary. For every gap you remove, add it to "cuts" with a 2-4 word reason (e.g. "silence", "false start", "retake of intro"):
        {"keep": [{"start": 0.0, "end": 12.5}], "cuts": [{"start": 12.5, "end": 20.1, "reason": "silence"}], "title": "...", "description": "...", "linkedin": "...", "tweet": "..."}
        \(markerNote)
        Transcript:
        \(transcript)\(extra)
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

        // Honor the same "Optimized for social" switch as the manual export.
        let social = UserDefaults.standard.object(forKey: "socialExport") as? Bool ?? true
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: social ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHighestQuality
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
        case badPlan(String), exportFailed, noSpeech
        var errorDescription: String? {
            switch self {
            case .badPlan(let raw): "Couldn't parse the agent's edit plan: \(raw)"
            case .exportFailed: "Video export failed."
            case .noSpeech: "I couldn't hear any talking in this video. AI editing works off your voice — record with the Voice toggle on and say a few words, then try again. You can still cut by hand on the strip below."
            }
        }
    }
}
