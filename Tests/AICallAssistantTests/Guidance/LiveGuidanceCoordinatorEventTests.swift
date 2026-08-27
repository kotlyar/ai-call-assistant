import Foundation
import XCTest
@testable import AICallAssistant

final class LiveGuidanceCoordinatorEventTests: XCTestCase {
    func testBudgetFailurePublishesBudgetStoppedAndPersistsSanitizedCode() async throws {
        try await assertFailure(
            .budget,
            expectedStatus: .budgetStopped,
            expectedCode: "spend_limit_exceeded"
        )
    }

    func testContextFailurePublishesContextLimitAndPersistsSanitizedCode() async throws {
        try await assertFailure(
            .contextLimit,
            expectedStatus: .contextLimitReached,
            expectedCode: "context_limit_reached"
        )
    }

    func testGenericFailurePublishesFailedAndPersistsSanitizedCode() async throws {
        try await assertFailure(
            .generic,
            expectedStatus: .failed,
            expectedCode: "provider_failure"
        )
    }

    func testSuccessPublishesTypedEventAndCompatibilityPublication() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = makeSnapshot()
        let store = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let coordinator = LiveGuidanceCoordinator(
            store: store,
            provider: SuccessfulEventGuidanceProvider()
        )
        var eventIterator = coordinator.events.makeAsyncIterator()
        var publicationIterator = coordinator.publications.makeAsyncIterator()

        _ = try await coordinator.enqueue(snapshot: snapshot)
        await coordinator.waitUntilIdle()

        guard case let .published(eventRun)? = await eventIterator.next() else {
            return XCTFail("Expected a published guidance event")
        }
        let compatibilityRun = await publicationIterator.next()
        XCTAssertEqual(eventRun, compatibilityRun)
        XCTAssertEqual(eventRun.snapshotID, snapshot.id)
        XCTAssertEqual(eventRun.pairs.map(\.answer), ["A focused answer."])
    }

    func testSuccessRecoversGenericFailureWithoutClearingTerminalStops() {
        let event = LiveGuidanceEvent.published(
            AnalysisRun(
                id: "run",
                snapshotID: "snapshot",
                trigger: [],
                pairs: [],
                status: .published
            )
        )

        XCTAssertEqual(LiveGuidanceStatus.failed.applying(event), .active)
        XCTAssertEqual(LiveGuidanceStatus.budgetStopped.applying(event), .budgetStopped)
        XCTAssertEqual(
            LiveGuidanceStatus.contextLimitReached.applying(event),
            .contextLimitReached
        )
    }

    func testLateFailureAndEnqueueCannotOverwriteTerminalStop() {
        let failure = LiveGuidanceEvent.failed(
            LiveGuidanceFailureEvent(
                jobID: "older-job",
                status: .failed,
                failureCode: "provider_failure"
            )
        )

        XCTAssertEqual(
            LiveGuidanceStatus.budgetStopped.applying(failure),
            .budgetStopped
        )
        XCTAssertEqual(
            LiveGuidanceStatus.contextLimitReached.applying(failure),
            .contextLimitReached
        )
        XCTAssertEqual(
            LiveGuidanceStatus.budgetStopped.transitioning(to: .active),
            .budgetStopped
        )
        XCTAssertEqual(
            LiveGuidanceStatus.contextLimitReached.transitioning(to: .failed),
            .contextLimitReached
        )
    }

    private func assertFailure(
        _ failure: ThrowingEventGuidanceProvider.Failure,
        expectedStatus: LiveGuidanceStatus,
        expectedCode: String
    ) async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let snapshot = makeSnapshot()
        let store = try GuidanceJobStore(callFolderURL: folder, callID: Self.callID)
        let coordinator = LiveGuidanceCoordinator(
            store: store,
            provider: ThrowingEventGuidanceProvider(failure: failure)
        )
        var iterator = coordinator.events.makeAsyncIterator()

        let enqueued = try await coordinator.enqueue(snapshot: snapshot)
        await coordinator.waitUntilIdle()

        guard case let .failed(event)? = await iterator.next() else {
            return XCTFail("Expected a failed guidance event")
        }
        XCTAssertEqual(event.jobID, enqueued.job.id)
        XCTAssertEqual(event.status, expectedStatus)
        XCTAssertEqual(event.failureCode, expectedCode)

        let jobs = await store.jobs()
        let persisted = try XCTUnwrap(jobs.first(where: { $0.id == enqueued.job.id }))
        XCTAssertEqual(persisted.state, .failed)
        XCTAssertEqual(persisted.failureCode, expectedCode)
    }

    private func makeSnapshot() -> ConversationSnapshot {
        let reference = TurnReference(
            turnID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            revision: 1
        )
        return ConversationSnapshot(
            schemaVersion: 1,
            id: "event-snapshot",
            callID: Self.callID,
            conversationRevision: 1,
            turns: [
                SnapshotTurn(
                    reference: reference,
                    track: .incoming,
                    startCallNanoseconds: 10,
                    endCallNanoseconds: 20,
                    text: "What is the next step?"
                )
            ],
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
            .appendingPathComponent("LiveGuidanceCoordinatorEventTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static let callID = UUID(
        uuidString: "10000000-0000-0000-0000-000000000001"
    )!
}

private struct ThrowingEventGuidanceProvider: LiveGuidanceProvider {
    enum Failure: Sendable {
        case budget
        case contextLimit
        case generic
    }

    let failure: Failure

    func analyze(snapshot _: ConversationSnapshot) async throws -> LiveGuidanceProviderResult {
        switch failure {
        case .budget:
            throw SpendLedgerError.limitExceeded(
                requiredNanoUSD: 1,
                remainingNanoUSD: 0
            )
        case .contextLimit:
            throw OpenAIResponsesGuidanceClientError.contextLimitReached
        case .generic:
            throw GenericEventGuidanceError.failed
        }
    }
}

private enum GenericEventGuidanceError: Error, Sendable {
    case failed
}

private struct SuccessfulEventGuidanceProvider: LiveGuidanceProvider {
    func analyze(snapshot: ConversationSnapshot) async throws -> LiveGuidanceProviderResult {
        let trigger = snapshot.triggerTurns[0]
        let text = snapshot.turns.first(where: { $0.reference == trigger })!.text
        return LiveGuidanceProviderResult(
            questionAnswers: [
                ValidatedGuidanceQuestionAnswer(
                    normalizedQuestion: text,
                    evidence: [
                        QuestionEvidence(
                            turn: trigger,
                            exactQuote: text,
                            unicodeScalarRange: 0..<text.unicodeScalars.count
                        )
                    ],
                    answer: "A focused answer.",
                    advice: "Keep it concrete.",
                    usedTurnIDs: [trigger.turnID],
                    usedContextIDs: []
                )
            ]
        )
    }
}
