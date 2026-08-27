import AppKit
import SwiftUI

/// Chrome primitives for the main window.
///
/// The main window is deliberately the inverse of the live panel: the content
/// canvas is opaque and calm, and glass appears exactly once — on the preflight
/// dock that floats over it. Everything here exists to keep that rule cheap to
/// follow.

// MARK: - Native window materials

/// A real `NSVisualEffectView`, used for the sidebar column.
///
/// SwiftUI's `Material` cannot express `.sidebar`, and only the AppKit material
/// picks up the window-tinted, behind-window vibrancy the system uses for its
/// own sidebars. It also degrades to an opaque fill under Reduce Transparency
/// without any work on our side.
struct WindowMaterialBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = isEmphasized
    }
}

// MARK: - The one glass layer in the main window

/// The floating preflight dock surface.
///
/// macOS 26 gets real Liquid Glass. Everything earlier gets the closest native
/// equivalent: a blur material, a hairline perimeter, a specular top edge and a
/// soft contact shadow — same geometry, same hierarchy, no milky wash.
struct MainWindowGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        surface(content: content)
            .overlay {
                shape.strokeBorder(AssistantTheme.glassHairline, lineWidth: 1)
            }
            .overlay {
                // Specular highlight: light catching the top edge only, which is
                // what separates a floating control layer from a flat card.
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                AssistantTheme.glassSpecular,
                                AssistantTheme.glassSpecular.opacity(0)
                            ],
                            startPoint: .top,
                            endPoint: .center
                        ),
                        lineWidth: 1
                    )
            }
            .compositingGroup()
            .shadow(color: AssistantTheme.dockShadow, radius: 16, y: 7)
            .shadow(color: AssistantTheme.dockContactShadow, radius: 1.5, y: 1)
    }

    @ViewBuilder
    private func surface(content: Content) -> some View {
        if reduceTransparency {
            content.background(shape.fill(AssistantTheme.dockOpaqueSurface))
        } else {
            glassOrFallback(content: content)
        }
    }

#if compiler(>=6.2)
    @ViewBuilder
    private func glassOrFallback(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            fallback(content: content)
        }
    }
#else
    @ViewBuilder
    private func glassOrFallback(content: Content) -> some View {
        fallback(content: content)
    }
#endif

    private func fallback(content: Content) -> some View {
        content
            .background(shape.fill(AssistantTheme.dockLift))
            .background(shape.fill(.regularMaterial))
    }
}

extension View {
    /// The single substantial glass layer of the main window.
    func mainWindowGlass(cornerRadius: CGFloat) -> some View {
        modifier(
            MainWindowGlassSurface(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        )
    }

    /// Chip chrome for controls nested *inside* the dock. Glass on glass reads as
    /// nothing, so these get a flat inset fill and a hairline instead.
    func dockInsetChip<S: InsettableShape>(_ shape: S, isHighlighted: Bool = false) -> some View {
        background(shape.fill(isHighlighted ? AssistantTheme.dockChipHover : AssistantTheme.dockChip))
            .overlay(shape.strokeBorder(AssistantTheme.dockChipStroke, lineWidth: 1))
    }
}

// MARK: - Shared primary-window structure

/// The fixed title strip shared by every primary destination in the main window.
/// Keeping it as one view prevents small alignment changes when destinations swap.
struct MainWindowTitlebar<Actions: View>: View {
    private let actions: Actions

    init(@ViewBuilder actions: () -> Actions) {
        self.actions = actions()
    }

    var body: some View {
        ZStack {
            Text("Callya")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.88))

            HStack(spacing: 8) {
                Spacer()
                actions
            }
            .padding(.horizontal, MainWindowTheme.titlebarHorizontalInset)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: MainWindowTheme.titlebarHeight)
        .background(MainWindowTheme.titlebar)
        .background(MainWindowTrafficLightAlignment())
        .overlay(alignment: .bottom) {
            Hairline(color: AssistantTheme.contentHairline)
        }
    }
}

/// Canonical small heading used at the top of every dark deck.
struct MainWindowDeckEyebrow: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MainWindowTheme.deckSecondary)
            .lineLimit(1)
    }
}

/// The 48 pt header shared by the dark audio and API decks.
struct MainWindowDeckHeader<Trailing: View>: View {
    let title: String
    private let trailing: Trailing

    init(
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            MainWindowDeckEyebrow(title: title)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, MainWindowTheme.deckHorizontalInset)
        .frame(height: MainWindowTheme.deckHeaderHeight)
    }
}

extension MainWindowDeckHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// One status mark throughout the main window. Text always accompanies it;
/// the colour is never the sole carrier of state.
struct MainWindowStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(
                width: MainWindowTheme.statusDotSize,
                height: MainWindowTheme.statusDotSize
            )
            .shadow(color: color.opacity(0.22), radius: 3)
            .accessibilityHidden(true)
    }
}

