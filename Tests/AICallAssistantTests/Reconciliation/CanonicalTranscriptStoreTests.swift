import Foundation
import XCTest
@testable import AICallAssistant

final class CanonicalTranscriptStoreTests: XCTestCase {
    func testCommitIsContentAddressedAndIdempotent() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = makeRecording()
        let result = makeResult()
        let store = CanonicalTranscriptStore()

        let first = try store.commit(
            result: result,
            for: recording,
            callFolderURL: folder,
            providerModelID: "gpt-transcribe"
        )
        let second = try store.commit(
            result: result,
            for: recording,
            callFolderURL: folder,
            providerModelID: "gpt-transcribe"
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.filename.contains(first.sha256))
        XCTAssertEqual(first.turns.map(\.speaker), [.participant, .you])
        XCTAssertEqual(first.turns.map(\.timestamp), [1, 2])
        let loaded = try store.load(
            filename: first.filename,
            expectedSHA256: first.sha256,
            callID: recording.id,
            callFolderURL: folder
        )
        XCTAssertEqual(loaded, first.document)
    }

    func testLoadRejectsTamperedCanonicalArtifact() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recording = makeRecording()
        let store = CanonicalTranscriptStore()
        let commit = try store.commit(
            result: makeResult(),
            for: recording,
            callFolderURL: folder,
            providerModelID: "gpt-transcribe"
        )
        let url = folder.appendingPathComponent(commit.filename)
        try Data("tampered".utf8).write(to: url, options: .atomic)

        XCTAssertThrowsError(
            try store.load(
                filename: commit.filename,
                expectedSHA256: commit.sha256,
                callID: recording.id,
                callFolderURL: folder
            )
        ) { error in
            XCTAssertEqual(error as? CanonicalTranscriptStoreError, .digestMismatch)
        }
    }

    private func makeRecording() -> Recording {
        let contexts = FrozenContextSnapshot(id: "ctx", frozenAt: Date(timeIntervalSince1970: 1), contexts: [])
        let configuration = GuidanceConfigurationSnapshot(
            id: "cfg",
            responsesModelID: "gpt-5.6-terra",
            realtimeTranscriptionModelID: "gpt-live-transcribe",
            fileTranscriptionModelID: "gpt-transcribe",
            transcriptionLanguages: ["ru", "en"],
            answerStyle: .brief,
            answerLanguage: .automatic,
            briefAnswerMaxWords: 60,
            detailedAnswerMaxWords: 160,
            adviceMaxWords: 30,
            maxOutputTokens: 4_096,
            initialPerCallSpendLimitUSD: 2,
            priceCatalogVersion: OpenAIPriceCatalog.current.version,
            modelCapabilityProfileID: "test",
            policyVersion: 1
        )
        return Recording(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
            title: "Call",
            startedAt: Date(timeIntervalSince1970: 1),
            duration: 10,
            folderName: "call",
            turns: [],
            transcription: RecordingTranscriptionMetadata(
                callState: .saved,
                liveStatus: .complete,
                reconciliationStatus: .pending,
                finalAnalysisStatus: .waitingForReconciliation,
                incomingRealtimeStatus: .live,
                outgoingRealtimeStatus: .live,
                liveRevision: 2,
                canonicalRevision: nil,
                liveJournalSealedAt: Date(timeIntervalSince1970: 2),
                provider: "openai",
                realtimeModelID: "gpt-live-transcribe",
                fileTranscriptionModelID: "gpt-transcribe",
                responsesModelID: "gpt-5.6-terra",
                frozenContexts: contexts,
                frozenConfiguration: configuration,
                lastErrorCode: nil
            )
        )
    }

    private func makeResult() -> ReconciliationCanonicalResult {
        ReconciliationCanonicalResult(
            turns: [
                ReconciledTranscriptTurn(
                    id: "incoming-1",
                    track: .incoming,
                    startCallNanoseconds: 1_000_000_000,
                    endCallNanoseconds: 1_500_000_000,
                    text: "Question?",
                    detectorMiss: false,
                    sourceChunkIDs: ["i"]
                ),
                ReconciledTranscriptTurn(
                    id: "outgoing-1",
                    track: .outgoing,
                    startCallNanoseconds: 2_000_000_000,
                    endCallNanoseconds: 2_500_000_000,
                    text: "Answer",
                    detectorMiss: false,
                    sourceChunkIDs: ["o"]
                )
            ],
            trackCoverage: [
                ReconciliationTrackCoverage(
                    track: .incoming,
                    sourceDurationNanoseconds: 10_000_000_000,
                    fullyProcessed: true,
                    missingReason: nil
                ),
                ReconciliationTrackCoverage(
                    track: .outgoing,
                    sourceDurationNanoseconds: 10_000_000_000,
                    fullyProcessed: true,
                    missingReason: nil
                )
            ]
        )
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonicalTranscriptStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
