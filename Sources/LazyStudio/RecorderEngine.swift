import Foundation
import Combine
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit

/// Drives screen + system audio + microphone recording via ScreenCaptureKit,
/// writing straight to an .mp4 with SCRecordingOutput (macOS 15+).
@MainActor
final class RecorderEngine: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var includeMicrophone = true
    @Published var includeSystemAudio = true
    @Published var showCamera = true
    @Published var clickEffects = true
    @Published var lastRecordingURL: URL?
    @Published var statusMessage = "Ready"
    @Published var agents: [AgentCLI] = []
    @Published var autoPolish = UserDefaults.standard.object(forKey: "autoPolish") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPolish, forKey: "autoPolish") }
    }

    let aiEditor = AIEditor()

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let cameraOverlay = CameraOverlayController()
    private let effectsOverlay = EffectsOverlayController()
    private var editorObservation: AnyCancellable?

    override init() {
        super.init()
        // Forward AIEditor changes so the menu UI updates.
        editorObservation = aiEditor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Agent detection shells out (`command -v`), so keep it off the main thread.
        Task { [weak self] in
            let found = await Task.detached { AgentCLI.detectAll() }.value
            self?.agents = found
        }
    }

    var recordingsDirectory: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LazyStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() async {
        guard !isRecording else { return }
        statusMessage = "Starting…"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                statusMessage = "No display found"
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = true
            config.capturesAudio = includeSystemAudio
            config.captureMicrophone = includeMicrophone
            if includeMicrophone {
                config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: self)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = recordingsDirectory
                .appendingPathComponent("Recording \(formatter.string(from: Date())).mp4")

            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = url
            recordingConfig.outputFileType = .mp4
            recordingConfig.videoCodecType = .h264

            let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            try stream.addRecordingOutput(output)

            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = output
            self.lastRecordingURL = url
            self.isRecording = true
            self.statusMessage = "Recording…"

            if showCamera { cameraOverlay.show() }
            if clickEffects { effectsOverlay.start() }
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            statusMessage = "Stop failed: \(error.localizedDescription)"
        }
        cameraOverlay.hide()
        effectsOverlay.stop()
        self.stream = nil
        self.recordingOutput = nil
        self.isRecording = false
        self.statusMessage = "Saved"
        guard let url = lastRecordingURL else { return }
        if autoPolish, let agent = agents.first {
            await aiEditor.polish(url: url, agent: agent)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

extension RecorderEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.isRecording = false
            self.statusMessage = "Stopped: \(error.localizedDescription)"
        }
    }
}

extension RecorderEngine: SCRecordingOutputDelegate {}
