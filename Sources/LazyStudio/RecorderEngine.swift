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
    let updater = Updater()

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let cameraOverlay = CameraOverlayController()
    private let effectsOverlay = EffectsOverlayController()
    private let recordingHUD = RecordingHUDController()
    private var editorObservation: AnyCancellable?

    override init() {
        super.init()
        // Forward AIEditor changes so the menu UI updates.
        editorObservation = aiEditor.objectWillChange
            .merge(with: updater.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        updater.checkAutomatically()
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

        // Fail loudly and helpfully if Screen Recording isn't granted —
        // a silent status line is how recordings get lost.
        guard CGPreflightScreenCaptureAccess() else {
            statusMessage = "Grant Screen Recording first"
            CGRequestScreenCaptureAccess()
            WelcomeWindow.show()
            return
        }

        // Show the native "choose what to share" picker (same one as
        // Zoom/Meet) so clicking Record always visibly does something.
        statusMessage = "Choose what to record…"
        let picker = SCContentSharingPicker.shared
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    /// Called once the user picks a screen/window/app in the system picker.
    func beginRecording(filter: SCContentFilter) async {
        guard !isRecording else { return }
        statusMessage = "Starting…"
        do {
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
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
            recordingHUD.show { [weak self] in
                Task { await self?.stop() }
            }
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
        recordingHUD.hide()
        SCContentSharingPicker.shared.isActive = false
        self.stream = nil
        self.recordingOutput = nil
        self.isRecording = false
        guard let url = lastRecordingURL,
              FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Recording failed — nothing was saved"
            return
        }
        statusMessage = "Saved"
        // Always reveal the raw file immediately — never leave the user
        // wondering where their video went while AI polish runs.
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if autoPolish, let agent = agents.first {
            await aiEditor.polish(url: url, agent: agent)
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

extension RecorderEngine: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        picker.remove(self)
        Task { @MainActor in await self.beginRecording(filter: filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        picker.remove(self)
        Task { @MainActor in
            self.statusMessage = "Cancelled"
            SCContentSharingPicker.shared.isActive = false
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.statusMessage = "Picker failed: \(error.localizedDescription)"
        }
    }
}
