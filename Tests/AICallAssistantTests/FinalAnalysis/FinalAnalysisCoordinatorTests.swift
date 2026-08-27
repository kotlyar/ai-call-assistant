import Foundation
import XCTest
@testable import AICallAssistant

final class FinalAnalysisCoordinatorTests: XCTestCase {
    func testPublishesContentAddressedSeparateCardsAndIsIdempotentAcrossRestart() async throws {
        let fixture = FinalAnalysisTestFixture()
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try FinalAnalysisStore(callFolderURL: folder, callID: fixture.callID)
        let provider = ScriptedFinalAnalysisProvider(mode: .success)
        let credentials = MutableFinalCredential(key: "current-key")
        let spend = RecordingFinalSpendReserver()
        let coordinator = FinalAnalysisCoordinator(
            store: store,
            provider: provider,
            credentialProvider: credentials,
            spendReserver: spend
        )

        let first = try await coordinator.start(
            reconciliation: fixture.reconciliation(),
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash,
            frozenContexts: fixture.contexts,
            configuration: fixture.configuration
        )
        let published = try XCTUnwrap(first.publishedResult)
        XCTAssertEqual(first.job.status, .complete)
        XCTAssertEqual(published.artifact.perspective, .postCallRetrospective)
        XCTAssertEqual(published.artifact.cards.count, 3)
        XCTAssertEqual(Set(published.artifact.cards.map(\.normalizedQuestion)), Set([
            "Какой бюджет?", "Кто согласует?", "Какой срок?"
        ]))
        XCTAssertTrue(published.artifact.cards.allSatisfy {
            !$0.evidence.isEmpty && $0.evidence.allSatisfy { evidence in
                evidence.canonicalTurnID.hasPrefix("canonical-incoming")
            }
        })
        XCTAssertEqual(
            published.pointer.fileName,
            "analysis.7.\(fixture.canonicalHash).json"
        )
        XCTAssertEqual(published.pointer.analysisHash.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(published.pointer.fileName).path
        ))

        let providerCalls = await provider.totalCalls
        let credentialLookups = await credentials.lookupCount
        let reservations = await spend.reservations
        XCTAssertEqual(providerCalls, 2, "Only incoming canonical turns trigger analysis")
        XCTAssertEqual(credentialLookups, 2)
        XCTAssertEqual(reservations.count, 2)
        XCTAssertEqual(Set(reservations.map(\.id)).count, 2)
        let finalSnapshot = try fixture.snapshot()
        let expectedInputReservations = try finalSnapshot.canonicallyOrderedTurns
            .filter { $0.track == .incoming }
            .map { trigger in
                try FinalAnalysisRequestSpendEstimator().estimate(
                    for: FinalAnalysisProviderRequest(
                        jobID: "estimation-only",
                        triggerJobID: "estimation-only",
                        idempotencyKey: "estimation-only",
                        snapshot: finalSnapshot,
                        triggerTurnID: trigger.id,
                        attempt: 1,
                        apiKey: "not-encoded"
                    )
                ).reservedInputTokens
            }
        XCTAssertEqual(
            reservations.map(\.inputTokens),
            expectedInputReservations
        )
        XCTAssertTrue(reservations.allSatisfy {
            $0.outputTokens == fixture.configuration.maxOutputTokens
        })
        let observedSnapshots = await provider.snapshots
        XCTAssertEqual(observedSnapshots.count, 2)
        XCTAssertTrue(observedSnapshots.allSatisfy {
            $0.turns.map(\.text) == fixture.turns.map(\.text)
                && $0.frozenContexts == fixture.contexts
                && $0.perspective == .postCallRetrospective
        })

        let repeated = try await coordinator.start(
            reconciliation: fixture.reconciliation(),
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash,
            frozenContexts: fixture.contexts,
            configuration: fixture.configuration
        )
        XCTAssertEqual(repeated.publishedResult, published)
        let callsAfterRepeat = await provider.totalCalls
        XCTAssertEqual(callsAfterRepeat, providerCalls)

        let reopenedStore = try FinalAnalysisStore(
            callFolderURL: folder,
            callID: fixture.callID
        )
        let reopenedCoordinator = FinalAnalysisCoordinator(
            store: reopenedStore,
            provider: provider,
            credentialProvider: credentials,
            spendReserver: spend
        )
        let recovered = try await reopenedCoordinator.recover()
        XCTAssertEqual(recovered.publishedResult, published)
        let callsAfterRecovery = await provider.totalCalls
        XCTAssertEqual(callsAfterRecovery, providerCalls)
        let readBack = try await reopenedStore.currentPublishedResult(
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash
        )
        XCTAssertEqual(readBack, published)
        let wrongRevision = try await reopenedStore.currentPublishedResult(
            canonicalRevision: 8,
            canonicalTranscriptHash: fixture.canonicalHash
        )
        XCTAssertNil(wrongRevision)

