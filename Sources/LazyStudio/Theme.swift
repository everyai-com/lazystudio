import SwiftUI

/// LazyStudio design system — one place for the brand look.
enum Theme {
    static let purple = Color(red: 0.55, green: 0.27, blue: 0.98)
    static let indigo = Color(red: 0.29, green: 0.15, blue: 0.66)
    static let coral = Color(red: 1.0, green: 0.30, blue: 0.33)
    static let coralDeep = Color(red: 0.85, green: 0.16, blue: 0.28)

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [purple, indigo],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var recordGradient: LinearGradient {
        LinearGradient(colors: [coral, coralDeep],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Soft elevated card used across panels.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.primary.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
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
