@preconcurrency import CoreMedia
import XCTest
@testable import AICallAssistant

final class CaptureTimelineTests: XCTestCase {
    func testNilSynchronizationClockUsesValidHostBasedPTSForLiveAndWriterTiming() throws {
        let timeline = CaptureTimeline()
        timeline.activate(atHostTime: CMTime(value: 10, timescale: 1))
        let sampleBuffer = try makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 41, timescale: 4),
            duration: CMTime(value: 1, timescale: 100)
        )

        XCTAssertEqual(
            timeline.callRelativePresentationNanoseconds(sampleBuffer, from: nil),
            250_000_000
        )
        let retimed = try XCTUnwrap(
            timeline.retimedBuffer(sampleBuffer, from: nil)
        )
        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(retimed),
            CMTime(value: 1, timescale: 4)
        )
        XCTAssertEqual(
            CMSampleBufferGetDuration(retimed),
            CMTime(value: 1, timescale: 100)
        )
    }

    func testNilSynchronizationClockRejectsPTSFromBeforeCallOrigin() throws {
        let timeline = CaptureTimeline()
        timeline.activate(atHostTime: CMTime(value: 10, timescale: 1))
        let sampleBuffer = try makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 9, timescale: 1),
            duration: CMTime(value: 1, timescale: 100)
        )

        XCTAssertNil(
            timeline.callRelativePresentationNanoseconds(sampleBuffer, from: nil)
        )
        XCTAssertNil(try timeline.retimedBuffer(sampleBuffer, from: nil))
        XCTAssertFalse(timeline.isStartupPreroll(sampleBuffer, from: nil))
    }

    func testShortPacketImmediatelyBeforeOriginIsClassifiedAsStartupPreroll() throws {
        let timeline = CaptureTimeline()
        timeline.activate(atHostTime: CMTime(value: 10_000, timescale: 1_000))
        let sampleBuffer = try makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 9_980, timescale: 1_000),
            duration: CMTime(value: 20, timescale: 1_000)
        )

        XCTAssertNil(
            timeline.callRelativePresentationNanoseconds(sampleBuffer, from: nil)
        )
        XCTAssertTrue(timeline.isStartupPreroll(sampleBuffer, from: nil))
    }

    private func makeSampleBuffer(
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: nil,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