        let nextSnapshot = try fixture.snapshot(
            canonicalRevision: 8,
            canonicalHash: String(repeating: "b", count: 64)
        )
        _ = try await reopenedStore.enqueue(snapshot: nextSnapshot)
        let stalePointer = try await reopenedStore.currentPublishedResult(
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash
        )
        XCTAssertNil(stalePointer, "Advancing canonical target must clear the old pointer")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(published.pointer.fileName).path
        ), "The old content-addressed artifact remains immutable but non-authoritative")
    }

    func testRunningRecoveryKeepsCompletedTriggerAndResumesOnlyPendingWork() async throws {
        let fixture = FinalAnalysisTestFixture()
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstStore = try FinalAnalysisStore(
            callFolderURL: folder,
            callID: fixture.callID
        )
        let job = try await firstStore.enqueue(snapshot: fixture.snapshot())
        let optionalFirstClaim = try await firstStore.claimNextTrigger(
            jobID: job.id,
            maximumAttempts: 2
        )
        let firstClaim = try XCTUnwrap(optionalFirstClaim)
        try await firstStore.markTriggerComplete(
            jobID: job.id,
            triggerJobID: firstClaim.triggerJobID,
            result: FinalAnalysisTriggerResult(
                triggerTurnID: firstClaim.triggerTurnID,
                cards: []
            )
        )
        let optionalSecondClaim = try await firstStore.claimNextTrigger(
            jobID: job.id,
            maximumAttempts: 2
        )
        let secondClaim = try XCTUnwrap(optionalSecondClaim)

        let reopened = try FinalAnalysisStore(
            callFolderURL: folder,
            callID: fixture.callID
        )
        let recoveredJob = try await reopened.targetJob()
        XCTAssertEqual(recoveredJob.status, .pending)
        XCTAssertEqual(recoveredJob.triggers.map(\.state), [.complete, .pending])
        XCTAssertEqual(recoveredJob.triggers[1].attempts, 1)

        let provider = ScriptedFinalAnalysisProvider(mode: .success)
        let coordinator = FinalAnalysisCoordinator(
            store: reopened,
            provider: provider,
            credentialProvider: MutableFinalCredential(key: "key"),
            spendReserver: RecordingFinalSpendReserver()
        )
        let result = try await coordinator.recover()
        let resumedTriggerIDs = await provider.triggerTurnIDs
        XCTAssertEqual(result.job.status, .complete)
        XCTAssertEqual(resumedTriggerIDs, [secondClaim.triggerTurnID])
        XCTAssertEqual(result.publishedResult?.artifact.cards.count, 1)
    }

    func testCrashOnLastClaimBecomesRetryableInsteadOfWedgingPending() async throws {
        let fixture = FinalAnalysisTestFixture()
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstStore = try FinalAnalysisStore(
            callFolderURL: folder,
            callID: fixture.callID
        )
        let job = try await firstStore.enqueue(snapshot: fixture.snapshot())
        let optionalFirstAttempt = try await firstStore.claimNextTrigger(
            jobID: job.id,
            maximumAttempts: 2
        )
        let firstAttempt = try XCTUnwrap(optionalFirstAttempt)
        try await firstStore.markTriggerFailed(
            jobID: job.id,
            triggerJobID: firstAttempt.triggerJobID,
            errorCode: "network_failure"
        )
        let optionalCrashedAttempt = try await firstStore.claimNextTrigger(
            jobID: job.id,
            maximumAttempts: 2
        )
        let crashedAttempt = try XCTUnwrap(optionalCrashedAttempt)
        XCTAssertEqual(crashedAttempt.triggerJobID, firstAttempt.triggerJobID)
        XCTAssertEqual(crashedAttempt.attempt, 2)

        let reopened = try FinalAnalysisStore(
            callFolderURL: folder,
            callID: fixture.callID
        )
        let provider = ScriptedFinalAnalysisProvider(mode: .success)
        let spend = RecordingFinalSpendReserver()
        let coordinator = FinalAnalysisCoordinator(
            store: reopened,
            provider: provider,
            credentialProvider: MutableFinalCredential(key: "key"),
            spendReserver: spend,
            maximumAttemptsPerTrigger: 2
        )

        let recovered = try await coordinator.recover()
        XCTAssertEqual(recovered.job.status, .failed)
        XCTAssertNil(recovered.publishedResult)

        let retried = try await coordinator.retryFailed()
        XCTAssertEqual(retried.job.status, .complete)
        XCTAssertNotNil(retried.publishedResult)
        let reservationIDs = await spend.reservations.map(\.id)
        XCTAssertTrue(reservationIDs.contains {
            $0 == "final-responses:\(crashedAttempt.triggerJobID):attempt:3"
        })
    }

    func testMissingCredentialSpendLimitAnd401BecomeDurableBlocks() async throws {
        let fixture = FinalAnalysisTestFixture()
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let credentials = MutableFinalCredential(key: nil)
        let spend = RecordingFinalSpendReserver(mode: .limitExceeded)
        let provider = ScriptedFinalAnalysisProvider(mode: .success)
        let coordinator = FinalAnalysisCoordinator(
            store: try FinalAnalysisStore(
                callFolderURL: folder,
                callID: fixture.callID
            ),
            provider: provider,
            credentialProvider: credentials,
            spendReserver: spend
        )

        let missing = try await coordinator.start(
            reconciliation: fixture.reconciliation(),
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash,
            frozenContexts: fixture.contexts,
            configuration: fixture.configuration
        )
        let callsAfterMissingCredential = await provider.totalCalls
        XCTAssertEqual(missing.job.status, .blockedByCredential)
        XCTAssertEqual(missing.job.attempts, 0)
        XCTAssertEqual(callsAfterMissingCredential, 0)

        await credentials.setKey("new-key")
        let spendBlocked = try await coordinator.recover()
        let callsAfterSpendBlock = await provider.totalCalls
        XCTAssertEqual(spendBlocked.job.status, .blockedBySpendLimit)
        XCTAssertEqual(spendBlocked.job.attempts, 0)
        XCTAssertEqual(callsAfterSpendBlock, 0)

        await spend.setMode(.allowed)
        await provider.setMode(.unauthorizedOnce)
        let rejected = try await coordinator.recover()
        let callsAfterRejection = await provider.totalCalls
        XCTAssertEqual(rejected.job.status, .blockedByCredential)
        XCTAssertEqual(rejected.job.attempts, 1)
        XCTAssertEqual(callsAfterRejection, 1)

        await provider.setMode(.success)
        let completed = try await coordinator.recover()
        XCTAssertEqual(completed.job.status, .complete)
        XCTAssertNotNil(completed.publishedResult)
        let ids = await spend.reservations.map(\.id)
        XCTAssertTrue(ids.contains { $0.hasSuffix(":attempt:1") })
        XCTAssertTrue(ids.contains { $0.hasSuffix(":attempt:2") })
    }

    func testContextLimitIsTerminalWithoutPartialArtifactAndFailedRunCanExplicitlyRetry() async throws {
        let fixture = FinalAnalysisTestFixture()
        let contextFolder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: contextFolder) }
        let contextProvider = ScriptedFinalAnalysisProvider(mode: .contextLimit)
        let contextStore = try FinalAnalysisStore(
            callFolderURL: contextFolder,
            callID: fixture.callID
        )
        let contextCoordinator = FinalAnalysisCoordinator(
            store: contextStore,
            provider: contextProvider,
            credentialProvider: MutableFinalCredential(key: "key"),
            spendReserver: RecordingFinalSpendReserver()
        )
        let limited = try await contextCoordinator.start(
            reconciliation: fixture.reconciliation(),
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash,
            frozenContexts: fixture.contexts,
            configuration: fixture.configuration
        )
        let contextCalls = await contextProvider.totalCalls
        let contextPublished = try await contextStore.currentPublishedResult(
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash
        )
        XCTAssertEqual(limited.job.status, .contextLimitExceeded)
        XCTAssertNil(limited.publishedResult)
        XCTAssertEqual(contextCalls, 1)
        XCTAssertNil(contextPublished)

        let retryFolder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: retryFolder) }
        let retryProvider = ScriptedFinalAnalysisProvider(mode: .refusal)
        let retryCoordinator = FinalAnalysisCoordinator(
            store: try FinalAnalysisStore(
                callFolderURL: retryFolder,
                callID: fixture.callID
            ),
            provider: retryProvider,
            credentialProvider: MutableFinalCredential(key: "key"),
            spendReserver: RecordingFinalSpendReserver()
        )
        let failed = try await retryCoordinator.start(
            reconciliation: fixture.reconciliation(),
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash,
            frozenContexts: fixture.contexts,
            configuration: fixture.configuration
        )
        XCTAssertEqual(failed.job.status, .failed)
        await retryProvider.setMode(.success)
        let retried = try await retryCoordinator.retryFailed()
        XCTAssertEqual(retried.job.status, .complete)
        XCTAssertNotNil(retried.publishedResult)
    }

    private func temporaryCallFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FinalAnalysisCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

}

