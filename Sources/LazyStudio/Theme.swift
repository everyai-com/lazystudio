import SwiftUI

/// LazyStudio design system — one place for the brand look.
enum Theme {
    /// Warm tungsten studio palette: brass accent, cream text, red only
    /// for Record. Restraint is the taste — one warm accent, one signal red.
    static let accent = Color(red: 0.89, green: 0.65, blue: 0.29)      // brass
    static let accentDeep = Color(red: 0.68, green: 0.44, blue: 0.16)  // dark brass
    static let coral = Color(red: 0.95, green: 0.30, blue: 0.25)
    static let coralDeep = Color(red: 0.78, green: 0.17, blue: 0.16)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [accent, accentDeep],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var recordGradient: LinearGradient {
        LinearGradient(colors: [coral, coralDeep],
                       startPoint: .top, endPoint: .bottom)
    }
}

extension Theme {
    /// The "dark studio" stage: charcoal-indigo with a soft key light from
    /// the top. Content (thumbnails, player) becomes the brightest thing on
    /// screen — the eye goes to the video, not the chrome.
    struct Studio: View {
        var body: some View {
            ZStack {
                // Warm charcoal, like a studio at night.
                LinearGradient(
                    colors: [
                        Color(red: 0.11, green: 0.10, blue: 0.09),
                        Color(red: 0.055, green: 0.05, blue: 0.045),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                // Tungsten key light from above.
                RadialGradient(
                    colors: [Theme.accent.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.5, y: -0.1),
                    startRadius: 0, endRadius: 520
                )
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// Put this screen on the dark studio stage.
    func studioStage() -> some View {
        ZStack { Theme.Studio(); self }
    }
}

extension Animation {
    /// Strong ease-out (cubic-bezier 0.23,1,0.32,1) — built-in curves are too
    /// weak; UI motion stays under 300ms and never eases in.
    static func lsSnappy(_ duration: Double = 0.18) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

/// Press feedback for plain/card buttons: instant, on press — not on release.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.lsSnappy(0.12), value: configuration.isPressed)
    }
}

/// Soft elevated card used across panels.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            // Glass over the dark stage: faint fill + hairline top-light border.
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.16), .white.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}

extension View {
    func lsCard(radius: CGFloat = 14) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

/// The big glowing Record button.
struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.bold())
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Theme.recordGradient, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Theme.coral.opacity(configuration.isPressed ? 0.2 : 0.45),
                    radius: configuration.isPressed ? 6 : 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
