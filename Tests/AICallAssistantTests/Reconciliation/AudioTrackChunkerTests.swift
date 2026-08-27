import Foundation
import XCTest
@testable import AICallAssistant

final class AudioTrackChunkerTests: XCTestCase {
    func testDefaultDurationCapChunksCompressedLongTrackForCoarseTimeline() throws {
        let asset = ReconciliationAudioAsset(
            track: .incoming,
            fileURL: URL(fileURLWithPath: "/tmp/incoming-long.m4a"),
            sourceDurationNanoseconds: 95_000_000_000,
            sourceByteCount: 3_000_000,
            sourceSHA256: "compressed-long-track",
            callStartOffsetNanoseconds: 0
        )
        let chunker = AudioTrackChunker()

        let chunks = try chunker.chunks(
            callID: Self.callID,
            asset: asset,
            modelID: "gpt-transcribe"
        )
        let repeated = try chunker.chunks(
            callID: Self.callID,
            asset: asset,
            modelID: "gpt-transcribe"
        )

        XCTAssertEqual(chunks, repeated)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks.map(\.chunkerVersion), [2, 2, 2, 2])
        XCTAssertTrue(chunks.allSatisfy {
            $0.coverageRange.durationNanoseconds
                <= AudioTrackChunker.defaultMaximumCoverageChunkNanoseconds
        })
        XCTAssertTrue(chunks.allSatisfy {
            $0.estimatedUploadBytes < AudioTrackChunker.defaultMaximumUploadBytes
        })
        XCTAssertTrue(AudioTrackChunker.hasContinuousCoverage(
            chunks,
            sourceDurationNanoseconds: asset.sourceDurationNanoseconds
        ))
        XCTAssertGreaterThan(
            chunks.map(\.uploadRange.durationNanoseconds).reduce(0, +),
            asset.sourceDurationNanoseconds,
            "Boundary overlap must remain part of the upload plan"
        )
    }

    func testVADOnlyMovesBoundariesAndQuietIntervalsRemainCovered() throws {
        let asset = ReconciliationAudioAsset(
            track: .incoming,
            fileURL: URL(fileURLWithPath: "/tmp/incoming.m4a"),
            sourceDurationNanoseconds: 100,
            sourceByteCount: 1_000,
            sourceSHA256: "incoming-hash",
            callStartOffsetNanoseconds: 7
        )
        let chunker = AudioTrackChunker(
            maximumUploadBytes: 260,
            overlapNanoseconds: 10,
            preferredBoundaryLookbackNanoseconds: 10,
            minimumCoverageChunkNanoseconds: 1,
            version: 4
        )
        let speech = [
            AudioSourceRange(startNanoseconds: 0, endNanoseconds: 20),
            AudioSourceRange(startNanoseconds: 80, endNanoseconds: 100)
        ]

        let chunks = try chunker.chunks(
            callID: Self.callID,
            asset: asset,
            modelID: "file-model",
            preferredSpeechRanges: speech
        )
        let repeated = try chunker.chunks(
            callID: Self.callID,
            asset: asset,
            modelID: "file-model",
            preferredSpeechRanges: speech
        )

        XCTAssertEqual(chunks, repeated)
        XCTAssertTrue(AudioTrackChunker.hasContinuousCoverage(
            chunks,
            sourceDurationNanoseconds: asset.sourceDurationNanoseconds
        ))
        XCTAssertTrue(chunks.allSatisfy { $0.estimatedUploadBytes < 260 })
        XCTAssertTrue(chunks.contains { chunk in
            chunk.coverageRange.startNanoseconds >= 20
                && chunk.coverageRange.endNanoseconds <= 80
                && !chunk.vadClassifiedSpeech
        }, "A VAD-negative quiet interval must still be assigned to an upload")

        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(
                pair.0.coverageRange.endNanoseconds,
                pair.1.coverageRange.startNanoseconds
            )
            XCTAssertGreaterThan(
                pair.0.uploadRange.endNanoseconds,
                pair.1.uploadRange.startNanoseconds,
                "Adjacent uploads should overlap"
            )
        }
    }

    func testZeroDurationAssetHasCompleteEmptyCoverage() throws {
        let asset = ReconciliationAudioAsset(
            track: .outgoing,
            fileURL: URL(fileURLWithPath: "/tmp/outgoing.m4a"),
            sourceDurationNanoseconds: 0,
            sourceByteCount: 0,
            sourceSHA256: "empty",
            callStartOffsetNanoseconds: 0
        )
        let chunks = try AudioTrackChunker().chunks(
            callID: Self.callID,
            asset: asset,
            modelID: "file-model"
        )

        XCTAssertEqual(chunks, [])
        XCTAssertTrue(AudioTrackChunker.hasContinuousCoverage(
            chunks,
            sourceDurationNanoseconds: 0
        ))
    }

    private static let callID = UUID(
        uuidString: "71000000-0000-0000-0000-000000000001"
    )!
}