/// One canonical page header for Setup, Settings and future primary surfaces.
struct MainWindowPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    private let trailing: Trailing

    init(
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            VStack(alignment: .leading, spacing: MainWindowTheme.pageHeaderSpacing) {
                Text(title)
                    .font(.system(size: MainWindowTheme.pageTitleSize, weight: .medium))
                    .tracking(MainWindowTheme.pageTitleTracking)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: MainWindowTheme.pageSubtitleSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 18)
            trailing
        }
        .frame(maxWidth: MainWindowTheme.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, MainWindowTheme.pageHorizontalInset)
        .padding(.top, MainWindowTheme.pageHeaderTopInset)
        .frame(
            maxWidth: .infinity,
            minHeight: MainWindowTheme.pageHeaderHeight,
            maxHeight: MainWindowTheme.pageHeaderHeight,
            alignment: .top
        )
        .background(MainWindowTheme.canvas)
    }
}

extension MainWindowPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

// MARK: - Shared control chrome

struct MainWindowToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? AssistantTheme.contentHairline : Color.clear,
                in: RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusSmall,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusSmall,
                    style: .continuous
                )
            )
    }
}

// MARK: - Shared surfaces

private struct MainWindowDeckSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: MainWindowTheme.deckCornerRadius,
            style: .continuous
        )

        content
            .background(MainWindowTheme.deck, in: shape)
            .overlay {
                shape.strokeBorder(
                    MainWindowTheme.deckStroke,
                    lineWidth: MainWindowTheme.deckStrokeWidth
                )
            }
            .shadow(
                color: MainWindowTheme.deckShadow,
                radius: MainWindowTheme.deckShadowRadius,
                y: MainWindowTheme.deckShadowY
            )
    }
}

private struct MainWindowFieldSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let castsShadow: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(MainWindowTheme.controlSurface, in: shape)
            .overlay {
                shape.strokeBorder(MainWindowTheme.controlBorder, lineWidth: 1)
            }
            .shadow(
                color: castsShadow ? Color.black.opacity(0.05) : .clear,
                radius: castsShadow ? 2 : 0,
                y: castsShadow ? 1 : 0
            )
    }
}

extension View {
    func mainWindowDeckSurface() -> some View {
        modifier(MainWindowDeckSurfaceModifier())
    }

    func mainWindowFieldSurface(
        cornerRadius: CGFloat = MainWindowTheme.radiusField,
        castsShadow: Bool = false
    ) -> some View {
        modifier(
            MainWindowFieldSurfaceModifier(
                cornerRadius: cornerRadius,
                castsShadow: castsShadow
            )
        )
    }

    /// Keeps keyboard focus while allowing controls to draw the shared,
    /// neutral focus treatment instead of the system-blue halo.
    @ViewBuilder
    func mainWindowFocusEffectDisabled() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

// MARK: - Native window controls

/// Aligns the native traffic lights to the real centre of our 48 pt title
/// strip. Coordinate conversion keeps this correct across backing scales and
/// macOS versions while retaining the standard NSWindow buttons themselves.
private struct MainWindowTrafficLightAlignment: NSViewRepresentable {
    func makeNSView(context: Context) -> TrafficLightAnchorView {
        TrafficLightAnchorView()
    }

    func updateNSView(_ nsView: TrafficLightAnchorView, context: Context) {
        nsView.scheduleAlignment()
    }
}

private final class TrafficLightAnchorView: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowGeometry()
        scheduleAlignment()
    }

    override func layout() {
        super.layout()
        scheduleAlignment()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func scheduleAlignment() {
        DispatchQueue.main.async { [weak self] in
            self?.alignTrafficLights()
        }
    }

    private func observeWindowGeometry() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        guard let window else { return }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleAlignment()
            }
        }
    }

    private func alignTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        let kinds: [NSWindow.ButtonType] = [
            .closeButton,
            .miniaturizeButton,
            .zoomButton
        ]
        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let closeSuperview = closeButton.superview
        else { return }

        // Native hidden-titlebar windows begin the close button at 9 pt,
        // while our right-side toolbar uses the 24 pt design-system inset.
        // Move the entire native cluster by one shared delta so its internal
        // spacing remains exactly AppKit's.
        let closeRectInTitleStrip = convert(closeButton.frame, from: closeSuperview)
        let horizontalDelta =
            MainWindowTheme.titlebarHorizontalInset - closeRectInTitleStrip.minX

        for kind in kinds {
            guard
                let button = window.standardWindowButton(kind),
                let buttonSuperview = button.superview
            else { continue }

            let titleStrip = convert(bounds, to: buttonSuperview)
            let targetY = titleStrip.midY - button.bounds.height / 2
            let targetX = button.frame.minX + horizontalDelta
            guard
                abs(button.frame.minX - targetX) > 0.25
                    || abs(button.frame.minY - targetY) > 0.25
            else { continue }
            button.setFrameOrigin(NSPoint(x: targetX, y: targetY))
        }
    }
}

/// Plain button chrome that presses without animating under Reduce Motion.
struct QuietButtonStyle: ButtonStyle {
    var pressedOpacity: Double = 0.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A 1 pt rule that stays a hairline at any backing scale.
struct Hairline: View {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis = .horizontal
    var color: Color = AssistantTheme.contentHairline
    var length: CGFloat?

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .vertical ? 1 : length,
                height: axis == .vertical ? length : 1
            )
            .accessibilityHidden(true)
    }
}
