import XCTest
@testable import AICallAssistant

@MainActor
final class AudioPermissionServiceTests: XCTestCase {
    func testInitialUnknownStateCanBeRequestedAndRetriedAfterDenial() async {
        var requestCount = 0
        let service = SystemAudioPermissionService(
            preflightSystemAudioAccess: { false },
            requestSystemAudioAccess: {
                requestCount += 1
                return false
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

    func testAcceptedRequestIsNotImmediatelyDowngradedByLaggingPreflight() async {
        var preflightGranted = false
        let service = SystemAudioPermissionService(
            preflightSystemAudioAccess: { preflightGranted },
            requestSystemAudioAccess: { true }
        )

        let request = await service.request(.systemAudio)
        XCTAssertEqual(request, .authorized)
        XCTAssertEqual(service.currentSnapshot().systemAudio, .authorized)

        preflightGranted = true
        XCTAssertEqual(service.currentSnapshot().systemAudio, .authorized)
    }

    func testExternalGrantTransitionsToAuthorized() {
        var preflightGranted = false
        let service = SystemAudioPermissionService(
            preflightSystemAudioAccess: { preflightGranted },
            requestSystemAudioAccess: { false }
        )

        XCTAssertEqual(service.currentSnapshot().systemAudio, .notDetermined)
        preflightGranted = true
        XCTAssertEqual(service.currentSnapshot().systemAudio, .authorized)
    }
}
