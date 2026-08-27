import Foundation

struct FinalAnalysisExecutionResult: Equatable, Sendable {
    let job: FinalAnalysisStoredJob
    let publishedResult: FinalAnalysisPublishedResult?
}

actor FinalAnalysisCoordinator {
    private let store: FinalAnalysisStore
    private let provider: any FinalAnalysisProvider
    private let credentialProvider: any FinalAnalysisCredentialProvider
    private let spendReserver: any FinalAnalysisSpendReserver
    private let snapshotBuilder: FinalAnalysisSnapshotBuilder
    private let maximumAttemptsPerTrigger: Int

    init(
        store: FinalAnalysisStore,
        provider: any FinalAnalysisProvider,
        credentialProvider: any FinalAnalysisCredentialProvider,
        spendReserver: any FinalAnalysisSpendReserver,
        snapshotBuilder: FinalAnalysisSnapshotBuilder = FinalAnalysisSnapshotBuilder(),
        maximumAttemptsPerTrigger: Int = 2
    ) {
        precondition(maximumAttemptsPerTrigger > 0)
        self.store = store
        self.provider = provider
        self.credentialProvider = credentialProvider
        self.spendReserver = spendReserver
        self.snapshotBuilder = snapshotBuilder
        self.maximumAttemptsPerTrigger = maximumAttemptsPerTrigger
    }

    /// This is the only new-run entry point: snapshot creation fails unless the
    /// reconciliation job and both required track coverages are complete.
    func start(
        reconciliation: ReconciliationStoredJob,
        canonicalRevision: Int64,
        canonicalTranscriptHash: String,
        frozenContexts: FrozenContextSnapshot,
        configuration: GuidanceConfigurationSnapshot
    ) async throws -> FinalAnalysisExecutionResult {
        let snapshot = try snapshotBuilder.makeSnapshot(
            reconciliation: reconciliation,
            canonicalRevision: canonicalRevision,
            canonicalTranscriptHash: canonicalTranscriptHash,
            frozenContexts: frozenContexts,
            configuration: configuration
        )
        let job = try await store.enqueue(snapshot: snapshot)
        return try await process(jobID: job.id)
    }

    /// Relaunch recovery uses the persisted immutable snapshot; it never rebuilds
    /// against mutable contexts or a different canonical transcript.
    func recover() async throws -> FinalAnalysisExecutionResult {
        try await store.resumeBlockedTargetJob()
        let target = try await store.targetJob()
        return try await process(jobID: target.id)
    }

    func retryFailed() async throws -> FinalAnalysisExecutionResult {
        let job = try await store.retryFailedTargetJob()
        let priorMaximum = job.triggers.map(\.attempts).max() ?? 0
        return try await process(
            jobID: job.id,
            maximumAttempts: priorMaximum + maximumAttemptsPerTrigger
        )
    }

    private func process(
        jobID: String,
        maximumAttempts: Int? = nil
    ) async throws -> FinalAnalysisExecutionResult {
        var job = try await store.job(id: jobID)
        if job.status == .complete {
            let published = try await store.currentPublishedResult(
                canonicalRevision: job.canonicalRevision,
                canonicalTranscriptHash: job.canonicalTranscriptHash
            )
            return FinalAnalysisExecutionResult(job: job, publishedResult: published)
        }
        if Self.isTerminalWithoutArtifact(job.status) {
            return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
        }
        if job.status == .blockedByCredential || job.status == .blockedBySpendLimit {
            try await store.resumeBlockedTargetJob()
        }

        let snapshot = try await store.snapshot(for: jobID)
        let attemptLimit = maximumAttempts ?? maximumAttemptsPerTrigger
        var forceFailure = false
        while let claim = try await store.claimNextTrigger(
            jobID: jobID,
            maximumAttempts: attemptLimit
        ) {
            let currentKey: String?
            do {
                currentKey = try await credentialProvider.currentAPIKey()
            } catch {
                job = try await store.blockTrigger(
                    jobID: claim.jobID,
                    triggerJobID: claim.triggerJobID,
                    status: .blockedByCredential,
                    errorCode: "credential_lookup_failed",
                    countsAsAttempt: false
                )
                return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
            }
            guard let apiKey = currentKey?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !apiKey.isEmpty else {
                job = try await store.blockTrigger(
                    jobID: claim.jobID,
                    triggerJobID: claim.triggerJobID,
                    status: .blockedByCredential,
                    errorCode: "credential_missing",
                    countsAsAttempt: false
                )
                return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
            }

            let request = FinalAnalysisProviderRequest(
                jobID: claim.jobID,
                triggerJobID: claim.triggerJobID,
                idempotencyKey: claim.triggerJobID,
                snapshot: snapshot,
                triggerTurnID: claim.triggerTurnID,
                attempt: claim.attempt,
                apiKey: apiKey
            )
            let spendEstimate: OpenAIResponsesRequestSpendEstimate
            do {
                spendEstimate = try FinalAnalysisRequestSpendEstimator().estimate(
                    for: request
                )
            } catch {
                try await store.markTriggerFailed(
                    jobID: claim.jobID,
                    triggerJobID: claim.triggerJobID,
                    errorCode: "request_estimation_failed"
                )
                job = try await store.markFailed(
                    jobID: claim.jobID,
                    errorCode: "request_estimation_failed"
                )
                return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
            }

            do {
                try await spendReserver.reserveResponses(
                    id: "final-responses:\(claim.triggerJobID):attempt:\(claim.attempt)",
                    modelID: snapshot.configuration.responsesModelID,
                    estimatedInputTokens: spendEstimate.reservedInputTokens,
                    maximumOutputTokens: snapshot.configuration.maxOutputTokens
                )
            } catch let error as SpendLedgerError {
                if case .limitExceeded = error {
                    job = try await store.blockTrigger(
                        jobID: claim.jobID,
                        triggerJobID: claim.triggerJobID,
                        status: .blockedBySpendLimit,
                        errorCode: "spend_limit_reached",
                        countsAsAttempt: false
                    )
                    return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
                }
                try await store.markTriggerFailed(
                    jobID: claim.jobID,
                    triggerJobID: claim.triggerJobID,
                    errorCode: "spend_reservation_failed"
                )
                job = try await store.markFailed(
                    jobID: claim.jobID,
                    errorCode: "spend_reservation_failed"
                )
                return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
            } catch {
                job = try await store.blockTrigger(
                    jobID: claim.jobID,
                    triggerJobID: claim.triggerJobID,
                    status: .blockedBySpendLimit,
                    errorCode: "spend_reservation_failed",
                    countsAsAttempt: false
                )
                return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
            }
            do {
                let result = try await provider.analyze(request: request)
                try await store.markTriggerComplete(
                    jobID: claim.jobID,
                    triggerJobID: claim.triggerJobID,
                    result: result
                )
            } catch {
                let failure = Self.classify(error)
                if failure.credentialBlocked {
                    job = try await store.blockTrigger(
                        jobID: claim.jobID,
                        triggerJobID: claim.triggerJobID,
                        status: .blockedByCredential,
                        errorCode: "credential_rejected",
                        countsAsAttempt: true
                    )
                    return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
                }
                if failure.contextLimit {
                    job = try await store.markContextLimitExceeded(
                        jobID: claim.jobID,
                        triggerJobID: claim.triggerJobID
                    )
                    return FinalAnalysisExecutionResult(
                        job: job,
                        publishedResult: nil
                    )
                }
                try await store.markTriggerFailed(
                    jobID: claim.jobID,
                    triggerJobID: claim.triggerJobID,
                    errorCode: failure.code
                )
                if !failure.retryable {
                    forceFailure = true
                    break
                }
            }
        }

        job = try await store.job(id: jobID)
        let hasFailedTrigger = job.triggers.contains { $0.state == .failed }
        // A process can die after a trigger was durably claimed on its final
        // allowed attempt but before the provider result is persisted. Reopen
        // turns that trigger back into `pending` while retaining its attempt
        // count, so there may be no claimable work even though publication is
        // incomplete. Persist a retryable failed job instead of leaving the
        // durable state wedged at `pending` forever.
        let hasIncompleteTrigger = job.triggers.contains {
            $0.state != .complete || $0.result == nil
        }
        if forceFailure || hasFailedTrigger || hasIncompleteTrigger {
            job = try await store.markFailed(
                jobID: jobID,
                errorCode: job.lastErrorCode ?? "trigger_retry_exhausted"
            )
            return FinalAnalysisExecutionResult(job: job, publishedResult: nil)
        }

        let published = try await store.publish(jobID: jobID)
        job = try await store.job(id: jobID)
        return FinalAnalysisExecutionResult(job: job, publishedResult: published)
    }

    private static func classify(
        _ error: Error
    ) -> (
        code: String,
        retryable: Bool,
        contextLimit: Bool,
        credentialBlocked: Bool
    ) {
        if let providerError = error as? FinalAnalysisProviderError,
           providerError == .contextLimitExceeded {
            return ("context_limit_exceeded", false, true, false)
        }
        if let providerError = error as? FinalAnalysisProviderError,
           case let .providerError(statusCode, _) = providerError,
           statusCode == 401 || statusCode == 403 {
            return ("credential_rejected", false, false, true)
        }
        if let failure = error as? any FinalAnalysisProviderFailure {
            return (
                failure.finalAnalysisFailureCode,
                failure.isRetryableForFinalAnalysis,
                false,
                false
            )
        }
        return ("provider_failure", true, false, false)
    }

    private static func isTerminalWithoutArtifact(_ status: FinalAnalysisStatus) -> Bool {
        status == .contextLimitExceeded || status == .failed
    }
}
