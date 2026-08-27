import Foundation

enum GuidanceJobState: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case published
    case failed
    case superseded
}

struct GuidanceStoredJob: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let runID: String
    let callID: UUID
    let snapshotID: String
    let trigger: [TurnReference]
    let triggerStartCallNanoseconds: UInt64
    let fifoSequence: Int64
    let createdAt: Date
    var state: GuidanceJobState
    var startedAt: Date?
    var completedAt: Date?
    var failureCode: String?
    var supersededByJobID: String?
    var result: AnalysisRun?
}

enum GuidanceEnqueueResult: Equatable, Sendable {
    case enqueued(GuidanceStoredJob)
    case existing(GuidanceStoredJob)
    case replaced(previousJobID: String, job: GuidanceStoredJob)

    var job: GuidanceStoredJob {
        switch self {
        case let .enqueued(job), let .existing(job), let .replaced(_, job):
            return job
        }
    }
}

enum GuidancePublicationResult: Equatable, Sendable {
    case published(AnalysisRun)
    case alreadyPublished(AnalysisRun)
}

enum GuidanceJobStoreError: Error, Equatable, Sendable {
    case callIDMismatch(expected: UUID, actual: UUID)
    case emptyTrigger
    case missingTriggerTurn(TurnReference)
    case outgoingTriggerTurn(TurnReference)
    case snapshotIDCollision(String)
    case jobNotFound(String)
    case invalidTransition(jobID: String, from: GuidanceJobState, to: GuidanceJobState)
    case replacementRevisionNotNewer(existingJobID: String)
    case replacementNotAllowedAfterStart(existingJobID: String, state: GuidanceJobState)
    case resultDoesNotMatchJob(String)
}

