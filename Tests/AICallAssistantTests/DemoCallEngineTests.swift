import XCTest
@testable import AICallAssistant

@MainActor
final class DemoCallEngineTests: XCTestCase {
    func testAdvanceMovesCurrentMomentIntoNewestFirstHistory() {
        let engine = DemoCallEngine()

        engine.start()
        let first = engine.currentMoment
        engine.advance()

        XCTAssertEqual(engine.answerHistory.first?.moment, first)
        XCTAssertNotEqual(engine.currentMoment, first)
        engine.stop()
    }
}
