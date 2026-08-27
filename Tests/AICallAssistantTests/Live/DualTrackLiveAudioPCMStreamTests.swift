@preconcurrency import CoreMedia
import Foundation
import XCTest
@testable import AICallAssistant

final class DualTrackLiveAudioPCMStreamTests: XCTestCase {
    func testProductionPolicyAbsorbsTwoSecondOutgoingConverterStall() async throws {
        let incoming = ControlledFrameConverter(track: .incoming)
        let outgoing = ControlledFrameConverter(
            track: .outgoing,
            freezeFirstConversion: true
        )
        let stream = DualTrackLiveAudioPCMStream(
            maxBufferedSourceFramesPerTrack: LiveAudioPCMStreamPolicy
                .productionMaxBufferedSourceFramesPerTrack,
            converterFactory: { track, _ in
                track == .incoming ? incoming : outgoing
            }
        ) { _ in }

        XCTAssertEqual(
            LiveAudioPCMStreamPolicy.productionMaxBufferedSourceFramesPerTrack,
            250
        )
        stream.offer(try makeFrame(index: 0, track: .outgoing))
        XCTAssertTrue(outgoing.waitUntilFirstConversionStarts())
        for index in 1...200 {
            stream.offer(try makeFrame(index: index, track: .outgoing))
        }

        outgoing.releaseFirstConversion()
        let report = await stream.finish()

        XCTAssertEqual(report.outgoing.acceptedSourceBuffers, 201)
        XCTAssertEqual(report.outgoing.droppedSourceBuffers, 0)
        XCTAssertEqual(report.outgoing.droppedAudioNanoseconds, 0)
        XCTAssertEqual(report.outgoing.discontinuities, 0)
        XCTAssertEqual(outgoing.conversionCount, 201)
    }

    func testProductionPolicyRemainsBoundedAtOutgoingBurstBoundary() async throws {
        let capacity = LiveAudioPCMStreamPolicy.productionMaxBufferedSourceFramesPerTrack
        let incoming = ControlledFrameConverter(track: .incoming)
        let outgoing = ControlledFrameConverter(
            track: .outgoing,
            freezeFirstConversion: true
        )
        let stream = DualTrackLiveAudioPCMStream(
            maxBufferedSourceFramesPerTrack: capacity,
            converterFactory: { track, _ in
                track == .incoming ? incoming : outgoing
            }
        ) { _ in }

        stream.offer(try makeFrame(index: 0, track: .outgoing))
        XCTAssertTrue(outgoing.waitUntilFirstConversionStarts())
        for index in 1...capacity {
            stream.offer(try makeFrame(index: index, track: .outgoing))
        }
        stream.offer(try makeFrame(index: capacity + 1, track: .outgoing))

        outgoing.releaseFirstConversion()
        await waitUntil { outgoing.conversionCount >= capacity + 1 }
        stream.offer(try makeFrame(index: capacity + 2, track: .outgoing))
        let report = await stream.finish()

        XCTAssertEqual(report.outgoing.acceptedSourceBuffers, capacity + 2)
        XCTAssertEqual(report.outgoing.droppedSourceBuffers, 1)
        XCTAssertEqual(report.outgoing.droppedAudioNanoseconds, 10_000_000)
        XCTAssertEqual(report.outgoing.discontinuities, 1)
        XCTAssertEqual(outgoing.conversionCount, capacity + 2)
    }

    func testFrozenConverterOverflowMarksNextAcceptedChunkAsDiscontinuous() async throws {
        let converter = ControlledFrameConverter(
            track: .incoming,
            freezeFirstConversion: true
        )
        let outgoing = ControlledFrameConverter(track: .outgoing)
        let recorder = LockedLiveChunks()
        let stream = DualTrackLiveAudioPCMStream(
            maxBufferedSourceFramesPerTrack: 1,
            converterFactory: { track, _ in
                track == .incoming ? converter : outgoing
            }
        ) { chunk in
            recorder.append(chunk)
        }

        stream.offer(try makeFrame(index: 0))
        XCTAssertTrue(converter.waitUntilFirstConversionStarts())
        stream.offer(try makeFrame(index: 1))
        stream.offer(try makeFrame(index: 2)) // deterministic pre-converter overflow
        converter.releaseFirstConversion()
        await waitUntil { converter.conversionCount >= 2 }
        stream.offer(try makeFrame(index: 3))

        let report = await stream.finish()
        let chunks = recorder.values.filter { $0.track == .incoming }

        XCTAssertEqual(report.incoming.acceptedSourceBuffers, 3)
        XCTAssertEqual(report.incoming.droppedSourceBuffers, 1)
        XCTAssertGreaterThan(report.incoming.droppedAudioNanoseconds, 0)
        XCTAssertEqual(report.incoming.discontinuities, 1)
        XCTAssertTrue(report.hasKnownGaps)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertFalse(chunks[0].discontinuityBefore)
        XCTAssertFalse(chunks[1].discontinuityBefore)
        XCTAssertTrue(chunks[2].discontinuityBefore)
        XCTAssertEqual(chunks[2].startCallNanoseconds, 30_000_000)
    }

