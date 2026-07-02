import SwiftUI

/// The Context design language: cream ground, ink text, logo-blue actions.
/// Mirrors the CSS tokens used on context.nikliolios.com.
enum Theme {
    static let cream   = Color(hex: 0xFAF6EC)
    static let card    = Color(hex: 0xFFFDF6)
    static let ink     = Color(hex: 0x2B2620)
    static let muted   = Color(hex: 0x8D8574)
    static let line    = Color(hex: 0xE7DCC2)
    static let blue    = Color(hex: 0x0A7BF5)
    static let green   = Color(hex: 0x2C8A4A)
    static let track   = Color(hex: 0xECE3CD)
    static let fact    = Color(hex: 0x6C6353)
    static let body    = Color(hex: 0x4A4237)
    static let orange  = Color(hex: 0xC2622A)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// Full-width primary action — brand blue, 7pt corners.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Theme.blue.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Compact filled button (e.g. "Open" in the link card).
struct SmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8).padding(.horizontal, 13)
            .background(Theme.blue.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Outlined secondary button on cream.
struct GhostButtonStyle: ButtonStyle {
    var tint: Color = Theme.blue
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 8).padding(.horizontal, 13)
            .background(RoundedRectangle(cornerRadius: 7)
                .stroke(Theme.line, lineWidth: 1.5)
                .opacity(configuration.isPressed ? 0.6 : 1))
    }
}

/// The through-line: 7pt bar, blue while working, green when complete.
struct ProgressBar: View {
    let value: Double
    var complete = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(complete ? Theme.green : Theme.blue)
                    .frame(width: max(10, geo.size.width * min(value, 1)))
            }
        }
        .frame(height: 7)
        .animation(.easeInOut(duration: 0.3), value: value)
    }
}

/// Small-caps section caption, e.g. "YOUR PROFILE".
struct Caption: View {
    let text: String
    var color: Color = Theme.muted

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(color)
    }
}
