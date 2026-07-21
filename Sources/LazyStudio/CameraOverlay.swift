import AppKit
import AVFoundation

/// Floating, borderless, always-on-top camera bubble (Loom / Screen Studio
/// style) that gets baked into the screen recording.
///  • round or rounded-square — double-click the bubble to switch live
///  • three sizes, set in Settings
///  • draggable; remembers where you left it
@MainActor
final class CameraOverlayController: NSObject {
    static let shapeKey = "cameraShape"   // "circle" | "square"
    static let sizeKey = "cameraSize"     // "small" | "medium" | "large"
    private static let originKey = "cameraOrigin"

    private var window: NSPanel?
    private var container: BubbleView?
    /// Shared so the home window's live preview and the recording bubble
    /// show the same camera without fighting over the device.
    static let session = AVCaptureSession()
    private var session: AVCaptureSession { Self.session }

    /// Configure + start the shared camera (used by the home-window preview).
    static func warmUp() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              !session.isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        if session.inputs.isEmpty,
           let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        nonisolated(unsafe) let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    /// Reports problems (denied permission, no camera) so they surface
    /// in the menu instead of the bubble just silently not appearing.
    var onProblem: ((String) -> Void)?

    static var bubbleSize: CGFloat {
        switch UserDefaults.standard.string(forKey: sizeKey) ?? "medium" {
        case "small": 160
        case "large": 300
        default: 220
        }
    }

    static var isCircle: Bool {
        (UserDefaults.standard.string(forKey: shapeKey) ?? "circle") == "circle"
    }

    static let mirrorKey = "cameraMirror"
    /// Mirrored (selfie-style) by default — what people expect from Loom.
    static var isMirrored: Bool {
        UserDefaults.standard.object(forKey: mirrorKey) as? Bool ?? true
    }

    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// Flip the live bubble when the mirror setting changes.
    func applyMirror() {
        guard let connection = previewLayer?.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = Self.isMirrored
    }

    func show() {
        guard window == nil else {
            window?.orderFrontRegardless()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            buildWindow()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.buildWindow() }
                    else { self?.onProblem?("Camera denied — no bubble (System Settings → Privacy → Camera)") }
                }
            }
        default:
            onProblem?("Camera denied — no bubble (System Settings → Privacy → Camera)")
        }
    }

    func hide() {
        if let frame = window?.frame {
            UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
        }
        // Stop the camera whenever the bubble is gone — no phantom green
        // light, no idle CPU burn. (stopRunning blocks; off the main thread.)
        nonisolated(unsafe) let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        window?.orderOut(nil)
        window = nil
        container = nil
    }

    /// Called from the bubble on double-click and from Settings.
    func applyShape() {
        container?.updateCorners()
    }

    private func buildWindow() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        if session.inputs.isEmpty {
            if let device = AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                onProblem?("No camera found — recording without bubble")
                return
            }
        }
        session.commitConfiguration()

        // 30fps is plenty for a bubble — halves the camera pipeline load.
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device,
           (try? device.lockForConfiguration()) != nil {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.unlockForConfiguration()
        }

        let size = Self.bubbleSize
        guard let screen = NSScreen.main else { return }
        // Restore the last position; default to bottom-left like Loom.
        var origin = NSPoint(x: screen.visibleFrame.minX + 24,
                             y: screen.visibleFrame.minY + 24)
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(saved)
            if screen.visibleFrame.insetBy(dx: -size / 2, dy: -size / 2).contains(p) {
                origin = p
            }
        }
        let rect = NSRect(origin: origin, size: NSSize(width: size, height: size))

        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = BubbleView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 3
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = container.bounds
        previewLayer.videoGravity = .resizeAspectFill
        container.layer?.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        applyMirror()
        container.updateCorners()

        panel.contentView = container
        panel.orderFrontRegardless()
        self.window = panel
        self.container = container

        nonisolated(unsafe) let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }
}

/// Camera view that supports double-click shape toggling.
private final class BubbleView: NSView {
    func updateCorners() {
        let circle = CameraOverlayController.isCircle
        layer?.cornerRadius = circle ? bounds.width / 2 : bounds.width * 0.12
        layer?.cornerCurve = .continuous
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let next = CameraOverlayController.isCircle ? "square" : "circle"
            UserDefaults.standard.set(next, forKey: CameraOverlayController.shapeKey)
            updateCorners()
            return
        }
        super.mouseDown(with: event)
    }
}