actor GuidanceJobStore {
    nonisolated let callID: UUID
    nonisolated let callFolderURL: URL
    nonisolated let guidanceFolderURL: URL
    nonisolated let snapshotsFolderURL: URL
    nonisolated let manifestURL: URL

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var document: GuidanceJobDocument

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

        let guidanceFolderURL = callFolderURL
            .appendingPathComponent("guidance", isDirectory: true)
        let snapshotsFolderURL = guidanceFolderURL
            .appendingPathComponent("snapshots", isDirectory: true)
        let manifestURL = guidanceFolderURL.appendingPathComponent("guidance-jobs.json")
        self.guidanceFolderURL = guidanceFolderURL
        self.snapshotsFolderURL = snapshotsFolderURL
        self.manifestURL = manifestURL

        try fileManager.createDirectory(
            at: snapshotsFolderURL,
            withIntermediateDirectories: true
        )

        var loaded: GuidanceJobDocument
        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            loaded = try Self.decoder.decode(GuidanceJobDocument.self, from: data)
        } else {
            loaded = GuidanceJobDocument(
                schemaVersion: 1,
                callID: callID,
                nextFIFOSequence: 0,
                jobs: []
            )
        }

        guard loaded.callID == callID else {
            throw GuidanceJobStoreError.callIDMismatch(
                expected: callID,
                actual: loaded.callID
            )
        }

        var recoveredRunningJob = false
        for index in loaded.jobs.indices where loaded.jobs[index].state == .running {
            loaded.jobs[index].state = .queued
            loaded.jobs[index].startedAt = nil
            recoveredRunningJob = true
        }
        document = loaded

        if recoveredRunningJob || !fileManager.fileExists(atPath: manifestURL.path) {
            try Self.persist(loaded, to: manifestURL)
        }
    }

    func enqueue(snapshot: ConversationSnapshot) throws -> GuidanceEnqueueResult {
        guard snapshot.callID == callID else {
            throw GuidanceJobStoreError.callIDMismatch(
                expected: callID,
                actual: snapshot.callID
            )
        }
        guard !snapshot.triggerTurns.isEmpty else {
            throw GuidanceJobStoreError.emptyTrigger
        }

        let turnsByReference = Dictionary(
            uniqueKeysWithValues: snapshot.turns.map { ($0.reference, $0) }
        )
        for trigger in snapshot.triggerTurns {
            guard let turn = turnsByReference[trigger] else {
                throw GuidanceJobStoreError.missingTriggerTurn(trigger)
            }
            guard turn.track == .incoming else {
                throw GuidanceJobStoreError.outgoingTriggerTurn(trigger)
            }
        }

        try persistSnapshot(snapshot)

        let identity = try GuidanceJobIdentity(snapshot: snapshot)
        if let existing = document.jobs.first(where: { $0.id == identity.jobID }) {
            return .existing(existing)
        }

        var updated = document
        let triggerIDs = Set(snapshot.triggerTurns.map(\.turnID))
        let activeSameTriggerIndex = updated.jobs.indices
            .filter { updated.jobs[$0].state != .superseded }
            .filter { Set(updated.jobs[$0].trigger.map(\.turnID)) == triggerIDs }
            .max { lhs, rhs in
                updated.jobs[lhs].createdAt < updated.jobs[rhs].createdAt
            }

        let fifoSequence: Int64
        let triggerStartCallNanoseconds: UInt64
        var replacedJobID: String?
        if let existingIndex = activeSameTriggerIndex {
            let existing = updated.jobs[existingIndex]
            let revisionRelation = Self.compareTriggerRevisions(
                snapshot.triggerTurns,
                existing.trigger
            )
            switch revisionRelation {
            case .same, .olderOrDivergent:
                if revisionRelation == .same {
                    return .existing(existing)
                }
                throw GuidanceJobStoreError.replacementRevisionNotNewer(
                    existingJobID: existing.id
                )
            case .newer:
                guard existing.state == .queued else {
                    throw GuidanceJobStoreError.replacementNotAllowedAfterStart(
                        existingJobID: existing.id,
                        state: existing.state
                    )
                }
                fifoSequence = existing.fifoSequence
                triggerStartCallNanoseconds = existing.triggerStartCallNanoseconds
                replacedJobID = existing.id
                updated.jobs[existingIndex].state = .superseded
                updated.jobs[existingIndex].completedAt = now()
                updated.jobs[existingIndex].supersededByJobID = identity.jobID
            }
        } else {
            fifoSequence = updated.nextFIFOSequence
            triggerStartCallNanoseconds = snapshot.triggerTurns.compactMap {
                turnsByReference[$0]?.startCallNanoseconds
            }.min()!
            updated.nextFIFOSequence += 1
        }

        let job = GuidanceStoredJob(
            id: identity.jobID,
            runID: identity.runID,
            callID: snapshot.callID,
            snapshotID: snapshot.id,
            trigger: snapshot.triggerTurns,
            triggerStartCallNanoseconds: triggerStartCallNanoseconds,
            fifoSequence: fifoSequence,
            createdAt: now(),
            state: .queued,
            startedAt: nil,
            completedAt: nil,
            failureCode: nil,
            supersededByJobID: nil,
            result: nil
        )
        updated.jobs.append(job)
        try commit(updated)

        if let replacedJobID {
            return .replaced(previousJobID: replacedJobID, job: job)
        }
        return .enqueued(job)
    }

    func claimNextQueuedJobs(limit: Int) throws -> [GuidanceStoredJob] {
        guard limit > 0 else { return [] }
        let candidateIDs = document.jobs
            .filter { $0.state == .queued }
            .sorted(by: Self.canonicalFIFOOrder)
            .prefix(limit)
            .map(\.id)
        guard !candidateIDs.isEmpty else { return [] }

        let candidateSet = Set(candidateIDs)
        var updated = document
        let startedAt = now()
        for index in updated.jobs.indices where candidateSet.contains(updated.jobs[index].id) {
            updated.jobs[index].state = .running
            updated.jobs[index].startedAt = startedAt
        }
        try commit(updated)

        let jobsByID = Dictionary(uniqueKeysWithValues: document.jobs.map { ($0.id, $0) })
        return candidateIDs.compactMap { jobsByID[$0] }
    }

    func snapshot(for jobID: String) throws -> ConversationSnapshot {
        guard let job = document.jobs.first(where: { $0.id == jobID }) else {
            throw GuidanceJobStoreError.jobNotFound(jobID)
        }
        let url = snapshotURL(for: job.snapshotID)
        let snapshot = try Self.decoder.decode(
            ConversationSnapshot.self,
            from: Data(contentsOf: url)
        )
        guard snapshot.id == job.snapshotID, snapshot.callID == callID else {
            throw GuidanceJobStoreError.snapshotIDCollision(job.snapshotID)
        }
        return snapshot
    }

    func hasNewerUnrelatedJob(than jobID: String) throws -> Bool {
        guard let job = document.jobs.first(where: { $0.id == jobID }) else {
            throw GuidanceJobStoreError.jobNotFound(jobID)
        }
        let triggerIDs = Set(job.trigger.map(\.turnID))
        return document.jobs.contains { candidate in
            candidate.state != .superseded
                && Set(candidate.trigger.map(\.turnID)) != triggerIDs
                && Self.canonicalFIFOOrder(job, candidate)
        }
    }

    func publish(
        jobID: String,
        run: AnalysisRun
    ) throws -> GuidancePublicationResult {
        guard let index = document.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw GuidanceJobStoreError.jobNotFound(jobID)
        }
        let existing = document.jobs[index]
        if existing.state == .published, let existingRun = existing.result {
            return .alreadyPublished(existingRun)
        }
        guard existing.state == .running else {
            throw GuidanceJobStoreError.invalidTransition(
                jobID: jobID,
                from: existing.state,
                to: .published
            )
        }
        guard
            run.id == existing.runID,
            run.snapshotID == existing.snapshotID,
            run.trigger == existing.trigger,
            run.status == .published
        else {
            throw GuidanceJobStoreError.resultDoesNotMatchJob(jobID)
        }

        var updated = document
        updated.jobs[index].state = .published
        updated.jobs[index].completedAt = now()
        updated.jobs[index].failureCode = nil
        updated.jobs[index].result = run
        try commit(updated)
        return .published(run)
    }

    func markFailed(jobID: String, failureCode: String) throws {
        guard let index = document.jobs.firstIndex(where: { $0.id == jobID }) else {
            throw GuidanceJobStoreError.jobNotFound(jobID)
        }
        let existing = document.jobs[index]
        if existing.state == .failed, existing.failureCode == failureCode {
            return
        }
        guard existing.state == .running else {
            throw GuidanceJobStoreError.invalidTransition(
                jobID: jobID,
                from: existing.state,
                to: .failed
            )
        }

        var updated = document
        updated.jobs[index].state = .failed
        updated.jobs[index].completedAt = now()
        updated.jobs[index].failureCode = failureCode
        try commit(updated)
    }

    func jobs() -> [GuidanceStoredJob] {
        document.jobs.sorted(by: Self.canonicalFIFOOrder)
    }

    func publishedRuns() -> [AnalysisRun] {
        document.jobs
            .filter { $0.state == .published }
            .sorted(by: Self.canonicalFIFOOrder)
            .compactMap(\.result)
    }

    func hasQueuedJobs() -> Bool {
        document.jobs.contains { $0.state == .queued }
    }

    private func persistSnapshot(_ snapshot: ConversationSnapshot) throws {
        let url = snapshotURL(for: snapshot.id)
        let data = try Self.encoder.encode(snapshot)
        if fileManager.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            let decoded = try Self.decoder.decode(ConversationSnapshot.self, from: existing)
            guard decoded == snapshot else {
                throw GuidanceJobStoreError.snapshotIDCollision(snapshot.id)
            }
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private func snapshotURL(for snapshotID: String) -> URL {
        let component = Data(snapshotID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return snapshotsFolderURL.appendingPathComponent("\(component).json")
    }

    private func commit(_ updated: GuidanceJobDocument) throws {
        try Self.persist(updated, to: manifestURL)
        document = updated
    }

    private static func persist(_ document: GuidanceJobDocument, to url: URL) throws {
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private static func canonicalFIFOOrder(
        _ lhs: GuidanceStoredJob,
        _ rhs: GuidanceStoredJob
    ) -> Bool {
        if lhs.triggerStartCallNanoseconds != rhs.triggerStartCallNanoseconds {
            return lhs.triggerStartCallNanoseconds < rhs.triggerStartCallNanoseconds
        }
        if lhs.fifoSequence != rhs.fifoSequence {
            return lhs.fifoSequence < rhs.fifoSequence
        }
        return lhs.id < rhs.id
    }

    private enum RevisionRelation {
        case same
        case newer
        case olderOrDivergent
    }

    private static func compareTriggerRevisions(
        _ candidate: [TurnReference],
        _ existing: [TurnReference]
    ) -> RevisionRelation {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidate.map { ($0.turnID, $0.revision) })
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.turnID, $0.revision) })
        guard Set(candidateByID.keys) == Set(existingByID.keys) else {
            return .olderOrDivergent
        }

        var hasNewerRevision = false
        for (turnID, existingRevision) in existingByID {
            guard let candidateRevision = candidateByID[turnID], candidateRevision >= existingRevision else {
                return .olderOrDivergent
            }
            hasNewerRevision = hasNewerRevision || candidateRevision > existingRevision
        }
        return hasNewerRevision ? .newer : .same
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

