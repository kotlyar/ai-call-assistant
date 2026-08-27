import AppKit
import SwiftUI

enum AssistantTheme {
    static let cornerRadius: CGFloat = 8
    static let compactCornerRadius: CGFloat = 6
    static let contentWidth: CGFloat = 680

    static let windowBackground = adaptive(
        light: NSColor(srgbRed: 247 / 255, green: 248 / 255, blue: 250 / 255, alpha: 1),
        dark: NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 31 / 255, alpha: 1)
    )
    /// Apple Music-style sidebar: a lightly tinted native plane in Light Mode,
    /// with the standard dark material equivalent in Dark Mode.
    static let sidebarBackground = adaptive(
        light: NSColor(srgbRed: 247 / 255, green: 243 / 255, blue: 245 / 255, alpha: 1),
        dark: NSColor(srgbRed: 38 / 255, green: 36 / 255, blue: 39 / 255, alpha: 1)
    )
    static let sidebarForeground = Color.primary.opacity(0.90)
    static let sidebarSecondary = Color.secondary
    static let sidebarRule = Color.primary.opacity(0.08)
    static let surface = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 43 / 255, green: 43 / 255, blue: 47 / 255, alpha: 1)
    )
    static let subtleSurface = adaptive(
        light: NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 249 / 255, alpha: 1),
        dark: NSColor(srgbRed: 52 / 255, green: 52 / 255, blue: 58 / 255, alpha: 1)
    )
    static let hoverSurface = adaptive(
        light: NSColor(srgbRed: 240 / 255, green: 241 / 255, blue: 247 / 255, alpha: 1),
        dark: NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 64 / 255, alpha: 1)
    )
    static let separator = adaptive(
        light: NSColor(srgbRed: 217 / 255, green: 220 / 255, blue: 226 / 255, alpha: 1),
        dark: NSColor(srgbRed: 64 / 255, green: 64 / 255, blue: 71 / 255, alpha: 1)
    )
    static let secondaryText = adaptive(
        light: NSColor(srgbRed: 108 / 255, green: 108 / 255, blue: 116 / 255, alpha: 1),
        dark: NSColor(srgbRed: 167 / 255, green: 167 / 255, blue: 175 / 255, alpha: 1)
    )
    static let accent = adaptive(
        light: NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 27 / 255, alpha: 1),
        dark: NSColor(srgbRed: 242 / 255, green: 241 / 255, blue: 237 / 255, alpha: 1)
    )
    static let accentSoft = adaptive(
        light: NSColor(srgbRed: 227 / 255, green: 227 / 255, blue: 222 / 255, alpha: 1),
        dark: NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 46 / 255, alpha: 1)
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

// MARK: - Main window tokens

extension AssistantTheme {
    /// Sidebar width. Wide enough for the longest destination plus its count,
    /// narrow enough that the content canvas keeps the window's centre of gravity.
    static let sidebarWidth: CGFloat = 196

    /// Height of the transparent titlebar strip the content view extends under.
    static let titleBarInset: CGFloat = 28

    /// Below this content width the context checklist folds to a single column.
    static let contentCompactWidthThreshold: CGFloat = 720

    static let dockCornerRadius: CGFloat = 18
    /// Concentric with the dock: outer radius minus the inset of the chip.
    static let dockChipCornerRadius: CGFloat = 9

