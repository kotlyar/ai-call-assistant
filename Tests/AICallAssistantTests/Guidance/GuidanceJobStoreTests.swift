import Foundation
import XCTest
@testable import AICallAssistant

final class GuidanceJobStoreTests: XCTestCase {
    func testDurableSnapshotAndRunningJobRecoverAsQueued() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = makeSnapshot(index: 1, triggerTime: 10)
        let store = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)

        let enqueue = try await store.enqueue(snapshot: snapshot)
        let claimed = try await store.claimNextQueuedJobs(limit: 1)

        XCTAssertEqual(claimed.map(\.id), [enqueue.job.id])
        XCTAssertEqual(claimed.first?.state, .running)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.manifestURL.path))
        XCTAssertEqual(try snapshotFileCount(in: store.snapshotsFolderURL), 1)

        let recovered = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let recoveredJobs = await recovered.jobs()
        let recoveredSnapshot = try await recovered.snapshot(for: enqueue.job.id)

        XCTAssertEqual(recoveredJobs.first(where: { $0.id == enqueue.job.id })?.state, .queued)
        XCTAssertNil(recoveredJobs.first(where: { $0.id == enqueue.job.id })?.startedAt)
        XCTAssertEqual(recoveredSnapshot, snapshot)
    }

    func testDeterministicEnqueueAndQueuedRevisionReplacementKeepFIFOPosition() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let triggerID = UUID(uuidString: "20000000-0000-0000-0000-000000000099")!
        let store = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let firstSnapshot = makeSnapshot(
            index: 1,
            triggerID: triggerID,
            revision: 1,
            triggerTime: 20
        )

        let first = try await store.enqueue(snapshot: firstSnapshot)
        let duplicate = try await store.enqueue(snapshot: firstSnapshot)
        XCTAssertEqual(duplicate, .existing(first.job))

        let revisedSnapshot = makeSnapshot(
            index: 2,
            triggerID: triggerID,
            revision: 2,
            triggerTime: 25
        )
        let replacement = try await store.enqueue(snapshot: revisedSnapshot)
        guard case let .replaced(previousJobID, revisedJob) = replacement else {
            return XCTFail("Expected queued replacement")
        }
        XCTAssertEqual(previousJobID, first.job.id)
        XCTAssertEqual(revisedJob.fifoSequence, first.job.fifoSequence)
        XCTAssertEqual(
            revisedJob.triggerStartCallNanoseconds,
            first.job.triggerStartCallNanoseconds
        )
        XCTAssertNotEqual(revisedJob.id, first.job.id)
        let repeatedReplacement = try await store.enqueue(snapshot: revisedSnapshot)
        XCTAssertEqual(revisedJob.id, repeatedReplacement.job.id)

        let jobs = await store.jobs()
        XCTAssertEqual(jobs.first(where: { $0.id == first.job.id })?.state, .superseded)
        XCTAssertEqual(jobs.first(where: { $0.id == revisedJob.id })?.state, .queued)

        _ = try await store.claimNextQueuedJobs(limit: 1)
        let thirdRevision = makeSnapshot(
            index: 3,
            triggerID: triggerID,
            revision: 3,
            triggerTime: 20
        )
        do {
            _ = try await store.enqueue(snapshot: thirdRevision)
            XCTFail("Replacement after start must be rejected")
        } catch let error as GuidanceJobStoreError {
            XCTAssertEqual(
                error,
                .replacementNotAllowedAfterStart(
                    existingJobID: revisedJob.id,
                    state: .running
                )
            )
        }
    }

    func testCoordinatorStartsStrictFIFOWithAtMostTwoAndPublishesLateResult() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let provider = ControlledGuidanceProvider()
        let coordinator = LiveGuidanceCoordinator(store: store, provider: provider)
        let snapshots = [
            makeSnapshot(index: 1, triggerTime: 10),
            makeSnapshot(index: 2, triggerTime: 20),
            makeSnapshot(index: 3, triggerTime: 30)
        ]
        let publicationCollector = Task { () -> [AnalysisRun] in
            var iterator = coordinator.publications.makeAsyncIterator()
            var runs: [AnalysisRun] = []
            while runs.count < snapshots.count, let run = await iterator.next() {
                runs.append(run)
            }
            return runs
        }

        for snapshot in snapshots {
            try await coordinator.enqueue(snapshot: snapshot)
        }
        await waitUntil { await provider.startedSnapshotIDs.count == 2 }
        let initialStarts = await provider.startedSnapshotIDs
        let initialMaximum = await provider.maximumObservedConcurrency
        XCTAssertEqual(initialStarts, ["snapshot-1", "snapshot-2"])
        XCTAssertEqual(initialMaximum, 2)

        await provider.complete(snapshotID: "snapshot-2")
        await waitUntil { await provider.startedSnapshotIDs.count == 3 }
        let allStarts = await provider.startedSnapshotIDs
        XCTAssertEqual(allStarts, [
            "snapshot-1", "snapshot-2", "snapshot-3"
        ])

        await provider.complete(snapshotID: "snapshot-3")
        await provider.complete(snapshotID: "snapshot-1")
        await coordinator.waitUntilIdle()
        let publications = await publicationCollector.value
        let storedRuns = await store.publishedRuns()
        let finalMaximum = await provider.maximumObservedConcurrency

        XCTAssertEqual(publications.count, 3)
        XCTAssertEqual(storedRuns.count, 3)
        XCTAssertEqual(finalMaximum, 2)
        let oldestRun = try XCTUnwrap(
            storedRuns.first(where: { $0.snapshotID == "snapshot-1" })
        )
        XCTAssertEqual(oldestRun.pairs.count, 1)
        XCTAssertTrue(oldestRun.pairs[0].isLate)
    }

    func testCASPublicationIsIdempotentAcrossReopen() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = makeSnapshot(index: 1, triggerTime: 10)
        let store = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let enqueued = try await store.enqueue(snapshot: snapshot).job
        _ = try await store.claimNextQueuedJobs(limit: 1)
        let run = AnalysisRun(
            id: enqueued.runID,
            snapshotID: snapshot.id,
            trigger: snapshot.triggerTurns,
            pairs: [],
            status: .published
        )

        let firstPublication = try await store.publish(jobID: enqueued.id, run: run)
        let repeatedPublication = try await store.publish(jobID: enqueued.id, run: run)
        XCTAssertEqual(firstPublication, .published(run))
        XCTAssertEqual(repeatedPublication, .alreadyPublished(run))

        let reopened = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let reopenedRuns = await reopened.publishedRuns()
        let reopenedPublication = try await reopened.publish(jobID: enqueued.id, run: run)
        let finalRuns = await reopened.publishedRuns()
        XCTAssertEqual(reopenedRuns, [run])
        XCTAssertEqual(reopenedPublication, .alreadyPublished(run))
        XCTAssertEqual(finalRuns.count, 1)
    }

    func testRunningJobCanTransitionToFailedWithSanitizedCode() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let job = try await store.enqueue(
            snapshot: makeSnapshot(index: 1, triggerTime: 10)
        ).job
        _ = try await store.claimNextQueuedJobs(limit: 1)

        try await store.markFailed(jobID: job.id, failureCode: "provider_failure")
        try await store.markFailed(jobID: job.id, failureCode: "provider_failure")

        let jobs = await store.jobs()
        let stored = try XCTUnwrap(jobs.first(where: { $0.id == job.id }))
        XCTAssertEqual(stored.state, .failed)
        XCTAssertEqual(stored.failureCode, "provider_failure")
        XCTAssertNil(stored.result)
    }

    private func makeSnapshot(
        index: Int,
        triggerID: UUID? = nil,
        revision: Int = 1,
        triggerTime: UInt64
    ) -> ConversationSnapshot {
        let triggerID = triggerID ?? UUID(
            uuidString: String(format: "20000000-0000-0000-0000-%012d", index)
        )!
        let reference = TurnReference(turnID: triggerID, revision: revision)
        let turn = SnapshotTurn(
            reference: reference,
            track: .incoming,
            startCallNanoseconds: triggerTime,
            endCallNanoseconds: triggerTime + 1,
            text: "Question \(index)?"
        )
        return ConversationSnapshot(
            schemaVersion: 1,
            id: "snapshot-\(index)",
            callID: Self.callID,
            conversationRevision: Int64(index),
            turns: [turn],
            triggerTurns: [reference],
            frozenContexts: FrozenContextSnapshot(
                id: "contexts",
                frozenAt: Date(timeIntervalSince1970: 1_000),
                contexts: []
            ),
            configuration: GuidanceConfigurationSnapshot(
                id: "configuration",
                responsesModelID: "responses-test",
                realtimeTranscriptionModelID: "realtime-test",
                fileTranscriptionModelID: "file-test",
                transcriptionLanguages: ["en"],
                answerStyle: .brief,
                answerLanguage: .automatic,
                briefAnswerMaxWords: 60,
                detailedAnswerMaxWords: 160,
                adviceMaxWords: 30,
                maxOutputTokens: 4_096,
                initialPerCallSpendLimitUSD: 5,
                priceCatalogVersion: "prices-test",
                modelCapabilityProfileID: "capabilities-test",
                policyVersion: 1
            ),
            perspective: .livePointInTime
        )
    }

    private func temporaryCallFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GuidanceJobStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func snapshotFileCount(in folder: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.count
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let interval: UInt64 = 1_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: interval)
            elapsed += interval
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }

    private static let callID = UUID(
        uuidString: "10000000-0000-0000-0000-000000000001"
    )!
}

