import Foundation
import XCTest
@testable import AICallAssistant

final class RecordingFinalAnalysisProcessorTests: XCTestCase {
    func testCompleteResultPersistsMatchingMetadataPointerAndLoadsArtifact() async throws {
        let harness = try makeHarness(apiKey: "test-key", providerMode: .success)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }

        let outcome = try await harness.processor.process(
            recording: harness.recording,
            reconciliation: harness.fixture.reconciliation()
        )

        let metadata = try XCTUnwrap(outcome.recording.transcription)
        let pointer = try XCTUnwrap(metadata.finalAnalysisResultPointer)
        let published = try XCTUnwrap(outcome.publishedResult)
        XCTAssertEqual(metadata.finalAnalysisStatus, .complete)
        XCTAssertEqual(metadata.finalAnalysisJobID, outcome.job.id)
        XCTAssertEqual(metadata.finalAnalysisAttempts, outcome.job.attempts)
        XCTAssertEqual(metadata.finalAnalysisUpdatedAt, outcome.job.updatedAt)
        XCTAssertNil(metadata.lastErrorCode)
        XCTAssertEqual(pointer, published.pointer)
        XCTAssertTrue(pointer.matches(
            canonicalRevision: try XCTUnwrap(metadata.canonicalRevision),
            canonicalTranscriptHash: try XCTUnwrap(metadata.canonicalTranscriptSHA256)
        ))