private struct GuidanceJobDocument: Codable, Equatable {
    let schemaVersion: Int
    let callID: UUID
    var nextFIFOSequence: Int64
    var jobs: [GuidanceStoredJob]
}

private struct GuidanceJobIdentity {
    struct Material: Encodable {
        struct Trigger: Encodable {
            let turnID: String
            let revision: Int
        }

        let callID: String
        let snapshotID: String
        let triggers: [Trigger]
        let policyVersion: Int
        let perspective: String
    }

    let jobID: String
    let runID: String

    init(snapshot: ConversationSnapshot) throws {
        let triggers = snapshot.triggerTurns
            .sorted {
                if $0.turnID != $1.turnID {
                    return $0.turnID.uuidString < $1.turnID.uuidString
                }
                return $0.revision < $1.revision
            }
            .map {
                Material.Trigger(turnID: $0.turnID.uuidString, revision: $0.revision)
            }
        let material = Material(
            callID: snapshot.callID.uuidString,
            snapshotID: snapshot.id,
            triggers: triggers,
            policyVersion: snapshot.configuration.policyVersion,
            perspective: snapshot.perspective.rawValue
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let component = try encoder.encode(material)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        jobID = "guidance-job-v1_\(component)"
        runID = "guidance-run-v1_\(component)"
    }
}
