import AppKit

/// Applies AppKit's window-capture exclusion flag to every window owned by the app.
///
/// The flag is intentionally reapplied because AppKit or window recreation can reset
/// it. This is still best-effort on modern macOS: third-party full-display capture
/// based on ScreenCaptureKit can ignore `NSWindow.SharingType.none`.
@MainActor
final class WindowCaptureProtectionController: NSObject {
    nonisolated static let reapplyIntervalNanoseconds: UInt64 = 500_000_000

    private let windowsProvider: @MainActor () -> [NSWindow]
    private let notificationCenter: NotificationCenter
    private let intervalNanoseconds: UInt64

    private var reapplyTask: Task<Void, Never>?
    private(set) var isRunning = false

    init(
        windowsProvider: @MainActor @escaping () -> [NSWindow] = { NSApplication.shared.windows },
        notificationCenter: NotificationCenter = .default,
        intervalNanoseconds: UInt64 = WindowCaptureProtectionController.reapplyIntervalNanoseconds
    ) {
        self.windowsProvider = windowsProvider
        self.notificationCenter = notificationCenter
        self.intervalNanoseconds = intervalNanoseconds
        super.init()
    }

    /// Starts app-wide protection. Calling this more than once is safe.
    func start() {
        protectAllWindows()
        guard !isRunning else { return }

        isRunning = true
        observeWindowLifecycle()
        startPeriodicReapplication()
    }

    /// Stops observers and periodic reapplication. Calling this more than once is safe.
    func stop() {
        guard isRunning else { return }

        isRunning = false
        notificationCenter.removeObserver(self)
        reapplyTask?.cancel()
        reapplyTask = nil
    }

    /// Reapplies protection after a capture flag has been reset.
    /// Internal so the periodic behavior can be verified without timing-based tests.
    func reapplyProtection() {
        guard isRunning else { return }
        protectAllWindows()
    }

    private func protectAllWindows() {
        windowsProvider().forEach(Self.protect)
    }

    private static func protect(_ window: NSWindow) {
        window.sharingType = .none
    }

    private func observeWindowLifecycle() {
        let names: [Notification.Name] = [
            NSApplication.didUpdateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didUpdateNotification,
            NSWindow.willBeginSheetNotification
        ]

        for name in names {
            notificationCenter.addObserver(
                self,
                selector: #selector(handleWindowEvent(_:)),
                name: name,
                object: nil
            )
        }
    }

    private func startPeriodicReapplication() {
        let intervalNanoseconds = self.intervalNanoseconds
        reapplyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    return
                }

                guard let self else { return }
                self.reapplyProtection()
            }
        }
    }

    @objc
    private func handleWindowEvent(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            Self.protect(window)
        }
        protectAllWindows()
    }
}