        let persisted = try harness.storage.load(folderName: harness.recording.folderName)
        XCTAssertEqual(persisted.transcription?.finalAnalysisStatus, .complete)
        XCTAssertEqual(persisted.transcription?.finalAnalysisResultPointer, pointer)
        let loaded = try await harness.processor.loadPublishedResult(for: persisted)
        XCTAssertEqual(loaded, published)
    }

    func testMissingCredentialPersistsBlockedStatusWithoutPointer() async throws {
        let harness = try makeHarness(apiKey: nil, providerMode: .success)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }

        let outcome = try await harness.processor.process(
            recording: harness.recording,
            reconciliation: harness.fixture.reconciliation()
        )

        XCTAssertEqual(outcome.job.status, .blockedByCredential)
        XCTAssertEqual(outcome.job.attempts, 0)
        XCTAssertNil(outcome.publishedResult)
        XCTAssertEqual(outcome.recording.transcription?.finalAnalysisStatus, .blockedByCredential)
        XCTAssertNil(outcome.recording.transcription?.finalAnalysisResultPointer)
        XCTAssertEqual(outcome.recording.transcription?.lastErrorCode, "credential_missing")
        let providerCallCount = await harness.provider.callCount
        XCTAssertEqual(providerCallCount, 0)

        let persisted = try harness.storage.load(folderName: harness.recording.folderName)
        XCTAssertEqual(persisted.transcription?.finalAnalysisStatus, .blockedByCredential)
        XCTAssertNil(persisted.transcription?.finalAnalysisResultPointer)
        let blockedResult = try await harness.processor.loadPublishedResult(for: persisted)
        XCTAssertNil(blockedResult)
    }

    func testLoaderRepairsMissingOrStaleMetadataPointerFromDurableStore() async throws {
        let harness = try makeHarness(apiKey: "test-key", providerMode: .success)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let outcome = try await harness.processor.process(
            recording: harness.recording,
            reconciliation: harness.fixture.reconciliation()
        )
        let pointer = try XCTUnwrap(outcome.recording.transcription?.finalAnalysisResultPointer)

        var missingPointer = outcome.recording
        missingPointer.transcription?.finalAnalysisResultPointer = nil
        let missingResult = try await harness.processor.loadPublishedResult(for: missingPointer)
        XCTAssertEqual(missingResult, outcome.publishedResult)
        XCTAssertEqual(
            try harness.storage.load(folderName: harness.recording.folderName)
                .transcription?.finalAnalysisResultPointer,
            pointer
        )

        var stalePointer = outcome.recording
        stalePointer.transcription?.finalAnalysisResultPointer = FinalAnalysisResultPointer(
            canonicalRevision: pointer.canonicalRevision + 1,
            canonicalTranscriptHash: pointer.canonicalTranscriptHash,
            analysisHash: pointer.analysisHash,
            fileName: pointer.fileName
        )
        let staleResult = try await harness.processor.loadPublishedResult(for: stalePointer)
        XCTAssertEqual(staleResult, outcome.publishedResult)
        let providerCalls = await harness.provider.callCount
        XCTAssertEqual(providerCalls, 2)
    }

    func testMissingSnapshotAndArtifactAreRebuiltWithoutProviderWork() async throws {
        let harness = try makeHarness(apiKey: "test-key", providerMode: .success)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let completed = try await harness.processor.process(
            recording: harness.recording,
            reconciliation: harness.fixture.reconciliation()
        )
        let published = try XCTUnwrap(completed.publishedResult)
        let callFolder = try harness.storage.folderURL(for: completed.recording)
        let artifactURL = callFolder.appendingPathComponent(published.pointer.fileName)
        let snapshotURL = callFolder
            .appendingPathComponent("final-analysis", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("\(completed.job.snapshotID).json")
        try FileManager.default.removeItem(at: artifactURL)
        try FileManager.default.removeItem(at: snapshotURL)

        var pointerless = completed.recording
        pointerless.transcription?.finalAnalysisResultPointer = nil
        try harness.storage.save(pointerless)
        let callsBeforeRepair = await harness.provider.callCount
        let repaired = try await harness.processor.process(
            recording: pointerless,
            reconciliation: harness.fixture.reconciliation()
        )

        XCTAssertEqual(repaired.publishedResult, published)
        XCTAssertEqual(repaired.recording.transcription?.finalAnalysisStatus, .complete)
        XCTAssertEqual(repaired.recording.transcription?.finalAnalysisResultPointer, published.pointer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        let callsAfterRepair = await harness.provider.callCount
        XCTAssertEqual(callsAfterRepair, callsBeforeRepair)

        try Data("corrupt artifact".utf8).write(to: artifactURL, options: .atomic)
        let repairedAgain = try await harness.processor.process(
            recording: repaired.recording,
            reconciliation: harness.fixture.reconciliation()
        )
        XCTAssertEqual(repairedAgain.publishedResult, published)
        let callsAfterCorruptionRepair = await harness.provider.callCount
        XCTAssertEqual(callsAfterCorruptionRepair, callsBeforeRepair)
    }

    func testUnreconstructibleArtifactBecomesRetryableAndRetriesOnlyMissingTrigger() async throws {
        let harness = try makeHarness(apiKey: "test-key", providerMode: .success)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let completed = try await harness.processor.process(
            recording: harness.recording,
            reconciliation: harness.fixture.reconciliation()
        )
        let pointer = try XCTUnwrap(completed.publishedResult?.pointer)
        let callFolder = try harness.storage.folderURL(for: completed.recording)
        try FileManager.default.removeItem(
            at: callFolder.appendingPathComponent(pointer.fileName)
        )
        let manifestURL = callFolder
            .appendingPathComponent("final-analysis", isDirectory: true)
            .appendingPathComponent("final-analysis-jobs.json")
        try removeFirstPersistedTriggerResult(from: manifestURL)
        let callsBeforeRepair = await harness.provider.callCount

        let unavailable = try await harness.processor.loadPublishedResult(
            for: completed.recording
        )
        XCTAssertNil(unavailable)
        let failed = try harness.storage.load(folderName: harness.recording.folderName)
        XCTAssertEqual(failed.transcription?.finalAnalysisStatus, .failed)
        XCTAssertNil(failed.transcription?.finalAnalysisResultPointer)
        XCTAssertEqual(
            failed.transcription?.lastErrorCode,
            "published_artifact_unrecoverable"
        )

        let retried = try await harness.processor.process(
            recording: failed,
            reconciliation: harness.fixture.reconciliation(),
            retryFailed: true
        )
        XCTAssertEqual(retried.recording.transcription?.finalAnalysisStatus, .complete)
        XCTAssertNotNil(retried.publishedResult)
        let callsAfterRetry = await harness.provider.callCount
        XCTAssertEqual(callsAfterRetry, callsBeforeRepair + 1)
    }

    func testExplicitRetryFailedRunPersistsCompletedReplacementState() async throws {
        let harness = try makeHarness(apiKey: "test-key", providerMode: .refusal)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }

        let failed = try await harness.processor.process(
            recording: harness.recording,
            reconciliation: harness.fixture.reconciliation()
        )
        XCTAssertEqual(failed.job.status, .failed)
        XCTAssertEqual(failed.recording.transcription?.finalAnalysisStatus, .failed)
        XCTAssertNil(failed.recording.transcription?.finalAnalysisResultPointer)

        await harness.provider.setMode(.success)
        let retried = try await harness.processor.process(
            recording: failed.recording,
            reconciliation: harness.fixture.reconciliation(),
            retryFailed: true
        )

        XCTAssertEqual(retried.job.id, failed.job.id)
        XCTAssertEqual(retried.job.status, .complete)
        XCTAssertNotNil(retried.publishedResult)
        XCTAssertEqual(retried.recording.transcription?.finalAnalysisStatus, .complete)
        XCTAssertEqual(
            retried.recording.transcription?.finalAnalysisResultPointer,
            retried.publishedResult?.pointer
        )
        let persisted = try harness.storage.load(folderName: harness.recording.folderName)
        XCTAssertEqual(persisted.transcription?.finalAnalysisStatus, .complete)
        XCTAssertEqual(
            persisted.transcription?.finalAnalysisResultPointer,
            retried.publishedResult?.pointer
        )
    }

    func testRetryRepairsFailedMetadataWhenDurableJobAlreadyCompleted() async throws {
        let harness = try makeHarness(apiKey: "test-key", providerMode: .success)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let completed = try await harness.processor.process(
            recording: harness.recording,
            reconciliation: harness.fixture.reconciliation()
        )
        let initialCalls = await harness.provider.callCount

        var staleMetadata = completed.recording
        staleMetadata.transcription?.finalAnalysisStatus = .failed
        staleMetadata.transcription?.finalAnalysisResultPointer = nil
        try harness.storage.save(staleMetadata)

        let repaired = try await harness.processor.process(
            recording: staleMetadata,
            reconciliation: harness.fixture.reconciliation(),
            retryFailed: true
        )

        XCTAssertEqual(repaired.job.status, .complete)
        XCTAssertEqual(repaired.recording.transcription?.finalAnalysisStatus, .complete)
        XCTAssertEqual(
            repaired.recording.transcription?.finalAnalysisResultPointer,
            completed.publishedResult?.pointer
        )
        let finalCalls = await harness.provider.callCount
        XCTAssertEqual(finalCalls, initialCalls)
    }

    private func makeHarness(
        apiKey: String?,
        providerMode: RecordingProcessorProvider.Mode
    ) throws -> Harness {
        let fixture = FinalAnalysisTestFixture()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingFinalAnalysisProcessorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = RecordingStorageService(rootURL: rootURL)
        let provider = RecordingProcessorProvider(mode: providerMode)
        let recording = Recording(
            id: fixture.callID,
            title: "Call",
            startedAt: Date(timeIntervalSince1970: 900),
            duration: 40,
            folderName: "call",
            turns: [],
            transcription: RecordingTranscriptionMetadata(
                callState: .saved,
                liveStatus: .complete,
                reconciliationStatus: .complete,
                finalAnalysisStatus: .pending,
                incomingRealtimeStatus: .live,
                outgoingRealtimeStatus: .live,
                liveRevision: 6,
                canonicalRevision: 7,
                canonicalTranscriptFilename: "transcript.canonical.json",
                canonicalTranscriptSHA256: fixture.canonicalHash,
                reconciliationJobID: fixture.reconciliation().id,
                reconciliationAttempts: fixture.reconciliation().attempts,
                reconciliationUpdatedAt: fixture.reconciliation().updatedAt,
                liveJournalSealedAt: Date(timeIntervalSince1970: 850),
                provider: "openai",
                realtimeModelID: fixture.configuration.realtimeTranscriptionModelID,
                fileTranscriptionModelID: fixture.configuration.fileTranscriptionModelID,
                responsesModelID: fixture.configuration.responsesModelID,
                frozenContexts: fixture.contexts,
                frozenConfiguration: fixture.configuration,
                lastErrorCode: nil
            )
        )
        try storage.save(recording)
        let processor = RecordingFinalAnalysisProcessor(
            recordingStorage: storage,
            provider: provider,
            credentialProvider: RecordingProcessorCredential(apiKey: apiKey)
        )
        return Harness(
            fixture: fixture,
            rootURL: rootURL,
            storage: storage,
            provider: provider,
            processor: processor,
            recording: recording
        )
    }

    private func removeFirstPersistedTriggerResult(from manifestURL: URL) throws {
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: manifestURL)
            ) as? [String: Any]
        )
        var jobs = try XCTUnwrap(document["jobs"] as? [[String: Any]])
        var firstJob = try XCTUnwrap(jobs.first)
        var triggers = try XCTUnwrap(firstJob["triggers"] as? [[String: Any]])
        var firstTrigger = try XCTUnwrap(triggers.first)
        firstTrigger.removeValue(forKey: "result")
        triggers[0] = firstTrigger
        firstJob["triggers"] = triggers
        jobs[0] = firstJob
        document["jobs"] = jobs
        try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        ).write(to: manifestURL, options: .atomic)
    }

    private struct Harness {
        let fixture: FinalAnalysisTestFixture
        let rootURL: URL
        let storage: RecordingStorageService
        let provider: RecordingProcessorProvider
        let processor: RecordingFinalAnalysisProcessor
        let recording: Recording
    }
}

