import AppKit
import SwiftUI

/// Owns the always-on-top assistant workspace shown while a call is in progress.
///
/// The controller accepts any SwiftUI root view. The caller can invoke `finish()`
/// from that view's end-call action; `onFinish` is then called after the normal
/// application window has been restored.
@MainActor
final class LivePanelController: NSObject, NSWindowDelegate {
    nonisolated static let defaultSize = CGSize(width: 1080, height: 720)
    nonisolated static let minimumSize = CGSize(width: 720, height: 680)

    private var panel: LiveSidecarPanel?
    private weak var hiddenMainWindow: NSWindow?
    private var shouldRestoreMainWindow = false
    private var finishHandler: (() -> Void)?
    private var isFinishing = false

    var isPresented: Bool {
        panel?.isVisible == true
    }

    /// Presents a native floating panel containing `rootView`.
    ///
    /// - Parameters:
    ///   - rootView: Any SwiftUI view used as the complete live-assistant UI.
    ///   - preferredSize: Initial panel size before it is constrained to the screen.
    ///   - mainWindow: Window to hide for the duration of the call. When omitted,
    ///     the current key/main application window is selected automatically.
    ///   - onFinish: Called once when `finish()` is invoked or the panel closes.
    func present<Content: View>(
        rootView: Content,
        preferredSize: CGSize = LivePanelController.defaultSize,
        hiding mainWindow: NSWindow? = nil,
        onFinish: @escaping () -> Void = {}
    ) {
        if panel != nil {
            dismissPanel(restoreMainWindow: false, notify: false)
        }

        isFinishing = false
        finishHandler = onFinish

        let windowToHide = mainWindow ?? candidateMainWindow()
        hiddenMainWindow = windowToHide
        shouldRestoreMainWindow = windowToHide?.isVisible == true
        if shouldRestoreMainWindow {
            windowToHide?.orderOut(nil)
        }

        let content = LivePanelClearContainer(content: rootView)
        let hostingController = NSHostingController(rootView: content)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        let panel = makePanel(preferredSize: preferredSize)
        panel.delegate = self
        panel.contentViewController = hostingController
        self.panel = panel

        position(panel, near: windowToHide)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Ends the live session, restores the main window, and invokes `onFinish` once.
    func finish() {
        dismissPanel(restoreMainWindow: true, notify: true)
    }

    /// Hides the panel and restores the main window without treating it as a
    /// completed call. Useful when the owning app is shutting down or resetting.
    func cancel() {
        dismissPanel(restoreMainWindow: true, notify: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, !isFinishing else { return }
        dismissPanel(restoreMainWindow: true, notify: true)
    }

    private func makePanel(preferredSize: CGSize) -> LiveSidecarPanel {
        let panel = LiveSidecarPanel(
            contentRect: NSRect(origin: .zero, size: preferredSize),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Best-effort for legacy capture paths. Modern ScreenCaptureKit-based
        // full-display sharing may still include the panel.
        panel.sharingType = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(
            width: LivePanelController.minimumSize.width,
            height: LivePanelController.minimumSize.height
        )

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        return panel
    }

    private func position(_ panel: NSPanel, near mainWindow: NSWindow?) {
        let screen = mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        // The workspace is large enough that a screen corner reads as cramped.
        // Centre it horizontally and bias it upward, clamping to the screen so
        // the panel still fits on a small display.
        let margin: CGFloat = 24
        let available = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(panel.frame.width, max(LivePanelController.minimumSize.width, available.width))
        let height = min(panel.frame.height, max(LivePanelController.minimumSize.height, available.height))
        let origin = NSPoint(
            x: max(visibleFrame.minX + margin, visibleFrame.midX - width / 2),
            y: min(
                visibleFrame.maxY - height - margin,
                visibleFrame.midY - height / 2 + visibleFrame.height * 0.06
            )
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    private func candidateMainWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow, !(keyWindow is NSPanel) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, !(mainWindow is NSPanel) {
            return mainWindow
        }
        return NSApp.windows.first { window in
            window.isVisible && !(window is NSPanel)
        }
    }

    private func dismissPanel(restoreMainWindow: Bool, notify: Bool) {
        guard !isFinishing else { return }
        isFinishing = true

        let callback = notify ? finishHandler : nil
        finishHandler = nil

        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil

        if restoreMainWindow, shouldRestoreMainWindow, let mainWindow = hiddenMainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        hiddenMainWindow = nil
        shouldRestoreMainWindow = false
        isFinishing = false
        callback?()
    }
}

private final class LiveSidecarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct LivePanelClearContainer<Content: View>: View {
    let content: Content

    var body: some View {
        content
        .environment(\.colorScheme, .dark)
    }
}
