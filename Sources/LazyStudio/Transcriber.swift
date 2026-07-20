import Foundation
import Speech
import AVFoundation

/// On-device transcription with Apple's Speech framework — free, private,
/// nothing to install. Produces timestamped segments for the AI edit pass.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum Transcriber {
    static func transcribe(url: URL) async throws -> [TranscriptSegment] {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw TranscriberError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw TranscriberError.unavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                let segments = result.bestTranscription.segments.map {
                    TranscriptSegment(
                        start: $0.timestamp,
                        end: $0.timestamp + $0.duration,
                        text: $0.substring
                    )
                }
                continuation.resume(returning: segments)
            }
        }
    }

    /// Word-level segments grouped into readable ~10s lines for the LLM prompt.
    static func promptText(from segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else { return "(no speech detected)" }
        var lines: [String] = []
        var lineStart = segments[0].start
        var lineEnd = segments[0].end
        var words: [String] = []
        for seg in segments {
            if seg.end - lineStart > 10, !words.isEmpty {
                lines.append(String(format: "[%.1f–%.1f] %@", lineStart, lineEnd, words.joined(separator: " ")))
                words = []
                lineStart = seg.start
            }
            words.append(seg.text)
            lineEnd = seg.end
        }
        if !words.isEmpty {
            lines.append(String(format: "[%.1f–%.1f] %@", lineStart, lineEnd, words.joined(separator: " ")))
        }
        return lines.joined(separator: "\n")
    }

    enum TranscriberError: LocalizedError {
        case notAuthorized, unavailable
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Speech recognition permission denied (System Settings → Privacy)."
            case .unavailable: "Speech recognition unavailable on this Mac."
            }
        }
    }
}
