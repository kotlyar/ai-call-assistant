import XCTest
@testable import AICallAssistant

final class RealtimeTrackStatusPresentationTests: XCTestCase {
    func testDegradedTrackRemainsVisuallyActiveAndShowsGapWarning() {
        let presentation = RealtimeTrackStatusPresentation(.degraded)

        XCTAssertEqual(presentation.indicatorTone, .active)
        XCTAssertEqual(presentation.statusText, "live, были пропуски")
        XCTAssertEqual(presentation.indicatorHelp, "Live-распознавание работает.")
        XCTAssertEqual(
            presentation.warning,
            "Распознавание работает, но часть аудио могла быть пропущена."
        )
    }

    func testLiveTrackIsActiveWithoutWarning() {
        let presentation = RealtimeTrackStatusPresentation(.live)

        XCTAssertEqual(presentation.indicatorTone, .active)
        XCTAssertEqual(presentation.statusText, "live")
        XCTAssertEqual(presentation.indicatorHelp, "Live-распознавание работает.")
        XCTAssertNil(presentation.warning)
    }

    func testNonOperationalStatusesDoNotUseActiveTone() {
        XCTAssertEqual(
            RealtimeTrackStatusPresentation(.connecting).indicatorTone,
            .pending
        )
        XCTAssertEqual(
            RealtimeTrackStatusPresentation(.reconnecting).indicatorTone,
            .pending
        )
        XCTAssertEqual(
            RealtimeTrackStatusPresentation(.budgetStopped).indicatorTone,
            .warning
        )
        XCTAssertEqual(
            RealtimeTrackStatusPresentation(.failed).indicatorTone,
            .error
        )
    }
}
