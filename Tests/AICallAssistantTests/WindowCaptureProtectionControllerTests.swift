import AppKit
import XCTest
@testable import AICallAssistant

@MainActor
final class WindowCaptureProtectionControllerTests: XCTestCase {
    func testStartImmediatelyProtectsAllExistingWindows() {
        let first = makeWindow()
        let second = makeWindow()
        let controller = makeController(windows: { [first, second] })

        controller.start()
        defer { controller.stop() }

        XCTAssertEqual(first.sharingType, .none)
        XCTAssertEqual(second.sharingType, .none)
    }

    func testWindowNotificationProtectsANewWindow() {
        let notificationCenter = NotificationCenter()
        var windows: [NSWindow] = []
        let controller = makeController(
            windows: { windows },
            notificationCenter: notificationCenter
        )
        controller.start()
        defer { controller.stop() }

        let window = makeWindow()
        windows.append(window)
        notificationCenter.post(name: NSWindow.didUpdateNotification, object: window)

        XCTAssertEqual(window.sharingType, .none)
    }

    func testReapplicationRestoresAResetFlag() {
        let window = makeWindow()
        let controller = makeController(windows: { [window] })
        controller.start()
        defer { controller.stop() }

        window.sharingType = .readOnly
        controller.reapplyProtection()

        XCTAssertEqual(window.sharingType, .none)
    }

    func testStartIsIdempotentAndStopDisablesReapplication() {
        let window = makeWindow()
        let controller = makeController(windows: { [window] })

        controller.start()
        controller.start()
        XCTAssertTrue(controller.isRunning)

        controller.stop()
        controller.stop()
        window.sharingType = .readOnly
        controller.reapplyProtection()

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(window.sharingType, .readOnly)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.sharingType = .readOnly
        return window
    }

    private func makeController(
        windows: @MainActor @escaping () -> [NSWindow],
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> WindowCaptureProtectionController {
        WindowCaptureProtectionController(
            windowsProvider: windows,
            notificationCenter: notificationCenter,
            intervalNanoseconds: 60_000_000_000
        )
    }
}
