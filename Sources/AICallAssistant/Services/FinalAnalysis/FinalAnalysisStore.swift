import Foundation

enum FinalAnalysisTriggerState: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case running
    case complete
    case failed
}

struct FinalAnalysisTriggerJob: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let triggerTurnID: String
    let triggerStartCallNanoseconds: UInt64
    var state: FinalAnalysisTriggerState
    var attempts: Int
    var lastErrorCode: String?
    var completedAt: Date?
    var result: FinalAnalysisTriggerResult?
}

struct FinalAnalysisStoredJob: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let callID: UUID
    let snapshotID: String
    let canonicalRevision: Int64
    let canonicalTranscriptHash: String
    let responsesModelID: String
    let createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var status: FinalAnalysisStatus
    var attempts: Int
    var lastErrorCode: String?
    var triggers: [FinalAnalysisTriggerJob]
    var resultPointer: FinalAnalysisResultPointer?
}

struct ClaimedFinalAnalysisTrigger: Equatable, Sendable {
    let jobID: String
    let triggerJobID: String
    let triggerTurnID: String
    let attempt: Int
}

enum FinalAnalysisStoreError: Error, Equatable, Sendable {
    case callIDMismatch(expected: UUID, actual: UUID)
    case invalidPerspective(AnalysisPerspective)
    case staleCanonicalRevision(candidate: Int64, current: Int64)
    case canonicalRevisionCollision(Int64)
    case snapshotCollision(String)
    case noTargetJob
    case jobNotFound(String)
    case staleJob(String)
    case triggerNotFound(String)
    case invalidTriggerTransition(
        triggerID: String,
        from: FinalAnalysisTriggerState,
        to: FinalAnalysisTriggerState
    )
    case invalidJobTransition(from: FinalAnalysisStatus, to: FinalAnalysisStatus)
    case resultDoesNotMatchTrigger(String)
    case incompleteTriggers
    case artifactCollision(String)
    case corruptPublishedArtifact(String)
}