private actor RecordingProcessorCredential: FinalAnalysisCredentialProvider {
    let apiKey: String?

    init(apiKey: String?) {
        self.apiKey = apiKey
    }

    func currentAPIKey() async throws -> String? {
        apiKey
    }
}

private actor RecordingProcessorProvider: FinalAnalysisProvider {
    enum Mode: Sendable {
        case success
        case refusal
    }

    private var mode: Mode
    private(set) var callCount = 0

    init(mode: Mode) {
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func analyze(
        request: FinalAnalysisProviderRequest
    ) async throws -> FinalAnalysisTriggerResult {
        callCount += 1
        if mode == .refusal {
            throw FinalAnalysisProviderError.refusal
        }
        let trigger = request.snapshot.turns.first {
            $0.id == request.triggerTurnID
        }!
        let evidence = FinalTranscriptEvidence(
            canonicalTurnID: trigger.id,
            exactQuote: trigger.text,
            unicodeScalarRange: 0..<trigger.text.unicodeScalars.count
        )
        return FinalAnalysisTriggerResult(
            triggerTurnID: trigger.id,
            cards: [
                FinalAnalysisCardDraft(
                    normalizedQuestion: "Question from \(trigger.id)",
                    evidence: [evidence],
                    answer: "Final answer",
                    advice: "Answer directly",
                    usedCanonicalTurnIDs: request.snapshot.turns.map(\.id),
                    usedContextIDs: request.snapshot.frozenContexts.contexts.map(\.sourceContextID)
                )
            ]
        )
    }
}
