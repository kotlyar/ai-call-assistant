import AppKit
import SwiftUI

/// Tokens that belong to the main window and nowhere else.
///
/// Kept out of `AssistantTheme` on purpose: the shared palette is shared with the
/// live panel and the sheets, and the breakpoints below are decisions about one
/// window's layout rather than about the app's colour language.
enum MainWindowTheme {
    // MARK: Layout

    // One fixed page grid for every primary surface in the 900×800 window.
    // Keeping these metrics here prevents Setup and Settings from drifting
    // into two subtly different design systems.
    static let contentMaxWidth: CGFloat = 1120
    static let pageHorizontalInset: CGFloat = 44
    static let pageTitleSize: CGFloat = 42
    static let pageTitleTracking: CGFloat = -1.5
    static let pageSubtitleSize: CGFloat = 17
    static let pageHeaderSpacing: CGFloat = 6
    static let pageHeaderTopInset: CGFloat = 30
    static let pageHeaderHeight: CGFloat = 106
    static let pageContentTopSpacing: CGFloat = 22
    static let sectionTitleSize: CGFloat = 25
    static let sectionTitleTracking: CGFloat = -0.5
    static let sectionSubtitleSize: CGFloat = 13
    static let titlebarHeight: CGFloat = 48
    static let titlebarHorizontalInset: CGFloat = 24
    static let toolbarControlSize: CGFloat = 28

    // Dark deck chrome. Setup and Settings share the complete surface role,
    // not only its fill: shape, edge and elevation are deliberately identical.
    static let deckHorizontalInset: CGFloat = 28
    static let deckHeaderHeight: CGFloat = 48
    static let deckHeaderControlSize: CGFloat = 28
    static let deckCornerRadius: CGFloat = 24
    static let deckStrokeWidth: CGFloat = 1
    static let deckShadowRadius: CGFloat = 24
    static let deckShadowY: CGFloat = 10

    // Settings uses a literal 4 pt grid. The model column consumes the first
    // two rows while the answer controls keep using the same 44 pt cadence.
    static let settingsGridRowHeight: CGFloat = 44
    static let settingsGridColumnGap: CGFloat = 48

    // MARK: Shape scale

    // A compact semantic radius scale. A role may grow with its control, but
    // screens never invent a nearby value of their own.
    static let radiusSmall: CGFloat = 8
    static let radiusControl: CGFloat = 10
    static let radiusField: CGFloat = 12
    static let radiusProminent: CGFloat = 14

    // MARK: Control scale

    static let controlHeight: CGFloat = 36
    static let fieldHeight: CGFloat = 44
    static let compactActionHeight: CGFloat = 32
    static let pageHeaderActionSize: CGFloat = 32
    static let prominentActionHeight: CGFloat = 52
    static let primaryActionWidth: CGFloat = 218
    static let primaryActionFontSize: CGFloat = 15
    static let statusDotSize: CGFloat = 7

    static let canvas = adaptive(
        light: NSColor(srgbRed: 244 / 255, green: 244 / 255, blue: 241 / 255, alpha: 1),
        dark: NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 28 / 255, alpha: 1)
    )

    static let titlebar = adaptive(
        light: NSColor(srgbRed: 241 / 255, green: 241 / 255, blue: 238 / 255, alpha: 0.96),
        dark: NSColor(srgbRed: 31 / 255, green: 31 / 255, blue: 30 / 255, alpha: 0.96)
    )

    static let deck = Color(red: 21 / 255, green: 22 / 255, blue: 21 / 255)
    static let deckText = Color(red: 244 / 255, green: 243 / 255, blue: 238 / 255)
    static let deckSecondary = Color(red: 153 / 255, green: 155 / 255, blue: 149 / 255)
    static let deckControl = Color.white.opacity(0.08)
    static let deckControlHover = Color.white.opacity(0.13)
    static let deckStroke = Color.white.opacity(0.06)
    static let deckShadow = Color.black.opacity(0.16)
    static let deckLevelActive = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let ready = adaptive(
        light: NSColor(srgbRed: 111 / 255, green: 156 / 255, blue: 119 / 255, alpha: 1),
        dark: NSColor(srgbRed: 134 / 255, green: 189 / 255, blue: 145 / 255, alpha: 1)
    )
    static let selectedRow = adaptive(
        light: NSColor(srgbRed: 227 / 255, green: 227 / 255, blue: 222 / 255, alpha: 1),
        dark: NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 46 / 255, alpha: 1)
    )
    static let controlSurface = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 46 / 255, alpha: 1)
    )
    static let controlSoft = adaptive(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.08)
    )
    static let controlBorder = adaptive(
        light: NSColor.black.withAlphaComponent(0.12),
        dark: NSColor.white.withAlphaComponent(0.11)
    )
    static let secondaryText = Color.secondary
    static let primaryAction = adaptive(
        light: NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 27 / 255, alpha: 1),
        dark: NSColor(srgbRed: 242 / 255, green: 241 / 255, blue: 237 / 255, alpha: 1)
    )

    /// Content width at which the context checklist earns its second column.
    ///
    /// Set above the width a minimum-size window can reach, so the reference
    /// window reads as two columns and every narrower window folds to one
    /// instead of squeezing two columns down to a table-like measure.
    static let checklistTwoColumnWidth: CGFloat = 800

    /// Safety net for the preflight dock: narrower than this it stacks rather
    /// than dropping controls. The window minimum keeps it out of reach in
    /// normal use — it exists so nothing important disappears if that changes.
    static let dockStackWidth: CGFloat = 660

    /// Selection plate for a sidebar row. Translucent rather than a flat fill:
    /// the sidebar is a real vibrancy material, and an opaque plate on top of it
    /// would sit there as a patch that never picks up what is behind the window.
    static let sidebarSelection = adaptive(
        light: NSColor(srgbRed: 230 / 255, green: 55 / 255, blue: 88 / 255, alpha: 0.10),
        dark: NSColor(srgbRed: 1, green: 92 / 255, blue: 122 / 255, alpha: 0.16)
    )

    /// Hover for an unselected sidebar row. Neutral, so hovering never previews
    /// the accent and reads as a half-made selection.
    static let sidebarHover = adaptive(
        light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.045),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Dock clearance

/// The height the floating preflight dock occupies at the foot of the canvas,
/// reported up to the window shell.
///
/// The dock floats, so anything else the window puts at the bottom edge — the
/// toast — has to be told how much room to leave. Measuring beats a constant
/// because the dock grows when it has to show an audio error.
struct PreflightDockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Publishes this view's height as the dock clearance for the window shell.
    func reportsPreflightDockHeight() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PreflightDockHeightKey.self,
                    value: proxy.size.height
                )
            }
            .accessibilityHidden(true)
        )
    }
}