    /// The reading canvas. Opaque and a touch warm, so text sits on paper rather
    /// than on a lit surface. Never glass.
    static let canvas = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 33 / 255, alpha: 1)
    )

    /// Flat planes used by the dense planning workspace. Information is grouped
    /// by rules and alignment first; these fills only distinguish hierarchy.
    static let workspacePanel = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 38 / 255, green: 39 / 255, blue: 44 / 255, alpha: 1)
    )
    static let workspaceMuted = adaptive(
        light: NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 249 / 255, alpha: 1),
        dark: NSColor(srgbRed: 34 / 255, green: 35 / 255, blue: 40 / 255, alpha: 1)
    )
    static let workspaceHeader = adaptive(
        light: NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 251 / 255, alpha: 1),
        dark: NSColor(srgbRed: 31 / 255, green: 32 / 255, blue: 36 / 255, alpha: 1)
    )

    static let calendarBlue = adaptive(
        light: NSColor(srgbRed: 68 / 255, green: 112 / 255, blue: 218 / 255, alpha: 1),
        dark: NSColor(srgbRed: 120 / 255, green: 156 / 255, blue: 1, alpha: 1)
    )
    static let calendarBlueSoft = adaptive(
        light: NSColor(srgbRed: 232 / 255, green: 239 / 255, blue: 253 / 255, alpha: 1),
        dark: NSColor(srgbRed: 42 / 255, green: 54 / 255, blue: 79 / 255, alpha: 1)
    )
    static let calendarTeal = adaptive(
        light: NSColor(srgbRed: 29 / 255, green: 139 / 255, blue: 132 / 255, alpha: 1),
        dark: NSColor(srgbRed: 83 / 255, green: 202 / 255, blue: 191 / 255, alpha: 1)
    )
    static let calendarTealSoft = adaptive(
        light: NSColor(srgbRed: 226 / 255, green: 246 / 255, blue: 243 / 255, alpha: 1),
        dark: NSColor(srgbRed: 35 / 255, green: 63 / 255, blue: 61 / 255, alpha: 1)
    )
    static let calendarViolet = adaptive(
        light: NSColor(srgbRed: 112 / 255, green: 90 / 255, blue: 190 / 255, alpha: 1),
        dark: NSColor(srgbRed: 167 / 255, green: 146 / 255, blue: 238 / 255, alpha: 1)
    )
    static let calendarVioletSoft = adaptive(
        light: NSColor(srgbRed: 239 / 255, green: 235 / 255, blue: 250 / 255, alpha: 1),
        dark: NSColor(srgbRed: 53 / 255, green: 45 / 255, blue: 70 / 255, alpha: 1)
    )
    static let calendarAmberSoft = adaptive(
        light: NSColor(srgbRed: 250 / 255, green: 241 / 255, blue: 220 / 255, alpha: 1),
        dark: NSColor(srgbRed: 67 / 255, green: 53 / 255, blue: 34 / 255, alpha: 1)
    )

    /// Structure inside the canvas: row rules and the column gutter. Barely there
    /// on purpose — whitespace carries the hierarchy, lines only confirm it.
    static let contentHairline = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
    )

    /// Boundary between the sidebar material and the canvas.
    static let sidebarEdge = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.11),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42)
    )

    static let rowHover = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.035),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)
    )

    static let glassHairline = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16)
    )

    static let glassSpecular = adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)
    )

    /// Slight lift blended over the blur so the dock reads as a control layer and
    /// not as a hole in the canvas.
    static let dockLift = adaptive(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05)
    )

    /// Reduce Transparency substitute for the dock's glass.
    static let dockOpaqueSurface = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 48 / 255, alpha: 1)
    )

    static let dockChip = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.04),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
    )

    static let dockChipHover = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
    )

    static let dockChipStroke = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
    )

    static let dockShadow = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.13),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42)
    )

    static let dockContactShadow = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
        dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
    )

    static let amber = adaptive(
        light: NSColor(srgbRed: 176 / 255, green: 106 / 255, blue: 12 / 255, alpha: 1),
        dark: NSColor(srgbRed: 1, green: 184 / 255, blue: 92 / 255, alpha: 1)
    )

    /// Destination tints. Colour is how a macOS sidebar tells destinations apart
    /// at a glance; the symbol carries the meaning, the tint carries the address.
    static func sidebarTint(for screen: AppScreen) -> Color {
        switch screen {
        case .setup: accent
        case .contexts: accent
        case .recordings: accent
        case .settings: secondaryText
        }
    }
}

// MARK: - Live workspace tokens

extension AssistantTheme {
    /// Backdrop scrim for the floating live panel. Kept deliberately dense:
    /// the panel floats over arbitrary screen content and transcript text has
    /// to stay legible regardless of what is behind it.
    static let liveBackdrop = Color(red: 11 / 255, green: 12 / 255, blue: 16 / 255).opacity(0.84)

    /// Reduce Transparency variant of the backdrop: same hue, no see-through.
    static let liveBackdropOpaque = Color(red: 11 / 255, green: 12 / 255, blue: 16 / 255)

    /// The transcript reading plate. Calm and near-opaque — glass never lands here.
    static let liveStage = Color(red: 17 / 255, green: 18 / 255, blue: 23 / 255).opacity(0.95)

    /// Flat fill substituted for every glass layer under Reduce Transparency.
    static let liveOpaqueSurface = Color(red: 30 / 255, green: 31 / 255, blue: 38 / 255)

    static let liveHairline = Color.white.opacity(0.13)
    static let liveAmber = Color(red: 1, green: 0.72, blue: 0.36)

    static let liveWorkspaceCornerRadius: CGFloat = 20
    static let liveCompactWidthThreshold: CGFloat = 900

    /// Speaker identity is carried by colour and an SF Symbol, never a portrait.
    static func tone(for track: AudioTrack) -> Color {
        switch track {
        case .incoming: liveAccent
        case .outgoing: liveGreen
        }
    }

    static func speakerTitle(for track: AudioTrack) -> String {
        switch track {
        case .incoming: "Собеседник"
        case .outgoing: "Вы"
        }
    }

    static func speakerGlyph(for track: AudioTrack) -> String {
        switch track {
        case .incoming: "speaker.wave.2.fill"
        case .outgoing: "mic.fill"
        }
    }
}
