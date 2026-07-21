import AppKit
import QuartzCore

/// Screen Studio–style live effects, baked into the recording:
///  • a soft spotlight halo that follows the cursor
///  • an animated ripple on every click
/// Drawn on a transparent, click-through panel above all windows.
@MainActor
final class EffectsOverlayController {
    private var window: NSPanel?
    private var pollTimer: Timer?
    private var wasPressed = false
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

        // Cursor spotlight: soft radial glow, not a hard-edged disc.
        let haloSize: CGFloat = 130
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.colors = [
            NSColor.systemYellow.withAlphaComponent(0.32).cgColor,
            NSColor.systemYellow.withAlphaComponent(0.10).cgColor,
            NSColor.clear.cgColor,
        ]
        halo.locations = [0, 0.55, 1]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.bounds = CGRect(x: 0, y: 0, width: haloSize, height: haloSize)
        halo.cornerRadius = haloSize / 2
        halo.position = flip(NSEvent.mouseLocation, in: screen)
        content.layer?.addSublayer(halo)
        self.halo = halo

        // Poll instead of global event monitors: monitors need Accessibility
        // permission and silently deliver nothing without it, which is how the
        // spotlight ends up frozen. mouseLocation + pressedMouseButtons need
        // no permission and work over every app.
        wasPressed = false
        let screenFrame = screen.frame
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let halo = self.halo else { return }
                let p = Self.flip(NSEvent.mouseLocation, in: screenFrame)
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.06)
                halo.position = p
                CATransaction.commit()
                let pressed = NSEvent.pressedMouseButtons != 0
                if pressed && !self.wasPressed {
                    self.ripple(at: p, in: content)
                }
                self.wasPressed = pressed
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        halo = nil
        window?.orderOut(nil)
        window = nil
    }

    /// NSEvent.mouseLocation is bottom-left origin; layers are top-left.
    private func flip(_ p: NSPoint, in screen: NSScreen) -> CGPoint {
        Self.flip(p, in: screen.frame)
    }

    private static func flip(_ p: NSPoint, in frame: NSRect) -> CGPoint {
        CGPoint(x: p.x - frame.minX, y: frame.height - (p.y - frame.minY))
    }

    /// Two expanding rings + a quick flash dot — reads clearly at any size.
    private func ripple(at point: CGPoint, in view: NSView) {
        func ring(_ delay: Double, width: CGFloat, to scale: Double, duration: Double) {
            let size: CGFloat = 46
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.cornerRadius = size / 2
            layer.position = point
            layer.borderColor = NSColor.systemYellow.cgColor
            layer.borderWidth = width
            layer.opacity = 0
            view.layer?.addSublayer(layer)

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.25
            grow.toValue = scale
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.95, 0]
            fade.keyTimes = [0, 0.15, 1]
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = duration
            group.beginTime = CACurrentMediaTime() + delay
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards
            layer.add(group, forKey: "ripple")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration + 0.05) {
                layer.removeFromSuperlayer()
            }
        }
        ring(0, width: 3.5, to: 2.4, duration: 0.45)
        ring(0.08, width: 2, to: 3.1, duration: 0.55)

        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        dot.cornerRadius = 7
        dot.position = point
        dot.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        view.layer?.addSublayer(dot)
        let dotFade = CABasicAnimation(keyPath: "opacity")
        dotFade.fromValue = 0.9
        dotFade.toValue = 0
        dotFade.duration = 0.3
        dotFade.isRemovedOnCompletion = false
        dotFade.fillMode = .forwards
        dot.add(dotFade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            dot.removeFromSuperlayer()
        }
    }
}
