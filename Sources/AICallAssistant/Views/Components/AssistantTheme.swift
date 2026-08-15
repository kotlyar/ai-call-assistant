import AppKit
import SwiftUI

enum AssistantTheme {
    static let cornerRadius: CGFloat = 12
    static let compactCornerRadius: CGFloat = 9
    static let contentWidth: CGFloat = 760

    static let windowBackground = adaptive(
        light: NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 246 / 255, alpha: 1),
        dark: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1)
    )
    static let sidebarBackground = adaptive(
        light: NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 237 / 255, alpha: 1),
        dark: NSColor(srgbRed: 36 / 255, green: 36 / 255, blue: 39 / 255, alpha: 1)
    )
    static let surface = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 43 / 255, green: 43 / 255, blue: 47 / 255, alpha: 1)
    )
    static let subtleSurface = adaptive(
        light: NSColor(srgbRed: 240 / 255, green: 241 / 255, blue: 244 / 255, alpha: 1),
        dark: NSColor(srgbRed: 52 / 255, green: 52 / 255, blue: 58 / 255, alpha: 1)
    )
    static let hoverSurface = adaptive(
        light: NSColor(srgbRed: 229 / 255, green: 230 / 255, blue: 234 / 255, alpha: 1),
        dark: NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 64 / 255, alpha: 1)
    )
    static let separator = adaptive(
        light: NSColor(srgbRed: 217 / 255, green: 218 / 255, blue: 224 / 255, alpha: 1),
        dark: NSColor(srgbRed: 64 / 255, green: 64 / 255, blue: 71 / 255, alpha: 1)
    )
    static let secondaryText = adaptive(
        light: NSColor(srgbRed: 108 / 255, green: 108 / 255, blue: 116 / 255, alpha: 1),
        dark: NSColor(srgbRed: 167 / 255, green: 167 / 255, blue: 175 / 255, alpha: 1)
    )
    static let accent = adaptive(
        light: NSColor(srgbRed: 57 / 255, green: 91 / 255, blue: 215 / 255, alpha: 1),
        dark: NSColor(srgbRed: 120 / 255, green: 146 / 255, blue: 255 / 255, alpha: 1)
    )
    static let accentSoft = adaptive(
        light: NSColor(srgbRed: 237 / 255, green: 240 / 255, blue: 255 / 255, alpha: 1),
        dark: NSColor(srgbRed: 40 / 255, green: 47 / 255, blue: 77 / 255, alpha: 1)
    )
    static let green = adaptive(
        light: NSColor(srgbRed: 39 / 255, green: 134 / 255, blue: 82 / 255, alpha: 1),
        dark: NSColor(srgbRed: 87 / 255, green: 204 / 255, blue: 135 / 255, alpha: 1)
    )

    static let liveSurface = Color.white.opacity(0.065)
    static let liveSubtleSurface = Color.white.opacity(0.04)
    static let liveSeparator = Color.white.opacity(0.11)
    static let liveSecondaryText = Color.white.opacity(0.62)
    static let liveAccent = Color(red: 141 / 255, green: 164 / 255, blue: 1)
    static let liveGreen = Color(red: 87 / 255, green: 204 / 255, blue: 135 / 255)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct AssistantCardModifier: ViewModifier {
    var selected = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: AssistantTheme.cornerRadius, style: .continuous)
                    .fill(selected ? AssistantTheme.accentSoft : AssistantTheme.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AssistantTheme.cornerRadius, style: .continuous)
                    .stroke(
                        selected ? AssistantTheme.accent : AssistantTheme.separator,
                        lineWidth: selected ? 1.5 : 1
                    )
            }
    }
}

extension View {
    func assistantCard(selected: Bool = false) -> some View {
        modifier(AssistantCardModifier(selected: selected))
    }
}

struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.992 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