private actor MutableFinalCredential: FinalAnalysisCredentialProvider {
    private var key: String?
    private(set) var lookupCount = 0

    init(key: String?) {
        self.key = key
    }

    func setKey(_ key: String?) {
        self.key = key
    }

    func currentAPIKey() async throws -> String? {
        lookupCount += 1
        return key
    }
}

private actor RecordingFinalSpendReserver: FinalAnalysisSpendReserver {
    enum Mode: Sendable {
        case allowed
        case limitExceeded
    }

    struct Reservation: Equatable, Sendable {
        let id: String
        let modelID: String
        let inputTokens: Int
        let outputTokens: Int
    }

    private var mode: Mode
    private(set) var reservations: [Reservation] = []

    init(mode: Mode = .allowed) {
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func reserveResponses(
        id: String,
        modelID: String,
        estimatedInputTokens: Int,
        maximumOutputTokens: Int
    ) async throws {
        if mode == .limitExceeded {
            throw SpendLedgerError.limitExceeded(
                requiredNanoUSD: 1,
                remainingNanoUSD: 0
            )
        }
        reservations.append(Reservation(
            id: id,
            modelID: modelID,
            inputTokens: estimatedInputTokens,
            outputTokens: maximumOutputTokens
        ))
    }
}

private actor ScriptedFinalAnalysisProvider: FinalAnalysisProvider {
    enum Mode: Sendable {
        case success
        case contextLimit
        case unauthorizedOnce
        case refusal
    }

    private var mode: Mode
    private(set) var triggerTurnIDs: [String] = []
    private(set) var snapshots: [FinalAnalysisSnapshot] = []

    init(mode: Mode) {
        self.mode = mode
    }

    var totalCalls: Int { triggerTurnIDs.count }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    func analyze(
        request: FinalAnalysisProviderRequest
    ) async throws -> FinalAnalysisTriggerResult {
        triggerTurnIDs.append(request.triggerTurnID)
        snapshots.append(request.snapshot)
        switch mode {
        case .contextLimit:
            throw FinalAnalysisProviderError.contextLimitExceeded
        case .unauthorizedOnce:
            mode = .success
            throw FinalAnalysisProviderError.providerError(statusCode: 401, code: nil)
        case .refusal:
            throw FinalAnalysisProviderError.refusal
        case .success:
            break
        }

        let contextIDs = request.snapshot.frozenContexts.contexts.map(\.sourceContextID)
        let turnIDs = request.snapshot.turns.map(\.id)
        let cards: [FinalAnalysisCardDraft]
        if request.triggerTurnID == "canonical-incoming-1" {
            cards = [
                makeCard(
                    snapshot: request.snapshot,
                    question: "Какой бюджет?",
                    quote: "Какой бюджет?",
                    turnIDs: turnIDs,
                    contextIDs: contextIDs
                ),
                makeCard(
                    snapshot: request.snapshot,
                    question: "Кто согласует?",
                    quote: "кто согласует?",
                    turnIDs: turnIDs,
                    contextIDs: contextIDs
                )
            ]
        } else {
            cards = [
                makeCard(
                    snapshot: request.snapshot,
                    question: "Какой срок?",
                    quote: "а срок?",
                    turnIDs: turnIDs,
                    contextIDs: contextIDs
                )
            ]
        }
        return FinalAnalysisTriggerResult(
            triggerTurnID: request.triggerTurnID,
            cards: cards
        )
    }

    private func makeCard(
        snapshot: FinalAnalysisSnapshot,
        question: String,
        quote: String,
        turnIDs: [String],
        contextIDs: [UUID]
    ) -> FinalAnalysisCardDraft {
        let trigger = snapshot.turns.first { turn in
            turn.text.contains(quote)
        }!
        return FinalAnalysisCardDraft(
            normalizedQuestion: question,
            evidence: [
                FinalTranscriptEvidence(
                    canonicalTurnID: trigger.id,
                    exactQuote: quote,
                    unicodeScalarRange: nil
                )
            ],
            answer: "Финальный ответ с учётом всего разговора",
            advice: "Ответьте прямо",
            usedCanonicalTurnIDs: turnIDs,
            usedContextIDs: contextIDs
        )
    }
}
