import Foundation

struct LiveGuidanceProviderResult: Equatable, Sendable {
    let questionAnswers: [ValidatedGuidanceQuestionAnswer]
}

protocol LiveGuidanceProvider: Sendable {
    func analyze(snapshot: ConversationSnapshot) async throws -> LiveGuidanceProviderResult
}

struct LiveGuidanceFailureEvent: Equatable, Sendable {
    let jobID: String
    let status: LiveGuidanceStatus
    let failureCode: String
}

enum LiveGuidanceEvent: Equatable, Sendable {
    case published(AnalysisRun)
    case failed(LiveGuidanceFailureEvent)
}

extension LiveGuidanceStatus {
    private var isTerminalStop: Bool {
        self == .budgetStopped || self == .contextLimitReached
    }

    /// Spend and full-context limits are immutable for the active call. Once
    /// reached, an older in-flight result or a later local failure must not
    /// replace the reason live guidance stopped.
    func transitioning(to proposed: LiveGuidanceStatus) -> LiveGuidanceStatus {
        isTerminalStop ? self : proposed
    }

    func applying(_ event: LiveGuidanceEvent) -> LiveGuidanceStatus {
        guard !isTerminalStop else { return self }
        switch event {
        case .published:
            // A transient provider/network failure is recoverable.
            return self == .failed ? .active : self
        case let .failed(failure):
            return failure.status
        }
    }
}

