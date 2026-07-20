import AppKit
import QuartzCore

/// Screen Studio–style live effects, baked into the recording:
///  • a soft spotlight halo that follows the cursor
///  • an animated ripple on every click
/// Drawn on a transparent, click-through panel above all windows.
@MainActor
final class EffectsOverlayController {
    private var window: NSPanel?
    private var clickMonitor: Any?
    private var moveMonitor: Any?
    private var halo: CALayer?

    func start() {
        guard window == nil, let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        panel.contentView = content
        panel.orderFrontRegardless()
        window = panel

        // Cursor spotlight
        let haloSize: CGFloat = 90
        let halo = CALayer()
        halo.bounds = CGRect(x: 0, y: 0, width: haloSize, height: haloSize)
        halo.cornerRadius = haloSize / 2
        halo.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        halo.borderColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        halo.borderWidth = 1.5
        halo.position = flip(NSEvent.mouseLocation, in: screen)
        content.layer?.addSublayer(halo)
        self.halo = halo

        moveMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            guard let self, let halo = self.halo else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            halo.position = self.flip(NSEvent.mouseLocation, in: screen)
            CATransaction.commit()
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            self.ripple(at: self.flip(NSEvent.mouseLocation, in: screen), in: content)
        }
    }

    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        clickMonitor = nil
        moveMonitor = nil
        halo = nil
        window?.orderOut(nil)
        window = nil
    }

    /// NSEvent.mouseLocation is bottom-left origin; layers are top-left.
    private func flip(_ p: NSPoint, in screen: NSScreen) -> CGPoint {
        CGPoint(x: p.x - screen.frame.minX, y: screen.frame.height - (p.y - screen.frame.minY))
    }

    private func ripple(at point: CGPoint, in view: NSView) {
        let size: CGFloat = 44
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        layer.position = point
        layer.borderColor = NSColor.systemBlue.cgColor
        layer.borderWidth = 3
        layer.opacity = 0.9
        view.layer?.addSublayer(layer)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        layer.add(group, forKey: "ripple")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            layer.removeFromSuperlayer()
        }
    }
}
