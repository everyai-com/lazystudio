import AppKit
import SwiftUI

/// Big 3…2…1 in the middle of the screen before capture starts, so you can
/// get ready instead of being recorded mid-scramble.
@MainActor
enum CountdownOverlay {
    static func run(seconds: Int = 3) async {
        guard let screen = NSScreen.main else { return }

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 160, weight: .bold)
        label.textColor = .white
        label.alignment = .center

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 280))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        box.layer?.cornerRadius = 48
        label.frame = box.bounds.insetBy(dx: 0, dy: 40)
        box.addSubview(label)

        let panel = NSPanel(
            contentRect: NSRect(
                x: screen.frame.midX - 140, y: screen.frame.midY - 140,
                width: 280, height: 280
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.contentView = box
        panel.orderFrontRegardless()

        for i in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(i)"
            NSSound(named: "Tink")?.play()
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
    }
}
