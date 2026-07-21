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

    /// Which detected agent does the editing ("claude" / "codex" / "gemini").
    @Published var selectedAgentID = UserDefaults.standard.string(forKey: "selectedAgent") ?? "" {
        didSet { UserDefaults.standard.set(selectedAgentID, forKey: "selectedAgent") }
    }
    var activeAgent: AgentCLI? {
        agents.first { $0.id == selectedAgentID } ?? agents.first
    }

    /// agent id → signed in? Refreshed whenever the app becomes active,
    /// so finishing `codex login` in Terminal updates the UI on your way back.
    @Published var agentLoggedIn: [String: Bool] = [:]

    func refreshAgentLogins() {
        for agent in agents {
            Task { [weak self] in
                let ok = await agent.isLoggedIn()
                self?.agentLoggedIn[agent.id] = ok
            }
        }
    }

    /// Open Terminal with the agent's login command (Codex = ChatGPT account,
    /// Claude Code = Claude account) — no API keys anywhere.
    static func openLogin(for agentID: String) {
        let cmd = switch agentID {
        case "codex": "codex login"
        case "gemini": "gemini"
        default: "claude /login"
        }
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(cmd)\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var fileFinalized = false
    private var finalizeContinuation: CheckedContinuation<Void, Never>?
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
        // Bubble problems (camera denied, no camera) show in the menu instead
        // of the bubble just silently not appearing.
        cameraOverlay.onProblem = { [weak self] msg in self?.statusMessage = msg }
        WelcomeWindow.onRecord = { [weak self] in
            Task { @MainActor in await self?.start() }
        }
        MainWindow.recorder = self
        MCPServer.shared.start(recorder: self)
        // System-wide hotkeys: ⌘⇧R record/stop, ⌘⇧X retake marker.
        HotKeys.install()
        HotKeys.onRecordToggle = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording { await self.stop() } else { await self.start() }
            }
        }
        HotKeys.onRetakeMarker = { [weak self] in self?.markRetake() }
        // Agent detection shells out (`command -v`), so keep it off the main thread.
        Task { [weak self] in
            let found = await Task.detached { AgentCLI.detectAll() }.value
            self?.agents = found
            self?.refreshAgentLogins()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAgentLogins() }
        }
    }

    var recordingsDirectory: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LazyStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var isStarting = false

    // MARK: - Retake markers (⌘⇧X while recording)

    private var recordingStartedAt: Date?
    private var retakeMarkers: [Double] = []

    /// "That take was bad" — stamp the moment; the AI cuts the flubbed
    /// sentence right before each marker during the edit.
    func markRetake() {
        guard isRecording, let started = recordingStartedAt else { return }
        retakeMarkers.append(Date().timeIntervalSince(started))
        NSSound(named: "Pop")?.play()
        statusMessage = "Retake marked (\(retakeMarkers.count))"
    }

    /// Sidecar file the editor reads: "<recording>.markers.json"
    static func markersURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("markers.json")
    }

    private func saveMarkers(for url: URL) {
        guard !retakeMarkers.isEmpty else { return }
        if let data = try? JSONEncoder().encode(retakeMarkers) {
            try? data.write(to: Self.markersURL(for: url))
        }
    }

    /// Show/hide the live camera bubble outside of recording so you can
    /// position yourself before pressing Record (Loom-style).
    func updateBubblePreview() {
        if showCamera { cameraOverlay.show() }
        else if !isRecording { cameraOverlay.hide() }
    }

    /// Turn the preview bubble (and camera) off, e.g. when the panel closes.
    func hideBubblePreview() {
        guard !isRecording else { return }
        cameraOverlay.hide()
    }

    func start() async {
        // isStarting also blocks the double-press that used to wedge things.
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        // Fail loudly and helpfully if Screen Recording isn't granted —
        // a silent status line is how recordings get lost.
        guard CGPreflightScreenCaptureAccess() else {
            statusMessage = "Grant Screen Recording first"
            CGRequestScreenCaptureAccess()
            WelcomeWindow.show()
            return
        }

        // Ask for mic access up front so recordings aren't silently voiceless.
        if includeMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                statusMessage = "Mic denied — recording without voice"
            }
        }

        // Same for the camera, so the bubble reliably appears on first use.
        if showCamera, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }

        // Loom-style: no confusing picker — just record the whole main screen.
        statusMessage = "Starting…"
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                statusMessage = "No screen found"
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            MainWindow.hide()
            ResultWindow.close()
            fileFinalized = false

            // Build the whole pipeline BEFORE the countdown so capture
            // starts the instant it hits zero — no lag after "1".
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

            // Camera bubble up during the countdown so you can position
            // yourself; 3…2…1, then capture fires immediately.
            if showCamera { cameraOverlay.show() }
            await CountdownOverlay.run()

            try await stream.startCapture()

            self.stream = stream
            self.recordingOutput = output
            self.lastRecordingURL = url
            self.isRecording = true
            self.statusMessage = "Recording…"
            self.recordingStartedAt = Date()
            self.retakeMarkers = []

            if clickEffects { effectsOverlay.start() }
            recordingHUD.show(onStop: { [weak self] in
                Task { await self?.stop() }
            }, onCancel: { [weak self] in
                Task { await self?.cancelRecording() }
            })
        } catch {
            statusMessage = "Couldn't start: \(error.localizedDescription)"
            cameraOverlay.hide()
            MainWindow.show()
        }
    }

    func stop() async {
        guard let stream else { return }
        statusMessage = "Finishing…"
        do {
            try await stream.stopCapture()
        } catch {
            statusMessage = "Stop failed: \(error.localizedDescription)"
        }
        // Wait (bounded) for SCRecordingOutput to finish writing the mp4 —
        // checking the file before finalize is how "nothing was saved" happens.
        if !fileFinalized {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                finalizeContinuation = cont
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.finalizeContinuation?.resume()
                    self?.finalizeContinuation = nil
                }
            }
        }
        cleanupAfterStream()
        guard let url = lastRecordingURL,
              FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Recording failed — nothing was saved"
            return
        }
        saveMarkers(for: url)
        statusMessage = "Saved"
        // Straight into the editor with the fresh video selected —
        // recorder and editor are the same app, no window shuffle.
        MainWindow.showVideos()
        if autoPolish, let agent = activeAgent {
            Task { await aiEditor.polish(url: url, agent: agent) }
        }
    }

    /// Re-round the live bubble when the shape changes in Settings.
    func cameraShapeChanged() {
        cameraOverlay.applyShape()
    }

    /// Flip the live bubble when the mirror toggle changes.
    func cameraMirrorChanged() {
        cameraOverlay.applyMirror()
    }

    /// Trash-can on the REC pill: stop and throw the file away.
    func cancelRecording() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        cleanupAfterStream()
        if let url = lastRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        lastRecordingURL = nil
        statusMessage = "Discarded"
        MainWindow.show()
    }

    /// Tear down everything tied to a live stream — used by both normal stop
    /// and the stream-died-with-error path, so overlays never get stuck.
    private func cleanupAfterStream() {
        cameraOverlay.hide()
        effectsOverlay.stop()
        recordingHUD.hide()
        stream = nil
        recordingOutput = nil
        isRecording = false
    }
}

extension RecorderEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.cleanupAfterStream()
            self.statusMessage = "Stopped: \(error.localizedDescription)"
        }
    }
}

extension RecorderEngine: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.fileFinalized = true
            self.finalizeContinuation?.resume()
            self.finalizeContinuation = nil
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.fileFinalized = true
            self.statusMessage = "Recording failed: \(error.localizedDescription)"
            self.finalizeContinuation?.resume()
            self.finalizeContinuation = nil
        }
    }
}
