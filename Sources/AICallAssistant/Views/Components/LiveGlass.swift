import AppKit
import SwiftUI

/// Liquid Glass primitives for the live workspace.
///
/// macOS 26 renders real `glassEffect` surfaces. Earlier systems fall back to a
/// native blur material with a hairline edge so the layout, hierarchy and
/// spacing stay identical across every supported release.
///
/// Glass is chrome only: navigation, status capsules, floating controls and the
/// call timeline. The transcript reading plate is deliberately excluded.
struct LiveGlassSurface<S: InsettableShape>: ViewModifier {
    enum Weight {
        /// Persistent chrome: toolbar, rail, timeline.
        case regular
        /// Small capsules that should let the backdrop through.
        case clear
    }

    let shape: S
    var weight: Weight = .regular
    var tint: Color?
    var isInteractive = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(shape.fill(opaqueFill))
                .overlay(shape.strokeBorder(AssistantTheme.liveHairline, lineWidth: 1))
        } else {
            glassOrFallback(content: content)
        }
    }

#if compiler(>=6.2)
    @ViewBuilder
    private func glassOrFallback(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(resolvedGlass, in: shape)
        } else {
            fallback(content: content)
        }
    }

    @available(macOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass: Glass = weight == .clear ? .clear : .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if isInteractive {
            glass = glass.interactive()
        }
        return glass
    }
#else
    @ViewBuilder
    private func glassOrFallback(content: Content) -> some View {
        fallback(content: content)
    }
#endif

    private func fallback(content: Content) -> some View {
        content
            .background(shape.fill(tint?.opacity(0.16) ?? Color.white.opacity(0.05)))
            .background(shape.fill(fallbackMaterial))
            .overlay(shape.strokeBorder(AssistantTheme.liveHairline, lineWidth: 1))
    }

    private var fallbackMaterial: Material {
        weight == .clear ? .ultraThinMaterial : .regularMaterial
    }

    /// Reduce Transparency replaces every glass layer with a flat, opaque fill
    /// so contrast no longer depends on whatever sits behind the panel.
    private var opaqueFill: Color {
        guard let tint else { return AssistantTheme.liveOpaqueSurface }
        return AssistantTheme.liveOpaqueSurface.opacity(0.92)
            .blended(with: tint, amount: 0.22)
    }
}

extension View {
    func liveGlass<S: InsettableShape>(
        in shape: S,
        weight: LiveGlassSurface<S>.Weight = .regular,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            LiveGlassSurface(
                shape: shape,
                weight: weight,
                tint: tint,
                isInteractive: interactive
            )
        )
    }

    func liveGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        liveGlass(in: Capsule(style: .continuous), weight: .clear, tint: tint, interactive: interactive)
    }

    func liveGlassPanel(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        liveGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint)
    }

    /// Chip style for controls nested *inside* a glass surface. Glass layered on
    /// glass reads as nothing at all, so these get a flat inset fill and a
    /// hairline instead — quieter, and legible on every macOS version.
    func liveInsetCapsule(tint: Color? = nil) -> some View {
        background(
            Capsule(style: .continuous)
                .fill(tint?.opacity(0.22) ?? Color.white.opacity(0.06))
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tint?.opacity(0.4) ?? Color.white.opacity(0.11), lineWidth: 1)
        }
    }
}

/// Merges sibling glass surfaces so they blend instead of stacking edges.
/// Transparent no-op before macOS 26.
struct LiveGlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
#else
        content
#endif
    }
}

/// Plain button chrome that presses without animating when Reduce Motion is on.
struct LiveGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Call-relative timecodes shown in the transcript gutter and the timeline.
enum LiveTimecode {
    static func text(callNanoseconds: UInt64) -> String {
        text(TimeInterval(callNanoseconds) / 1_000_000_000)
    }

    static func text(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// Spoken form for VoiceOver, which reads "04:35" as a number otherwise.
    static func spokenText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let minutes = total / 60
        let seconds = total % 60
        return "\(minutes) мин \(seconds) с"
    }
}

extension Color {
    /// Straight sRGB mix, used only to keep Reduce Transparency fills tinted.
    fileprivate func blended(with other: Color, amount: Double) -> Color {
        let clamped = min(max(amount, 0), 1)
        let base = NSColor(self).usingColorSpace(.sRGB)
        let overlay = NSColor(other).usingColorSpace(.sRGB)
        guard let base, let overlay else { return self }
        return Color(
            .sRGB,
            red: Double(base.redComponent) * (1 - clamped) + Double(overlay.redComponent) * clamped,
            green: Double(base.greenComponent) * (1 - clamped) + Double(overlay.greenComponent) * clamped,
            blue: Double(base.blueComponent) * (1 - clamped) + Double(overlay.blueComponent) * clamped,
            opacity: Double(base.alphaComponent)
        )
    }
}

extension View {
    /// `onChange` that uses the modern two-parameter closure where available and
    /// the macOS 13 signature otherwise, so the live UI stays warning-free.
    @ViewBuilder
    func onValueChange<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}
