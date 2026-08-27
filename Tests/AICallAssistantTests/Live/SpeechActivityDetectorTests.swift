import Foundation
import XCTest
@testable import AICallAssistant

final class SpeechActivityDetectorTests: XCTestCase {
    func testPreRollSpeechAndHangoverProduceOneTurn() {
        let stableID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var detector = SpeechActivityDetector(
            track: .incoming,
            makeTurnID: { stableID }
        )
        var events: [SpeechActivityEvent] = []

        for index in 0..<3 {
            events += detector.consume(chunk(index: index, amplitude: 0))
        }
        events += detector.consume(chunk(index: 3, amplitude: 8_000))
        events += detector.consume(chunk(index: 4, amplitude: 8_000))
        for index in 5..<11 {
            events += detector.consume(chunk(index: index, amplitude: 0))
        }

        let starts = events.compactMap { event -> (LocalAudioTurn, [LivePCMChunk])? in
            guard case let .started(turn, preRoll) = event else { return nil }
            return (turn, preRoll)
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].0.id, stableID)
        XCTAssertEqual(starts[0].1.first?.sequence, 2)
        XCTAssertEqual(starts[0].1.last?.sequence, 4)

        let endings = events.filter {
            if case .ended = $0 { return true }
            return false
        }
        XCTAssertEqual(endings.count, 1)
        if case let .ended(turnID, _, forced) = endings[0] {
            XCTAssertEqual(turnID, stableID)
            XCTAssertFalse(forced)
        }
    }

    func testDiscontinuityClosesActiveTurnBeforeNewDetection() {
        var detector = SpeechActivityDetector(track: .outgoing)
        _ = detector.consume(chunk(index: 0, amplitude: 9_000, track: .outgoing))
        _ = detector.consume(chunk(index: 1, amplitude: 9_000, track: .outgoing))

        let events = detector.consume(
            chunk(
                index: 20,
                amplitude: 9_000,
                track: .outgoing,
                discontinuity: true
            )
        )

        XCTAssertTrue(events.contains {
            if case let .ended(_, _, forced) = $0 { return forced }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .discontinuity = $0 { return true }
            return false
        })
    }

    func testForcedCommitBoundsLongSpeech() {
        var config = SpeechActivityConfiguration()
        config.forcedCommitMilliseconds = 500
        var detector = SpeechActivityDetector(track: .incoming, configuration: config)
        var events: [SpeechActivityEvent] = []
        for index in 0..<8 {
            events += detector.consume(chunk(index: index, amplitude: 10_000))
        }

        XCTAssertTrue(events.contains {
            if case let .ended(_, _, forced) = $0 { return forced }
            return false
        })
    }

    private func chunk(
        index: Int,
        amplitude: Int16,
        track: AudioTrack = .incoming,
        discontinuity: Bool = false
    ) -> LivePCMChunk {
        var value = amplitude.littleEndian
        let sample = withUnsafeBytes(of: &value) { Data($0) }
        var data = Data(capacity: 2_400 * 2)
        for _ in 0..<2_400 {
            data.append(sample)
        }
        return LivePCMChunk(
            track: track,
            sequence: UInt64(index),
            startCallNanoseconds: UInt64(index) * 100_000_000,
            pcm16LittleEndian: data,
            frameCount: 2_400,
            discontinuityBefore: discontinuity
        )
    }
}