actor LiveGuidanceCoordinator {
    static let defaultMaximumConcurrentJobs = 2

    private let store: GuidanceJobStore
    private let provider: any LiveGuidanceProvider
    private let maximumConcurrentJobs: Int
    private let publicationsContinuation: AsyncStream<AnalysisRun>.Continuation
    private let eventsContinuation: AsyncStream<LiveGuidanceEvent>.Continuation
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Compatibility stream for consumers that only need completed cards.
    nonisolated let publications: AsyncStream<AnalysisRun>
    /// Authoritative stream for UI state: successful publications and typed failures.
    nonisolated let events: AsyncStream<LiveGuidanceEvent>

    init(
        store: GuidanceJobStore,
        provider: any LiveGuidanceProvider,
        maximumConcurrentJobs: Int = LiveGuidanceCoordinator.defaultMaximumConcurrentJobs
    ) {
        precondition(
            (1...LiveGuidanceCoordinator.defaultMaximumConcurrentJobs)
                .contains(maximumConcurrentJobs),
            "Maximum concurrency must be between one and two"
        )
        self.store = store
        self.provider = provider
        self.maximumConcurrentJobs = maximumConcurrentJobs

        let stream = AsyncStream<AnalysisRun>.makeStream(bufferingPolicy: .unbounded)
        publications = stream.stream
        publicationsContinuation = stream.continuation

        let eventStream = AsyncStream<LiveGuidanceEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        events = eventStream.stream
        eventsContinuation = eventStream.continuation
    }

    @discardableResult
    func enqueue(snapshot: ConversationSnapshot) async throws -> GuidanceEnqueueResult {
        let result = try await store.enqueue(snapshot: snapshot)
        try await scheduleAvailableJobs()
        return result
    }

    func resumePendingJobs() async throws {
        try await scheduleAvailableJobs()
    }

    func waitUntilIdle() async {
        while true {
            let tasks = Array(activeTasks.values)
            if tasks.isEmpty {
                if await store.hasQueuedJobs() {
                    try? await scheduleAvailableJobs()
                    await Task.yield()
                    continue
                }
                return
            }
            for task in tasks {
                await task.value
            }
        }
    }

    func activeJobCount() -> Int {
        activeTasks.count
    }

    private func scheduleAvailableJobs() async throws {
        let availableSlots = maximumConcurrentJobs - activeTasks.count
        guard availableSlots > 0 else { return }
        let jobs = try await store.claimNextQueuedJobs(limit: availableSlots)
        for job in jobs {
            activeTasks[job.id] = Task { [weak self] in
                guard let self else { return }
                await self.execute(job)
            }
        }
    }

    private func execute(_ job: GuidanceStoredJob) async {
        do {
            let snapshot = try await store.snapshot(for: job.id)
            let providerResult = try await provider.analyze(snapshot: snapshot)
            let isLate = try await store.hasNewerUnrelatedJob(than: job.id)
            let orderedAnswers = Self.canonicalAnswerOrder(
                providerResult.questionAnswers,
                snapshot: snapshot
            )
            let pairs = orderedAnswers.enumerated().map { ordinal, answer in
                QuestionAnswerPair(
                    id: QuestionAnswerPair.deterministicID(
                        runID: job.runID,
                        canonicalOrdinal: ordinal
                    ),
                    snapshotID: snapshot.id,
                    normalizedQuestion: answer.normalizedQuestion,
                    evidence: answer.evidence,
                    answer: answer.answer,
                    advice: answer.advice,
                    usedTurnIDs: answer.usedTurnIDs,
                    usedContextIDs: answer.usedContextIDs,
                    isLate: isLate
                )
            }
            let run = AnalysisRun(
                id: job.runID,
                snapshotID: snapshot.id,
                trigger: snapshot.triggerTurns,
                pairs: pairs,
                status: .published
            )
            let publication = try await store.publish(jobID: job.id, run: run)
            if case let .published(run) = publication {
                publicationsContinuation.yield(run)
                eventsContinuation.yield(.published(run))
            }
        } catch {
            let failureCode = Self.sanitizedFailureCode(error)
            try? await store.markFailed(
                jobID: job.id,
                failureCode: failureCode
            )
            eventsContinuation.yield(
                .failed(
                    LiveGuidanceFailureEvent(
                        jobID: job.id,
                        status: Self.guidanceStatus(for: error),
                        failureCode: failureCode
                    )
                )
            )
        }

        activeTasks[job.id] = nil
        try? await scheduleAvailableJobs()
    }

    private static func canonicalAnswerOrder(
        _ answers: [ValidatedGuidanceQuestionAnswer],
        snapshot: ConversationSnapshot
    ) -> [ValidatedGuidanceQuestionAnswer] {
        let orderedTurns = snapshot.canonicallyOrderedTurns
        let turnOrder = Dictionary(
            uniqueKeysWithValues: orderedTurns.enumerated().map { ($0.element.reference, $0.offset) }
        )

        return answers.sorted { lhs, rhs in
            let lhsKey = evidenceOrderKey(lhs.evidence, turnOrder: turnOrder)
            let rhsKey = evidenceOrderKey(rhs.evidence, turnOrder: turnOrder)
            if lhsKey.turn != rhsKey.turn { return lhsKey.turn < rhsKey.turn }
            if lhsKey.scalar != rhsKey.scalar { return lhsKey.scalar < rhsKey.scalar }
            return lhs.normalizedQuestion < rhs.normalizedQuestion
        }
    }

    private static func evidenceOrderKey(
        _ evidence: [QuestionEvidence],
        turnOrder: [TurnReference: Int]
    ) -> (turn: Int, scalar: Int) {
        var earliest = (turn: Int.max, scalar: Int.max)
        for item in evidence {
            let candidate = (
                turn: turnOrder[item.turn] ?? Int.max,
                scalar: item.unicodeScalarRange?.lowerBound ?? Int.max
            )
            if candidate.turn < earliest.turn
                || (candidate.turn == earliest.turn && candidate.scalar < earliest.scalar) {
                earliest = candidate
            }
        }
        return earliest
    }

    private static func sanitizedFailureCode(_ error: Error) -> String {
        if let error = error as? SpendLedgerError,
           case .limitExceeded = error {
            return "spend_limit_exceeded"
        }
        if let error = error as? OpenAIResponsesGuidanceClientError {
            switch error {
            case .contextLimitReached:
                return "context_limit_reached"
            case .providerError:
                return "provider_error"
            case .incomplete:
                return "incomplete_response"
            case .refusal:
                return "refusal"
            case .malformedResponse:
                return "malformed_response"
            case .invalidStructuredOutput:
                return "invalid_structured_output"
            case .validationFailed:
                return "validation_failed"
            }
        }
        return "provider_failure"
    }

    private static func guidanceStatus(for error: Error) -> LiveGuidanceStatus {
        if let error = error as? SpendLedgerError,
           case .limitExceeded = error {
            return .budgetStopped
        }
        if let error = error as? OpenAIResponsesGuidanceClientError,
           case .contextLimitReached = error {
            return .contextLimitReached
        }
        return .failed
    }
}
