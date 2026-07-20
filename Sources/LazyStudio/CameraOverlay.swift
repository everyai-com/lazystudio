import AppKit
import AVFoundation

/// Floating, borderless, always-on-top circular camera bubble
/// (Screen Studio / Cap style) that gets baked into the screen recording.
@MainActor
final class CameraOverlayController: NSObject {
    private var window: NSPanel?
    private let session = AVCaptureSession()

    func show() {
        guard window == nil else {
            window?.orderFrontRegardless()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in self?.buildWindow() }
        }
    }

    func hide() {
        session.stopRunning()
        window?.orderOut(nil)
        window = nil
    }

    private func buildWindow() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()

        let size: CGFloat = 220
        guard let screen = NSScreen.main else { return }
        let rect = NSRect(
            x: screen.visibleFrame.minX + 24,
            y: screen.visibleFrame.minY + 24,
            width: size, height: size
        )

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

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = size / 2
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 3
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = container.bounds
        previewLayer.videoGravity = .resizeAspectFill
        container.layer?.addSublayer(previewLayer)

        panel.contentView = container
        panel.orderFrontRegardless()
        self.window = panel

        nonisolated(unsafe) let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }
}