actor FinalAnalysisStore {
    nonisolated let callID: UUID
    nonisolated let callFolderURL: URL
    nonisolated let finalAnalysisFolderURL: URL
    nonisolated let snapshotsFolderURL: URL
    nonisolated let manifestURL: URL

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var document: FinalAnalysisDocument

    init(
        callFolderURL: URL,
        callID: UUID,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.callID = callID
        self.callFolderURL = callFolderURL
        self.fileManager = fileManager
        self.now = now

        let folder = callFolderURL.appendingPathComponent(
            "final-analysis",
            isDirectory: true
        )
        let snapshots = folder.appendingPathComponent("snapshots", isDirectory: true)
        let manifest = folder.appendingPathComponent("final-analysis-jobs.json")
        finalAnalysisFolderURL = folder
        snapshotsFolderURL = snapshots
        manifestURL = manifest
        try fileManager.createDirectory(at: snapshots, withIntermediateDirectories: true)

        var loaded: FinalAnalysisDocument
        if fileManager.fileExists(atPath: manifest.path) {
            loaded = try Self.decoder.decode(
                FinalAnalysisDocument.self,
                from: Data(contentsOf: manifest)
            )
        } else {
            loaded = FinalAnalysisDocument(
                schemaVersion: 1,
                callID: callID,
                target: nil,
                currentResultPointer: nil,
                jobs: []
            )
        }
        guard loaded.callID == callID else {
            throw FinalAnalysisStoreError.callIDMismatch(
                expected: callID,
                actual: loaded.callID
            )
        }

        var recovered = false
        for jobIndex in loaded.jobs.indices {
            for triggerIndex in loaded.jobs[jobIndex].triggers.indices
            where loaded.jobs[jobIndex].triggers[triggerIndex].state == .running {
                loaded.jobs[jobIndex].triggers[triggerIndex].state = .pending
                recovered = true
            }
            if loaded.jobs[jobIndex].status == .running {
                loaded.jobs[jobIndex].status = .pending
                loaded.jobs[jobIndex].updatedAt = now()
                recovered = true
            }
        }
        document = loaded
        if recovered || !fileManager.fileExists(atPath: manifest.path) {
            try Self.persist(loaded, to: manifest)
        }
    }

    /// Enqueue also advances the private canonical target. A newer canonical
    /// target clears the renderable pointer before any provider work starts.
    func enqueue(snapshot: FinalAnalysisSnapshot) throws -> FinalAnalysisStoredJob {
        guard snapshot.callID == callID else {
            throw FinalAnalysisStoreError.callIDMismatch(
                expected: callID,
                actual: snapshot.callID
            )
        }
        guard snapshot.perspective == .postCallRetrospective else {
            throw FinalAnalysisStoreError.invalidPerspective(snapshot.perspective)
        }
        try persistSnapshot(snapshot)

        let jobID = "final-analysis-job-v1_\(snapshot.id)"
        if let target = document.target {
            if snapshot.canonicalRevision < target.canonicalRevision {
                throw FinalAnalysisStoreError.staleCanonicalRevision(
                    candidate: snapshot.canonicalRevision,
                    current: target.canonicalRevision
                )
            }
            if snapshot.canonicalRevision == target.canonicalRevision,
               snapshot.canonicalTranscriptHash != target.canonicalTranscriptHash {
                throw FinalAnalysisStoreError.canonicalRevisionCollision(
                    snapshot.canonicalRevision
                )
            }
        }

        if let existing = document.jobs.first(where: { $0.id == jobID }) {
            return existing
        }

        let timestamp = now()
        let triggers = try snapshot.canonicallyOrderedTurns
            .filter { $0.track == .incoming }
            .map { turn in
                FinalAnalysisTriggerJob(
                    id: try Self.triggerJobID(jobID: jobID, turnID: turn.id),
                    triggerTurnID: turn.id,
                    triggerStartCallNanoseconds: turn.startCallNanoseconds,
                    state: .pending,
                    attempts: 0,
                    lastErrorCode: nil,
                    completedAt: nil,
                    result: nil
                )
            }
        let job = FinalAnalysisStoredJob(
            id: jobID,
            callID: callID,
            snapshotID: snapshot.id,
            canonicalRevision: snapshot.canonicalRevision,
            canonicalTranscriptHash: snapshot.canonicalTranscriptHash,
            responsesModelID: snapshot.configuration.responsesModelID,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: nil,
            completedAt: nil,
            status: .pending,
            attempts: 0,
            lastErrorCode: nil,
            triggers: triggers,
            resultPointer: nil
        )

        var updated = document
        updated.jobs.append(job)
        updated.target = FinalAnalysisTarget(
            canonicalRevision: snapshot.canonicalRevision,
            canonicalTranscriptHash: snapshot.canonicalTranscriptHash,
            snapshotID: snapshot.id,
            jobID: jobID
        )
        updated.currentResultPointer = nil
        try commit(updated)
        return job
    }

    func targetJob() throws -> FinalAnalysisStoredJob {
        guard let target = document.target,
              let job = document.jobs.first(where: { $0.id == target.jobID }) else {
            throw FinalAnalysisStoreError.noTargetJob
        }
        return job
    }

    func job(id: String) throws -> FinalAnalysisStoredJob {
        guard let job = document.jobs.first(where: { $0.id == id }) else {
            throw FinalAnalysisStoreError.jobNotFound(id)
        }
        return job
    }

    func snapshot(for jobID: String) throws -> FinalAnalysisSnapshot {
        let job = try job(id: jobID)
        let snapshot = try Self.decoder.decode(
            FinalAnalysisSnapshot.self,
            from: Data(contentsOf: snapshotURL(for: job.snapshotID))
        )
        guard snapshot.id == job.snapshotID, snapshot.callID == callID else {
            throw FinalAnalysisStoreError.snapshotCollision(job.snapshotID)
        }
        return snapshot
    }

    func resumeBlockedTargetJob() throws {
        var job = try targetJob()
        guard job.status == .blockedByCredential
                || job.status == .blockedBySpendLimit else {
            return
        }
        job.status = .pending
        job.completedAt = nil
        job.updatedAt = now()
        try replaceJob(job)
    }

    func retryFailedTargetJob() throws -> FinalAnalysisStoredJob {
        var job = try targetJob()
        guard job.status == .failed else {
            throw FinalAnalysisStoreError.invalidJobTransition(
                from: job.status,
                to: .pending
            )
        }
        for index in job.triggers.indices where job.triggers[index].state == .failed {
            job.triggers[index].state = .pending
            job.triggers[index].lastErrorCode = nil
            job.triggers[index].completedAt = nil
        }
        job.status = .pending
        job.lastErrorCode = nil
        job.completedAt = nil
        job.updatedAt = now()
        try replaceJob(job)
        return job
    }

    /// Restores a missing or unreadable immutable snapshot from the same
    /// authoritative reconciliation inputs. A different snapshot ID is never
    /// substituted for the current target.
    @discardableResult
    func repairTargetSnapshotIfMatching(
        _ snapshot: FinalAnalysisSnapshot
    ) throws -> Bool {
        guard let target = document.target,
              target.canonicalRevision == snapshot.canonicalRevision,
              target.canonicalTranscriptHash == snapshot.canonicalTranscriptHash,
              let job = document.jobs.first(where: { $0.id == target.jobID }) else {
            return false
        }
        guard target.snapshotID == snapshot.id,
              job.snapshotID == snapshot.id,
              job.callID == snapshot.callID else {
            throw FinalAnalysisStoreError.snapshotCollision(snapshot.id)
        }

        let url = snapshotURL(for: snapshot.id)
        if let data = try? Data(contentsOf: url),
           let existing = try? Self.decoder.decode(FinalAnalysisSnapshot.self, from: data),
           existing == snapshot {
            return true
        }
        try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
        return true
    }

    func claimNextTrigger(
        jobID: String,
        maximumAttempts: Int
    ) throws -> ClaimedFinalAnalysisTrigger? {
        guard maximumAttempts > 0 else { return nil }
        try requireCurrentTarget(jobID: jobID)
        var job = try job(id: jobID)
        guard job.status == .pending || job.status == .running else { return nil }

        let candidates = job.triggers.indices.filter { index in
            let trigger = job.triggers[index]
            return (trigger.state == .pending || trigger.state == .failed)
                && trigger.attempts < maximumAttempts
        }.sorted { lhs, rhs in
            let left = job.triggers[lhs]
            let right = job.triggers[rhs]
            if left.triggerStartCallNanoseconds != right.triggerStartCallNanoseconds {
                return left.triggerStartCallNanoseconds < right.triggerStartCallNanoseconds
            }
            return left.id < right.id
        }
        guard let index = candidates.first else { return nil }

        job.triggers[index].state = .running
        job.triggers[index].attempts += 1
        job.status = .running
        job.attempts += 1
        job.startedAt = job.startedAt ?? now()
        job.updatedAt = now()
        try replaceJob(job)
        return ClaimedFinalAnalysisTrigger(
            jobID: job.id,
            triggerJobID: job.triggers[index].id,
            triggerTurnID: job.triggers[index].triggerTurnID,
            attempt: job.triggers[index].attempts
        )
    }

    func markTriggerComplete(
        jobID: String,
        triggerJobID: String,
        result: FinalAnalysisTriggerResult
    ) throws {
        var job = try job(id: jobID)
        guard let index = job.triggers.firstIndex(where: { $0.id == triggerJobID }) else {
            throw FinalAnalysisStoreError.triggerNotFound(triggerJobID)
        }
        let existing = job.triggers[index]
        if existing.state == .complete {
            guard existing.result == result else {
                throw FinalAnalysisStoreError.resultDoesNotMatchTrigger(triggerJobID)
            }
            return
        }
        guard existing.state == .running else {
            throw FinalAnalysisStoreError.invalidTriggerTransition(
                triggerID: triggerJobID,
                from: existing.state,
                to: .complete
            )
        }
        guard result.triggerTurnID == existing.triggerTurnID else {
            throw FinalAnalysisStoreError.resultDoesNotMatchTrigger(triggerJobID)
        }
        job.triggers[index].state = .complete
        job.triggers[index].lastErrorCode = nil
        job.triggers[index].completedAt = now()
        job.triggers[index].result = result
        job.lastErrorCode = nil
        job.updatedAt = now()
        try replaceJob(job)
    }

    func markTriggerFailed(
        jobID: String,
        triggerJobID: String,
        errorCode: String
    ) throws {
        var job = try job(id: jobID)
        guard let index = job.triggers.firstIndex(where: { $0.id == triggerJobID }) else {
            throw FinalAnalysisStoreError.triggerNotFound(triggerJobID)
        }
        let existing = job.triggers[index]
        guard existing.state == .running else {
            throw FinalAnalysisStoreError.invalidTriggerTransition(
                triggerID: triggerJobID,
                from: existing.state,
                to: .failed
            )
        }
        let code = Self.sanitizedCode(errorCode)
        job.triggers[index].state = .failed
        job.triggers[index].lastErrorCode = code
        job.lastErrorCode = code
        job.updatedAt = now()
        try replaceJob(job)
    }

    func markContextLimitExceeded(
        jobID: String,
        triggerJobID: String
    ) throws -> FinalAnalysisStoredJob {
        var job = try job(id: jobID)
        guard let index = job.triggers.firstIndex(where: { $0.id == triggerJobID }) else {
            throw FinalAnalysisStoreError.triggerNotFound(triggerJobID)
        }
        let existing = job.triggers[index]
        guard existing.state == .running else {
            throw FinalAnalysisStoreError.invalidTriggerTransition(
                triggerID: triggerJobID,
                from: existing.state,
                to: .failed
            )
        }
        job.triggers[index].state = .failed
        job.triggers[index].lastErrorCode = "context_limit_exceeded"
        job.status = .contextLimitExceeded
        job.lastErrorCode = "context_limit_exceeded"
        job.completedAt = now()
        job.updatedAt = now()
        try replaceJob(job)
        return job
    }

    func blockTrigger(
        jobID: String,
        triggerJobID: String,
        status: FinalAnalysisStatus,
        errorCode: String,
        countsAsAttempt: Bool
    ) throws -> FinalAnalysisStoredJob {
        guard status == .blockedByCredential || status == .blockedBySpendLimit else {
            throw FinalAnalysisStoreError.invalidJobTransition(
                from: try job(id: jobID).status,
                to: status
            )
        }
        var job = try job(id: jobID)
        guard let index = job.triggers.firstIndex(where: { $0.id == triggerJobID }) else {
            throw FinalAnalysisStoreError.triggerNotFound(triggerJobID)
        }
        let existing = job.triggers[index]
        guard existing.state == .running else {
            throw FinalAnalysisStoreError.invalidTriggerTransition(
                triggerID: triggerJobID,
                from: existing.state,
                to: .pending
            )
        }
        job.triggers[index].state = .pending
        if !countsAsAttempt {
            job.triggers[index].attempts = max(0, job.triggers[index].attempts - 1)
            job.attempts = max(0, job.attempts - 1)
        }
        job.status = status
        job.lastErrorCode = Self.sanitizedCode(errorCode)
        job.updatedAt = now()
        try replaceJob(job)
        return job
    }

    func markFailed(jobID: String, errorCode: String) throws -> FinalAnalysisStoredJob {
        var job = try job(id: jobID)
        guard job.status == .running || job.status == .pending else {
            if job.status == .failed { return job }
            throw FinalAnalysisStoreError.invalidJobTransition(
                from: job.status,
                to: .failed
            )
        }
        job.status = .failed
        job.lastErrorCode = Self.sanitizedCode(errorCode)
        job.completedAt = now()
        job.updatedAt = now()
        try replaceJob(job)
        return job
    }

    /// Writes the immutable artifact first, then atomically advances the private
    /// result pointer. Only the current canonical target can become renderable.
    func publish(jobID: String) throws -> FinalAnalysisPublishedResult {
        try requireCurrentTarget(jobID: jobID)
        var job = try job(id: jobID)
        if job.status == .complete, let pointer = job.resultPointer {
            return try loadPublishedResult(pointer: pointer)
        }
        guard job.triggers.allSatisfy({
            $0.state == .complete && $0.result != nil
        }) else {
            throw FinalAnalysisStoreError.incompleteTriggers
        }
        let snapshot = try snapshot(for: jobID)
        return try publish(
            job: &job,
            snapshot: snapshot,
            replaceInvalidArtifact: false
        )
    }

    /// Rebuilds a lost/corrupt published artifact solely from the persisted
    /// completed trigger results. This performs no provider or spend work.
    /// Nil means the durable trigger results are insufficient and an explicit
    /// provider retry is required.
    func repairPublishedTarget(
        canonicalRevision: Int64,
        canonicalTranscriptHash: String
    ) throws -> FinalAnalysisPublishedResult? {
        guard let target = document.target,
              target.canonicalRevision == canonicalRevision,
              target.canonicalTranscriptHash == canonicalTranscriptHash.lowercased(),
              var job = document.jobs.first(where: { $0.id == target.jobID }),
              job.canonicalRevision == canonicalRevision,
              job.canonicalTranscriptHash == canonicalTranscriptHash.lowercased(),
              job.status == .complete else {
            return nil
        }

        if let pointer = document.currentResultPointer,
           pointer.matches(
               canonicalRevision: canonicalRevision,
               canonicalTranscriptHash: canonicalTranscriptHash
           ),
           let published = try? loadPublishedResult(pointer: pointer) {
            return published
        }

        guard job.triggers.allSatisfy({
            $0.state == .complete && $0.result != nil
        }) else {
            return nil
        }
        let snapshot = try snapshot(for: job.id)
        guard snapshot.canonicalRevision == canonicalRevision,
              snapshot.canonicalTranscriptHash == canonicalTranscriptHash.lowercased(),
              snapshot.id == job.snapshotID else {
            throw FinalAnalysisStoreError.snapshotCollision(job.snapshotID)
        }
        return try publish(
            job: &job,
            snapshot: snapshot,
            replaceInvalidArtifact: true
        )
    }

    /// Converts an otherwise terminal completed job into a retryable durable
    /// failure when its persisted trigger results cannot reconstruct an
    /// artifact. Completed trigger results that are still valid are retained.
    func invalidateCompletedTargetForRetry(
        errorCode: String
    ) throws -> FinalAnalysisStoredJob {
        var job = try targetJob()
        guard job.status == .complete else {
            if job.status == .failed { return job }
            throw FinalAnalysisStoreError.invalidJobTransition(
                from: job.status,
                to: .failed
            )
        }
        for index in job.triggers.indices {
            if job.triggers[index].state == .complete,
               job.triggers[index].result == nil {
                job.triggers[index].state = .pending
                job.triggers[index].completedAt = nil
            } else if job.triggers[index].state == .running {
                job.triggers[index].state = .pending
            }
        }
        job.status = .failed
        job.resultPointer = nil
        job.lastErrorCode = Self.sanitizedCode(errorCode)
        job.completedAt = now()
        job.updatedAt = now()

        var updated = document
        guard let index = updated.jobs.firstIndex(where: { $0.id == job.id }) else {
            throw FinalAnalysisStoreError.jobNotFound(job.id)
        }
        updated.jobs[index] = job
        updated.currentResultPointer = nil
        try commit(updated)
        return job
    }

    /// Reader API for metadata/UI integration. A pointer for a different
    /// canonical transcript is intentionally invisible.
    func currentPublishedResult(
        canonicalRevision: Int64,
        canonicalTranscriptHash: String
    ) throws -> FinalAnalysisPublishedResult? {
        guard let pointer = document.currentResultPointer,
              pointer.matches(
                canonicalRevision: canonicalRevision,
                canonicalTranscriptHash: canonicalTranscriptHash
              ) else {
            return nil
        }
        return try loadPublishedResult(pointer: pointer)
    }

    private func loadPublishedResult(
        pointer: FinalAnalysisResultPointer
    ) throws -> FinalAnalysisPublishedResult {
        let url = callFolderURL.appendingPathComponent(pointer.fileName)
        let data = try Data(contentsOf: url)
        let artifact = try Self.decoder.decode(FinalAnalysisArtifact.self, from: data)
        guard
            artifact.callID == callID,
            artifact.canonicalRevision == pointer.canonicalRevision,
            artifact.canonicalTranscriptHash == pointer.canonicalTranscriptHash,
            (try FinalAnalysisStableDigest.hex(artifact)) == pointer.analysisHash
        else {
            throw FinalAnalysisStoreError.corruptPublishedArtifact(pointer.fileName)
        }
        return FinalAnalysisPublishedResult(pointer: pointer, artifact: artifact)
    }

    private func publish(
        job: inout FinalAnalysisStoredJob,
        snapshot: FinalAnalysisSnapshot,
        replaceInvalidArtifact: Bool
    ) throws -> FinalAnalysisPublishedResult {
        let cards = try Self.makeCards(job: job, snapshotID: snapshot.id)
        let artifactMaterial = FinalAnalysisArtifactIdentity(
            callID: callID,
            snapshotID: snapshot.id,
            canonicalRevision: snapshot.canonicalRevision,
            canonicalTranscriptHash: snapshot.canonicalTranscriptHash,
            cards: cards
        )
        let artifact = FinalAnalysisArtifact(
            schemaVersion: 1,
            id: "final-analysis-v1_\(try FinalAnalysisStableDigest.hex(artifactMaterial))",
            callID: callID,
            snapshotID: snapshot.id,
            canonicalRevision: snapshot.canonicalRevision,
            canonicalTranscriptHash: snapshot.canonicalTranscriptHash,
            perspective: .postCallRetrospective,
            cards: cards
        )
        let analysisHash = try FinalAnalysisStableDigest.hex(artifact)
        let fileName = "analysis.\(snapshot.canonicalRevision).\(snapshot.canonicalTranscriptHash).json"
        let pointer = FinalAnalysisResultPointer(
            canonicalRevision: snapshot.canonicalRevision,
            canonicalTranscriptHash: snapshot.canonicalTranscriptHash,
            analysisHash: analysisHash,
            fileName: fileName
        )
        let artifactURL = callFolderURL.appendingPathComponent(fileName)
        let artifactData = try Self.encoder.encode(artifact)
        if fileManager.fileExists(atPath: artifactURL.path) {
            let existingData = try? Data(contentsOf: artifactURL)
            let existing = existingData.flatMap {
                try? Self.decoder.decode(FinalAnalysisArtifact.self, from: $0)
            }
            if existing != artifact {
                guard replaceInvalidArtifact else {
                    throw FinalAnalysisStoreError.artifactCollision(fileName)
                }
                try artifactData.write(to: artifactURL, options: .atomic)
            }
        } else {
            try artifactData.write(to: artifactURL, options: .atomic)
        }

        job.status = .complete
        job.resultPointer = pointer
        job.lastErrorCode = nil
        job.completedAt = now()
        job.updatedAt = now()
        var updated = document
        guard let index = updated.jobs.firstIndex(where: { $0.id == job.id }) else {
            throw FinalAnalysisStoreError.jobNotFound(job.id)
        }
        updated.jobs[index] = job
        updated.currentResultPointer = pointer
        try commit(updated)
        return FinalAnalysisPublishedResult(pointer: pointer, artifact: artifact)
    }

    private func requireCurrentTarget(jobID: String) throws {
        guard document.target?.jobID == jobID else {
            throw FinalAnalysisStoreError.staleJob(jobID)
        }
    }

    private func replaceJob(_ job: FinalAnalysisStoredJob) throws {
        guard let index = document.jobs.firstIndex(where: { $0.id == job.id }) else {
            throw FinalAnalysisStoreError.jobNotFound(job.id)
        }
        var updated = document
        updated.jobs[index] = job
        try commit(updated)
    }

    private func persistSnapshot(_ snapshot: FinalAnalysisSnapshot) throws {
        let url = snapshotURL(for: snapshot.id)
        if fileManager.fileExists(atPath: url.path) {
            let existing = try Self.decoder.decode(
                FinalAnalysisSnapshot.self,
                from: Data(contentsOf: url)
            )
            guard existing == snapshot else {
                throw FinalAnalysisStoreError.snapshotCollision(snapshot.id)
            }
            return
        }
        try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    private func snapshotURL(for snapshotID: String) -> URL {
        snapshotsFolderURL.appendingPathComponent("\(snapshotID).json")
    }

    private func commit(_ updated: FinalAnalysisDocument) throws {
        try Self.persist(updated, to: manifestURL)
        document = updated
    }

    private static func triggerJobID(jobID: String, turnID: String) throws -> String {
        struct Material: Encodable {
            let jobID: String
            let turnID: String
        }
        let digest = try FinalAnalysisStableDigest.hex(
            Material(jobID: jobID, turnID: turnID)
        )
        return "final-trigger-v1_\(digest)"
    }

    private static func makeCards(
        job: FinalAnalysisStoredJob,
        snapshotID: String
    ) throws -> [FinalQuestionAnswerCard] {
        struct CardIdentity: Encodable {
            let snapshotID: String
            let normalizedQuestion: String
            let evidence: [FinalTranscriptEvidence]
        }

        let orderedTriggers = job.triggers.sorted {
            if $0.triggerStartCallNanoseconds != $1.triggerStartCallNanoseconds {
                return $0.triggerStartCallNanoseconds < $1.triggerStartCallNanoseconds
            }
            return $0.id < $1.id
        }
        var seen: Set<String> = []
        var cards: [FinalQuestionAnswerCard] = []
        for trigger in orderedTriggers {
            for draft in trigger.result!.cards {
                let identity = CardIdentity(
                    snapshotID: snapshotID,
                    normalizedQuestion: draft.normalizedQuestion,
                    evidence: draft.evidence
                )
                let id = "final-card-v1_\(try FinalAnalysisStableDigest.hex(identity))"
                guard seen.insert(id).inserted else { continue }
                cards.append(FinalQuestionAnswerCard(
                    id: id,
                    snapshotID: snapshotID,
                    normalizedQuestion: draft.normalizedQuestion,
                    evidence: draft.evidence,
                    answer: draft.answer,
                    advice: draft.advice,
                    usedCanonicalTurnIDs: draft.usedCanonicalTurnIDs,
                    usedContextIDs: draft.usedContextIDs
                ))
            }
        }
        return cards
    }

    private static func sanitizedCode(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 64, scalars.allSatisfy({ scalar in
            (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value)
                || scalar.value == 95
                || scalar.value == 45
        }) else {
            return "provider_failure"
        }
        return value
    }

    private static func persist(_ document: FinalAnalysisDocument, to url: URL) throws {
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

private struct FinalAnalysisTarget: Codable, Equatable {
    let canonicalRevision: Int64
    let canonicalTranscriptHash: String
    let snapshotID: String
    let jobID: String
}

private struct FinalAnalysisDocument: Codable, Equatable {
    let schemaVersion: Int
    let callID: UUID
    var target: FinalAnalysisTarget?
    var currentResultPointer: FinalAnalysisResultPointer?
    var jobs: [FinalAnalysisStoredJob]
}

private struct FinalAnalysisArtifactIdentity: Encodable {
    let callID: UUID
    let snapshotID: String
    let canonicalRevision: Int64
    let canonicalTranscriptHash: String
    let cards: [FinalQuestionAnswerCard]
}
