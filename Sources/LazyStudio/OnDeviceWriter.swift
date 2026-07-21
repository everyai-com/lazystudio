import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Titles & descriptions from Apple's on-device model (macOS 26 Foundation
/// Models) — free, private, instant, and no agent CLI needed. The agent CLIs
/// still do the edit *plan* (cuts need stronger reasoning); this covers the
/// FunClip-style "describe my video" half entirely on-device.
enum OnDeviceWriter {

    struct SocialPack: Sendable {
        var title: String
        var description: String
        var linkedin: String
        var tweet: String
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    // Plain-JSON prompting rather than @Generable guided generation: the
    // FoundationModels macro plugin isn't visible to `swift build` (Xcode-only
    // toolchain plugin), and a decodable JSON contract works everywhere.
    private struct PackDraft: Decodable {
        var title: String
        var description: String
        var linkedin: String
        var tweet: String
    }

    /// nil when the model isn't available (old macOS, model not downloaded).
    static func socialPack(transcript: String) async -> SocialPack? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              SystemLanguageModel.default.availability == .available else { return nil }
        // The on-device model has a small context window — keep the head of
        // the talk, which is where creators say what the video is about.
        let clipped = String(transcript.prefix(6000))
        let session = LanguageModelSession(instructions: """
            You write publishing copy for screen-recorded videos. \
            Base everything only on the transcript you are given. \
            Plain language, no hashtag spam, no emojis unless natural. \
            Reply with ONLY a JSON object, no markdown fences, shaped exactly: \
            {"title": "catchy YouTube title under 70 chars", \
            "description": "2-3 sentence YouTube description", \
            "linkedin": "friendly 2-4 sentence LinkedIn post", \
            "tweet": "one tweet under 260 chars"}
            """)
        do {
            let raw = try await session.respond(
                to: "Transcript of the video:\n\(clipped)"
            ).content
            // Tolerate stray prose/fences around the JSON.
            guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"),
                  let data = String(raw[a...b]).data(using: .utf8),
                  let draft = try? JSONDecoder().decode(PackDraft.self, from: data)
            else { return nil }
            return SocialPack(
                title: draft.title, description: draft.description,
                linkedin: draft.linkedin, tweet: draft.tweet
            )
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
