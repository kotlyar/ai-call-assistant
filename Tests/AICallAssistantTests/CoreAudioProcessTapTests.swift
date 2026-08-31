import XCTest
@testable import AICallAssistant

final class CoreAudioProcessTapTests: XCTestCase {
    func testStopBeforeStartIsIdempotent() async throws {
        let tap = CoreAudioProcessTap(scope: .systemAudio()) { _ in
            XCTFail("An idle tap must not deliver frames")
        }

        let firstDroppedCount = try await tap.stop()
        let secondDroppedCount = try await tap.stop()

        XCTAssertEqual(firstDroppedCount, 0)
        XCTAssertEqual(secondDroppedCount, 0)
    }

    func testScopeRetainsSpecificProcessIdentifiers() async throws {
        let tap = CoreAudioProcessTap(scope: .processes([101, 202])) { _ in
            XCTFail("An idle tap must not deliver frames")
        }

        let droppedCount = try await tap.stop()
        XCTAssertEqual(droppedCount, 0)
    }
}
