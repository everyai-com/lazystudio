import Foundation

/// Pluggable AI post-processing: the "record lazily, get a polished video" pipeline.
///
/// Design: providers (Claude, OpenAI, local Whisper, …) implement `AIProvider`.
/// The planned pipeline:
///   1. Extract audio → transcribe (Whisper / provider ASR)
///   2. Send transcript + silence/scene analysis to the LLM
///   3. LLM returns an edit decision list (cuts, zooms, chapters, title)
///   4. Apply the EDL with AVFoundation composition and export
protocol AIProvider: Sendable {
    var name: String { get }
    func planEdits(transcript: String) async throws -> String
}

struct ClaudeProvider: AIProvider {
    let name = "Claude"
    let apiKey: String

    func planEdits(transcript: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 4096,
            "messages": [[
                "role": "user",
                "content": "You are a video editor. Given this screen-recording transcript with timestamps, return a JSON edit decision list: cuts for silences/mistakes, zoom moments, chapter markers, and a YouTube title + description.\n\n\(transcript)"
            ]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Entry point used by the UI. Currently a stub that logs;
/// transcription + EDL application land next.
actor AIEditor {
    static let shared = AIEditor()

    func polish(url: URL) async {
        // TODO: transcribe with SFSpeechRecognizer/whisper.cpp, call provider,
        // apply returned EDL via AVMutableComposition, export polished .mp4.
        print("AI polish requested for \(url.path) — pipeline not implemented yet.")
    }
}