    func testConversionFailureMarksFollowingChunkAsDiscontinuous() async throws {
        let converter = ControlledFrameConverter(
            track: .incoming,
            failFirstConversion: true
        )
        let outgoing = ControlledFrameConverter(track: .outgoing)
        let recorder = LockedLiveTimeline()
        let stream = DualTrackLiveAudioPCMStream(
            maxBufferedSourceFramesPerTrack: 4,
            converterFactory: { track, _ in
                track == .incoming ? converter : outgoing
            },
            onGap: { recorder.append(.gap($0)) }
        ) { chunk in
            recorder.append(.chunk(chunk))
        }

        stream.offer(try makeFrame(index: 0))
        stream.offer(try makeFrame(index: 1))

        let report = await stream.finish()
        let chunks = recorder.chunks.filter { $0.track == .incoming }
        let gaps = recorder.gaps.filter { $0.track == .incoming }

        XCTAssertEqual(report.incoming.conversionFailures, 1)
        XCTAssertEqual(report.incoming.discontinuities, 1)
        XCTAssertTrue(report.hasKnownGaps)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].startCallNanoseconds, 0)
        XCTAssertEqual(gaps[0].endCallNanoseconds, 10_000_000)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].discontinuityBefore)
        XCTAssertEqual(chunks[0].startCallNanoseconds, 10_000_000)
        XCTAssertEqual(
            recorder.values.map(\.kind),
            [.gap, .chunk],
            "The failed interval must be published before subsequent audio"
        )
    }

    func testAllConversionsFailCoalescesAndPublishesTerminalGapWithoutFollowingFrame() async throws {
        let converter = ControlledFrameConverter(
            track: .incoming,
            failEveryConversion: true
        )
        let outgoing = ControlledFrameConverter(track: .outgoing)
        let recorder = LockedLiveTimeline()
        let stream = DualTrackLiveAudioPCMStream(
            maxBufferedSourceFramesPerTrack: 4,
            converterFactory: { track, _ in
                track == .incoming ? converter : outgoing
            },
            onGap: { recorder.append(.gap($0)) }
        ) { chunk in
            recorder.append(.chunk(chunk))
        }

        stream.offer(try makeFrame(index: 0))
        stream.offer(try makeFrame(index: 1))

        let report = await stream.finish()
        let gaps = recorder.gaps.filter { $0.track == .incoming }
        let terminal = try XCTUnwrap(gaps.last)

        XCTAssertEqual(report.incoming.conversionFailures, 2)
        XCTAssertTrue(report.incoming.hasKnownGaps)
        XCTAssertTrue(recorder.chunks.isEmpty)
        XCTAssertEqual(Set(gaps.map(\.id)).count, 1)
        XCTAssertEqual(terminal.startCallNanoseconds, 0)
        XCTAssertEqual(terminal.endCallNanoseconds, 20_000_000)
    }

    func testTimestampMappingDropIsRetainedInTerminalMetricsWithoutFollowingFrame() async {
        let incoming = ControlledFrameConverter(track: .incoming)
        let outgoing = ControlledFrameConverter(track: .outgoing)
        let stream = DualTrackLiveAudioPCMStream(
            maxBufferedSourceFramesPerTrack: 4,
            converterFactory: { track, _ in
                track == .incoming ? incoming : outgoing
            }
        ) { _ in }

        stream.recordDroppedFrame(
            track: .outgoing,
            durationNanoseconds: 25_000_000
        )
        let report = await stream.finish()

        XCTAssertEqual(report.outgoing.droppedSourceBuffers, 1)
        XCTAssertEqual(report.outgoing.droppedAudioNanoseconds, 25_000_000)
        XCTAssertTrue(report.outgoing.hasKnownGaps)
        XCTAssertTrue(report.hasKnownGaps)
    }

    private func makeFrame(
        index: Int,
        track: AudioTrack = .incoming
    ) throws -> CapturedAudioFrame {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 10, timescale: 1_000),
            presentationTimeStamp: CMTime(value: CMTimeValue(index * 10), timescale: 1_000),
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
        return CapturedAudioFrame(
            track: track,
            sampleBuffer: try XCTUnwrap(sampleBuffer),
            startCallNanoseconds: UInt64(index) * 10_000_000
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let step: UInt64 = 1_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() { return }
            try? await Task.sleep(nanoseconds: step)
            elapsed += step
        }
        XCTFail("Timed out waiting for the converter")
    }
}

