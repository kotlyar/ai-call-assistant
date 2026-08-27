import Foundation

struct RecordingReconciliationOutcome: Sendable {
    let recording: Recording
    let job: ReconciliationStoredJob
    let canonicalCommit: CanonicalTranscriptCommit?
}

struct RecordingReconciliationProcessor: @unchecked Sendable {
    let recordingStorage: RecordingStorageService
    let provider: any FileTranscriptionProvider
    let credentialProvider: any ReconciliationCredentialProvider
    let assetInspector: ReconciliationAudioAssetInspector
    let canonicalStore: CanonicalTranscriptStore

    init(
        recordingStorage: RecordingStorageService,
        provider: any FileTranscriptionProvider,
        credentialProvider: any ReconciliationCredentialProvider,
        assetInspector: ReconciliationAudioAssetInspector = ReconciliationAudioAssetInspector(),
        canonicalStore: CanonicalTranscriptStore = CanonicalTranscriptStore()
    ) {
        self.recordingStorage = recordingStorage
        self.provider = provider
        self.credentialProvider = credentialProvider
        self.assetInspector = assetInspector
        self.canonicalStore = canonicalStore
    }

    func process(
        recording original: Recording,
        retryFailed: Bool = false
    ) async throws -> RecordingReconciliationOutcome {
        var recording = original
        guard let metadata = recording.transcription else {
            throw ReconciliationJobStoreError.noJob
        }
        let folderURL = try recordingStorage.folderURL(for: recording)
        let ledger = try CallSpendLedger(
            callFolderURL: folderURL,
            callID: recording.id,
            initialLimitUSD: metadata.frozenConfiguration.initialPerCallSpendLimitUSD
        )
        let store = try ReconciliationJobStore(
            callFolderURL: folderURL,
            callID: recording.id
        )
        let coordinator = ReconciliationCoordinator(
            store: store,
            provider: provider,
            credentialProvider: credentialProvider,
            spendAuthorizer: CallSpendReconciliationAuthorizer(ledger: ledger)
        )

        let job: ReconciliationStoredJob
        if retryFailed, await store.currentJob()?.status == .failed {
            job = try await coordinator.retryFailed()
        } else if await store.currentJob() != nil {
            // Resume the persisted descriptor verbatim. This keeps in-flight
            // jobs recoverable when a newer app version changes chunking rules
            // or deterministic job identifiers.
            job = try await coordinator.resume()
        } else {
            let request = try await makeRequest(
                recording: recording,
                modelID: metadata.fileTranscriptionModelID,
                languages: metadata.frozenConfiguration.transcriptionLanguages
            )
            job = try await coordinator.start(request: request)
        }

        var canonicalCommit: CanonicalTranscriptCommit?
        let writerHasKnownGaps = (metadata.incomingWriterDroppedBuffers ?? 0) > 0
            || (metadata.outgoingWriterDroppedBuffers ?? 0) > 0
        var effectiveStatus = job.status
        var errorCode = job.lastErrorCode
        if job.status == .complete, writerHasKnownGaps {
            effectiveStatus = .incomplete
            errorCode = "recorded_audio_gap"
        }

        if effectiveStatus == .complete, let result = job.result {
            let commit = try canonicalStore.commit(
                result: result,
                for: recording,
                callFolderURL: folderURL,
                providerModelID: job.modelID
            )
            recording.turns = commit.turns
            recording.transcription?.canonicalRevision = commit.document.canonicalRevision
            recording.transcription?.canonicalTranscriptFilename = commit.filename
            recording.transcription?.canonicalTranscriptSHA256 = commit.sha256
            recording.transcription?.finalAnalysisStatus = .pending
            recording.transcription?.finalAnalysisJobID = nil
            recording.transcription?.finalAnalysisAttempts = nil
            recording.transcription?.finalAnalysisUpdatedAt = nil
            recording.transcription?.finalAnalysisResultPointer = nil
            canonicalCommit = commit
        } else {
            switch effectiveStatus {
            case .blockedByCredential:
                recording.transcription?.finalAnalysisStatus = .blockedByCredential
            case .blockedBySpendLimit:
                recording.transcription?.finalAnalysisStatus = .blockedBySpendLimit
            default:
                recording.transcription?.finalAnalysisStatus = .waitingForReconciliation
            }
        }

        recording.transcription?.reconciliationStatus = effectiveStatus
        recording.transcription?.reconciliationJobID = job.id
        recording.transcription?.reconciliationAttempts = job.attempts
        recording.transcription?.reconciliationUpdatedAt = job.updatedAt
        recording.transcription?.lastErrorCode = errorCode
        try recordingStorage.save(recording)

        return RecordingReconciliationOutcome(
            recording: recording,
            job: job,
            canonicalCommit: canonicalCommit
        )
    }

    func repairCanonicalPointerIfNeeded(_ original: Recording) throws -> Recording {
        guard
            let metadata = original.transcription,
            metadata.reconciliationStatus == .complete,
            let filename = metadata.canonicalTranscriptFilename,
            let sha256 = metadata.canonicalTranscriptSHA256
        else { return original }

        let folderURL = try recordingStorage.folderURL(for: original)
        let document = try canonicalStore.load(
            filename: filename,
            expectedSHA256: sha256,
            callID: original.id,
            callFolderURL: folderURL
        )
        let expected = CanonicalTranscriptStore.transcriptTurns(from: document.result)
        guard expected != original.turns else { return original }
        var repaired = original
        repaired.turns = expected
        try recordingStorage.save(repaired)
        return repaired
    }

    private func makeRequest(
        recording: Recording,
        modelID: String,
        languages: [String]
    ) async throws -> ReconciliationRequest {
        let urls = try recordingStorage.audioURLs(for: recording)
        async let incoming = trackInput(track: .incoming, url: urls.incoming)
        async let outgoing = trackInput(track: .outgoing, url: urls.outgoing)
        let inputs = await (incoming, outgoing)
        return ReconciliationRequest(
            callID: recording.id,
            modelID: modelID,
            languages: languages,
            tracks: [inputs.0, inputs.1]
        )
    }

    private func trackInput(
        track: AudioTrack,
        url: URL
    ) async -> ReconciliationTrackInput {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReconciliationTrackInput(
                track: track,
                asset: nil,
                missingReason: "missing_source_file"
            )
        }
        do {
            return ReconciliationTrackInput(
                track: track,
                asset: try await assetInspector.inspect(track: track, url: url)
            )
        } catch {
            return ReconciliationTrackInput(
                track: track,
                asset: nil,
                missingReason: "invalid_source_file"
            )
        }
    }

}