private actor ControlledGuidanceProvider: LiveGuidanceProvider {
    private struct Pending {
        let snapshot: ConversationSnapshot
        let continuation: CheckedContinuation<LiveGuidanceProviderResult, Error>
    }

    private var pending: [String: Pending] = [:]
    private var activeCount = 0
    private(set) var maximumObservedConcurrency = 0
    private(set) var startedSnapshotIDs: [String] = []

    func analyze(snapshot: ConversationSnapshot) async throws -> LiveGuidanceProviderResult {
        activeCount += 1
        maximumObservedConcurrency = max(maximumObservedConcurrency, activeCount)
        startedSnapshotIDs.append(snapshot.id)
        return try await withCheckedThrowingContinuation { continuation in
            pending[snapshot.id] = Pending(snapshot: snapshot, continuation: continuation)
        }
    }

    func complete(snapshotID: String) {
        guard let pending = pending.removeValue(forKey: snapshotID) else {
            return
        }
        activeCount -= 1
        let trigger = pending.snapshot.triggerTurns[0]
        let text = pending.snapshot.turns.first(where: { $0.reference == trigger })!.text
        let evidence = QuestionEvidence(
            turn: trigger,
            exactQuote: text,
            unicodeScalarRange: 0..<text.unicodeScalars.count
        )
        pending.continuation.resume(
            returning: LiveGuidanceProviderResult(
                questionAnswers: [
                    ValidatedGuidanceQuestionAnswer(
                        normalizedQuestion: text,
                        evidence: [evidence],
                        answer: "Answer for \(snapshotID)",
                        advice: "Be concise.",
                        usedTurnIDs: [trigger.turnID],
                        usedContextIDs: []
                    )
                ]
            )
        )
    }
}