private final class ControlledFrameConverter: LiveAudioFrameConverting, @unchecked Sendable {
    private let track: AudioTrack
    private let freezeFirstConversion: Bool
    private let failFirstConversion: Bool
    private let failEveryConversion: Bool
    private let lock = NSLock()
    private let firstConversionStarted = DispatchSemaphore(value: 0)
    private let firstConversionRelease = DispatchSemaphore(value: 0)
    private var conversionCountStorage = 0
    private var forceNextDiscontinuity = false

    init(
        track: AudioTrack,
        freezeFirstConversion: Bool = false,
        failFirstConversion: Bool = false,
        failEveryConversion: Bool = false
    ) {
        self.track = track
        self.freezeFirstConversion = freezeFirstConversion
        self.failFirstConversion = failFirstConversion
        self.failEveryConversion = failEveryConversion
    }

    var conversionCount: Int {
        lock.withLock { conversionCountStorage }
    }

    func waitUntilFirstConversionStarts() -> Bool {
        firstConversionStarted.wait(timeout: .now() + 2) == .success
    }

    func releaseFirstConversion() {
        firstConversionRelease.signal()
    }

    func convert(_ frame: CapturedAudioFrame) throws -> [LivePCMChunk] {
        let call = lock.withLock { () -> Int in
            conversionCountStorage += 1
            return conversionCountStorage
        }
        if call == 1, freezeFirstConversion {
            firstConversionStarted.signal()
            firstConversionRelease.wait()
        }
        if failEveryConversion || (call == 1 && failFirstConversion) {
            throw ControlledConversionError.failed
        }
        let discontinuity = lock.withLock { () -> Bool in
            defer { forceNextDiscontinuity = false }
            return forceNextDiscontinuity
        }
        return [
            LivePCMChunk(
                track: track,
                sequence: UInt64(call - 1),
                startCallNanoseconds: frame.startCallNanoseconds,
                pcm16LittleEndian: Data(repeating: 0, count: 2),
                frameCount: 1,
                discontinuityBefore: discontinuity
            )
        ]
    }

    func finish() -> [LivePCMChunk] { [] }

    func forceDiscontinuityBeforeNextInput() -> [LivePCMChunk] {
        lock.withLock {
            forceNextDiscontinuity = true
        }
        return []
    }
}

private enum ControlledConversionError: Error {
    case failed
}

private final class LockedLiveChunks: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LivePCMChunk] = []

    var values: [LivePCMChunk] {
        lock.withLock { storage }
    }

    func append(_ chunk: LivePCMChunk) {
        lock.withLock {
            storage.append(chunk)
        }
    }
}

private enum RecordedLiveTimelineEvent: Equatable {
    enum Kind: Equatable {
        case gap
        case chunk
    }

    case gap(LiveAudioGap)
    case chunk(LivePCMChunk)

    var kind: Kind {
        switch self {
        case .gap: .gap
        case .chunk: .chunk
        }
    }
}

private final class LockedLiveTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedLiveTimelineEvent] = []

    var values: [RecordedLiveTimelineEvent] {
        lock.withLock { storage }
    }

    var gaps: [LiveAudioGap] {
        values.compactMap {
            guard case let .gap(gap) = $0 else { return nil }
            return gap
        }
    }

    var chunks: [LivePCMChunk] {
        values.compactMap {
            guard case let .chunk(chunk) = $0 else { return nil }
            return chunk
        }
    }

    func append(_ event: RecordedLiveTimelineEvent) {
        lock.withLock {
            storage.append(event)
        }
    }
}
