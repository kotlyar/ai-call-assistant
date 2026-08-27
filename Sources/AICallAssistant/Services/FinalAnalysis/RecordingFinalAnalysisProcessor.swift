import Foundation

struct RecordingFinalAnalysisOutcome: Sendable {
    let recording: Recording
    let job: FinalAnalysisStoredJob
    let publishedResult: FinalAnalysisPublishedResult?
}

enum RecordingFinalAnalysisProcessorError: Error, Equatable, Sendable {
    case missingMetadata
    case reconciliationNotComplete
    case missingCanonicalPointer
    case stalePublishedResult
}

/// Bridges the durable final-analysis domain into a Recording metadata update.
/// The analysis store remains authoritative; metadata is a repairable UI index.
struct RecordingFinalAnalysisProcessor: @unchecked Sendable {
    let recordingStorage: RecordingStorageService
    let provider: any FinalAnalysisProvider
    let credentialProvider: any FinalAnalysisCredentialProvider

    init(
        recordingStorage: RecordingStorageService,
        provider: any FinalAnalysisProvider,
        credentialProvider: any FinalAnalysisCredentialProvider
    ) {
        self.recordingStorage = recordingStorage
        self.provider = provider
        self.credentialProvider = credentialProvider
    }

    func process(
        recording original: Recording,
        reconciliation: ReconciliationStoredJob,
        retryFailed: Bool = false
    ) async throws -> RecordingFinalAnalysisOutcome {
        guard let metadata = original.transcription else {
            throw RecordingFinalAnalysisProcessorError.missingMetadata
        }
        guard metadata.reconciliationStatus == .complete,
              reconciliation.status == .complete else {
            throw RecordingFinalAnalysisProcessorError.reconciliationNotComplete
        }
        guard let canonicalRevision = metadata.canonicalRevision,
              let canonicalHash = metadata.canonicalTranscriptSHA256 else {
            throw RecordingFinalAnalysisProcessorError.missingCanonicalPointer
        }

        let folderURL = try recordingStorage.folderURL(for: original)
        let spendLedger = try CallSpendLedger(
            callFolderURL: folderURL,
            callID: original.id,
            initialLimitUSD: metadata.frozenConfiguration.initialPerCallSpendLimitUSD
        )
        let store = try FinalAnalysisStore(
            callFolderURL: folderURL,
            callID: original.id
        )
        let coordinator = FinalAnalysisCoordinator(
            store: store,
            provider: provider,
            credentialProvider: credentialProvider,
            spendReserver: spendLedger
        )

        let snapshot = try FinalAnalysisSnapshotBuilder().makeSnapshot(
            reconciliation: reconciliation,
            canonicalRevision: canonicalRevision,
            canonicalTranscriptHash: canonicalHash,
            frozenContexts: metadata.frozenContexts,
            configuration: metadata.frozenConfiguration
        )
        _ = try await store.repairTargetSnapshotIfMatching(snapshot)

        let execution: FinalAnalysisExecutionResult
        let authoritativeJob = try? await store.targetJob()
        let authoritativeMatchesCanonical = authoritativeJob?.canonicalRevision
                == canonicalRevision
            && authoritativeJob?.canonicalTranscriptHash == canonicalHash.lowercased()
        if let authoritativeJob,
           authoritativeMatchesCanonical,
           authoritativeJob.status == .complete {
            if let published = try await store.repairPublishedTarget(
                canonicalRevision: canonicalRevision,
                canonicalTranscriptHash: canonicalHash
            ) {
                execution = FinalAnalysisExecutionResult(
                    job: try await store.targetJob(),
                    publishedResult: published
                )
            } else {
                let invalidated = try await store.invalidateCompletedTargetForRetry(
                    errorCode: "published_artifact_unrecoverable"
                )
                if retryFailed {
                    execution = try await coordinator.retryFailed()
                } else {
                    execution = FinalAnalysisExecutionResult(
                        job: invalidated,
                        publishedResult: nil
                    )
                }
            }
        } else if retryFailed,
                  authoritativeMatchesCanonical,
                  authoritativeJob?.status == .failed {
            execution = try await coordinator.retryFailed()
        } else {
            execution = try await coordinator.start(
                reconciliation: reconciliation,
                canonicalRevision: canonicalRevision,
                canonicalTranscriptHash: canonicalHash,
                frozenContexts: metadata.frozenContexts,
                configuration: metadata.frozenConfiguration
            )
        }

        if let published = execution.publishedResult,
           !published.pointer.matches(
               canonicalRevision: canonicalRevision,
               canonicalTranscriptHash: canonicalHash
           ) {
            throw RecordingFinalAnalysisProcessorError.stalePublishedResult
        }

        var recording = original
        recording.transcription?.finalAnalysisStatus = execution.job.status
        recording.transcription?.finalAnalysisJobID = execution.job.id
        recording.transcription?.finalAnalysisAttempts = execution.job.attempts
        recording.transcription?.finalAnalysisUpdatedAt = execution.job.updatedAt
        recording.transcription?.finalAnalysisResultPointer = execution.publishedResult?.pointer
        recording.transcription?.lastErrorCode = execution.job.lastErrorCode
        try recordingStorage.save(recording)

        return RecordingFinalAnalysisOutcome(
            recording: recording,
            job: execution.job,
            publishedResult: execution.publishedResult
        )
    }

    func loadPublishedResult(
        for recording: Recording
    ) async throws -> FinalAnalysisPublishedResult? {
        guard let metadata = recording.transcription,
              metadata.reconciliationStatus == .complete,
              metadata.finalAnalysisStatus == .complete,
              let revision = metadata.canonicalRevision,
              let hash = metadata.canonicalTranscriptSHA256 else {
            return nil
        }
        let folderURL = try recordingStorage.folderURL(for: recording)
        let store = try FinalAnalysisStore(
            callFolderURL: folderURL,
            callID: recording.id
        )
        if let published = try await store.repairPublishedTarget(
            canonicalRevision: revision,
            canonicalTranscriptHash: hash
        ) {
            let job = try await store.targetJob()
            var repaired = recording
            repaired.transcription?.finalAnalysisStatus = .complete
            repaired.transcription?.finalAnalysisJobID = job.id
            repaired.transcription?.finalAnalysisAttempts = job.attempts
            repaired.transcription?.finalAnalysisUpdatedAt = job.updatedAt
            repaired.transcription?.finalAnalysisResultPointer = published.pointer
            repaired.transcription?.lastErrorCode = nil
            if repaired != recording {
                try recordingStorage.save(repaired)
            }
            return published
        }

        let target = try? await store.targetJob()
        guard target?.status == .complete,
              target?.canonicalRevision == revision,
              target?.canonicalTranscriptHash == hash.lowercased() else {
            return nil
        }
        let invalidated = try await store.invalidateCompletedTargetForRetry(
            errorCode: "published_artifact_unrecoverable"
        )
        var failed = recording
        failed.transcription?.finalAnalysisStatus = .failed
        failed.transcription?.finalAnalysisJobID = invalidated.id
        failed.transcription?.finalAnalysisAttempts = invalidated.attempts
        failed.transcription?.finalAnalysisUpdatedAt = invalidated.updatedAt
        failed.transcription?.finalAnalysisResultPointer = nil
        failed.transcription?.lastErrorCode = invalidated.lastErrorCode
        try recordingStorage.save(failed)
        return nil
    }
}
