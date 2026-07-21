# TODO after macOS 26 upgrade: SpeechAnalyzer transcription

Once this Mac is on macOS 26 (Tahoe) with the matching SDK/CLT, swap
Transcriber's engine to Apple's SpeechAnalyzer (~2.1% WER, beats Whisper,
on-device). Reference implementation: https://github.com/Kuberwastaken/megaphone
(MIT) — see their SpeechTranscriber usage.

Sketch (verify against the macOS 26 SDK before shipping):

```swift
// In Transcriber.transcribe(url:), preferred path:
if #available(macOS 26.0, *) {
    let transcriber = SpeechTranscriber(
        locale: .current,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)
    async let results: [TranscriptSegment] = transcriber.results.reduce(into: []) { acc, r in
        // r.text (AttributedString) + r.range (CMTimeRange) → TranscriptSegment
    }
    try await analyzer.analyzeSequence(from: file)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    return await results
}
// else: existing SFSpeechRecognizer path (keep as fallback for macOS 15).
```

Checklist:
1. `xcrun --show-sdk-version` ≥ 26.0 (update Command Line Tools if not).
2. Implement the path above in Transcriber.swift behind #available.
3. First run downloads the speech model — call AssetInventory APIs to
   preinstall, show "Downloading speech model…" in WelcomeWindow.
4. Bump LSMinimumSystemVersion stays 15.0 (fallback keeps old Macs working).
5. Test: transcript quality on a technical-vocabulary recording, then release.
