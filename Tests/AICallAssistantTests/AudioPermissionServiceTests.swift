import XCTest
@testable import AICallAssistant

@MainActor
final class AudioPermissionServiceTests: XCTestCase {
    func testInitialUnknownStateCanBeRequestedAndRetriedAfterDenial() async {
        var requestCount = 0
        let service = SystemAudioPermissionService(
            systemAudioAccessProbe: {
                requestCount += 1
                return .denied
            }
        )

        XCTAssertEqual(service.currentSnapshot().systemAudio, .notDetermined)
        let firstRequest = await service.request(.systemAudio)
        XCTAssertEqual(firstRequest, .denied)
        XCTAssertEqual(service.currentSnapshot().systemAudio, .denied)

        let retry = await service.request(.systemAudio)
        XCTAssertEqual(retry, .denied)
        XCTAssertEqual(requestCount, 2)
    }

    func testAcceptedProbeRemainsAuthorizedForCurrentProcess() async {
        let service = SystemAudioPermissionService(
            systemAudioAccessProbe: { .authorized }
        )

        let request = await service.request(.systemAudio)
        XCTAssertEqual(request, .authorized)
        XCTAssertEqual(service.currentSnapshot().systemAudio, .authorized)

        XCTAssertEqual(service.currentSnapshot().systemAudio, .authorized)
    }

    func testTransientProbeFailureStaysRetryable() async {
        var requestCount = 0
        let service = SystemAudioPermissionService(
            systemAudioAccessProbe: {
                requestCount += 1
                return requestCount == 1 ? .notDetermined : .authorized
            }
        )

        XCTAssertEqual(service.currentSnapshot().systemAudio, .notDetermined)
        let firstRequest = await service.request(.systemAudio)
        XCTAssertEqual(firstRequest, .notDetermined)
        XCTAssertEqual(service.currentSnapshot().systemAudio, .notDetermined)
        let retry = await service.request(.systemAudio)
        XCTAssertEqual(retry, .authorized)
        XCTAssertEqual(service.currentSnapshot().systemAudio, .authorized)
    }

    func testSystemAudioSettingsUsesAudioCapturePrivacyPane() {
        var openedURL: URL?
        let service = SystemAudioPermissionService(
            systemAudioAccessProbe: { .authorized },
            settingsURLOpener: { openedURL = $0 }
        )

        service.openSettings(for: .systemAudio)

        XCTAssertEqual(
            openedURL?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        )
    }
}
