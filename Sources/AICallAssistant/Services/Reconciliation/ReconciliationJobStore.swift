import CryptoKit
import Foundation

enum ReconciliationChunkState: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case running
    case complete
    case failed
}

struct ReconciledTranscriptSegment: Codable, Equatable, Sendable {
    let chunkID: String
    let track: AudioTrack
    let sourceStartNanoseconds: UInt64
    let sourceEndNanoseconds: UInt64
    let startCallNanoseconds: UInt64
    let endCallNanoseconds: UInt64
    let text: String
    let detectorMiss: Bool
}

struct ReconciliationChunkResult: Codable, Equatable, Sendable {
    let providerResultID: String?
    let resultHash: String
    let segments: [ReconciledTranscriptSegment]
}

struct ReconciliationChunkWork: Identifiable, Codable, Equatable, Sendable {
    var id: String { descriptor.id }

    let descriptor: AudioTrackChunkDescriptor
    var state: ReconciliationChunkState
    var attempts: Int
    var lastErrorCode: String?
    var completedAt: Date?
    var result: ReconciliationChunkResult?
}

struct ReconciliationTrackWork: Codable, Equatable, Sendable {
    let track: AudioTrack
    let asset: ReconciliationAudioAsset?
    let missingReason: String?
    var chunks: [ReconciliationChunkWork]
}

struct ReconciliationTrackCoverage: Codable, Equatable, Sendable {
    let track: AudioTrack
    let sourceDurationNanoseconds: UInt64?
    let fullyProcessed: Bool
    let missingReason: String?
}

struct ReconciledTranscriptTurn: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let track: AudioTrack
    let startCallNanoseconds: UInt64
    let endCallNanoseconds: UInt64
    let text: String
    let detectorMiss: Bool
    let sourceChunkIDs: [String]
}

struct ReconciliationCanonicalResult: Codable, Equatable, Sendable {
    let turns: [ReconciledTranscriptTurn]
    let trackCoverage: [ReconciliationTrackCoverage]
}

struct ReconciliationStoredJob: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let callID: UUID
    let modelID: String
    var languages: [String]? = nil
    let chunkerVersion: Int
    let createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var status: ReconciliationStatus
    var attempts: Int
    /// Absent in v1 manifests. Generation zero preserves the original
    /// reservation identity; every explicit retry advances the generation so
    /// billable attempts cannot reuse reservations from an earlier retry window.
    var retryGeneration: Int? = nil
    var lastErrorCode: String?
    var tracks: [ReconciliationTrackWork]
    var result: ReconciliationCanonicalResult?
}

struct ReconciliationTrackSeed: Codable, Equatable, Sendable {
    let track: AudioTrack
    let asset: ReconciliationAudioAsset?
    let missingReason: String?
    let chunks: [AudioTrackChunkDescriptor]

    init(
        track: AudioTrack,
        asset: ReconciliationAudioAsset?,
        missingReason: String? = nil,
        chunks: [AudioTrackChunkDescriptor] = []
    ) {
        self.track = track
        self.asset = asset
        self.missingReason = missingReason
        self.chunks = chunks
    }
}

struct ReconciliationJobSeed: Codable, Equatable, Sendable {
    let callID: UUID
    let modelID: String
    let languages: [String]
    let chunkerVersion: Int
    let tracks: [ReconciliationTrackSeed]

    init(
        callID: UUID,
        modelID: String,
        languages: [String] = [],
        chunkerVersion: Int,
        tracks: [ReconciliationTrackSeed]
    ) {
        self.callID = callID
        self.modelID = modelID
        self.languages = languages
        self.chunkerVersion = chunkerVersion
        self.tracks = tracks
    }
}

struct ClaimedReconciliationChunk: Equatable, Sendable {
    let jobID: String
    let callID: UUID
    let modelID: String
    let languages: [String]
    let asset: ReconciliationAudioAsset
    let descriptor: AudioTrackChunkDescriptor
    let nextAttempt: Int
    let retryGeneration: Int
}

enum ReconciliationChunkCompletion: Equatable, Sendable {
    case completed
    case alreadyCompleted
}

enum ReconciliationJobStoreError: Error, Equatable, Sendable {
    case callIDMismatch(expected: UUID, actual: UUID)
    case jobAlreadyExists(existingID: String, candidateID: String)
    case duplicateTrack(AudioTrack)
    case invalidTrackPlan(AudioTrack)
    case noJob
    case jobIDMismatch
    case chunkNotFound(String)
    case invalidChunkTransition(
        chunkID: String,
        from: ReconciliationChunkState,
        to: ReconciliationChunkState
    )
    case invalidJobTransition(from: ReconciliationStatus, to: ReconciliationStatus)
    case conflictingChunkResult(String)
    case invalidTerminalResult
}

actor ReconciliationJobStore {
    nonisolated let callID: UUID
    nonisolated let callFolderURL: URL
    nonisolated let reconciliationFolderURL: URL
    nonisolated let manifestURL: URL

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var document: ReconciliationJobDocument

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

        let reconciliationFolderURL = callFolderURL
            .appendingPathComponent("reconciliation", isDirectory: true)
        let manifestURL = reconciliationFolderURL
            .appendingPathComponent("reconciliation-job.json")
        self.reconciliationFolderURL = reconciliationFolderURL
        self.manifestURL = manifestURL

        try fileManager.createDirectory(
            at: reconciliationFolderURL,
            withIntermediateDirectories: true
        )

        var loaded: ReconciliationJobDocument
        if fileManager.fileExists(atPath: manifestURL.path) {
            loaded = try Self.decoder.decode(
                ReconciliationJobDocument.self,
                from: Data(contentsOf: manifestURL)
            )
        } else {
            loaded = ReconciliationJobDocument(
                schemaVersion: 1,
                callID: callID,
                job: nil
            )
        }
        guard loaded.callID == callID else {
            throw ReconciliationJobStoreError.callIDMismatch(
                expected: callID,
                actual: loaded.callID
            )
        }

        var recovered = false
        if var job = loaded.job {
            for trackIndex in job.tracks.indices {
                for chunkIndex in job.tracks[trackIndex].chunks.indices
                where job.tracks[trackIndex].chunks[chunkIndex].state == .running {
                    job.tracks[trackIndex].chunks[chunkIndex].state = .pending
                    recovered = true
                }
            }
            if job.status == .running {
                job.status = .pending
                job.updatedAt = now()
                recovered = true
            }
            loaded.job = job
        }
        document = loaded

        if recovered || !fileManager.fileExists(atPath: manifestURL.path) {
            try Self.persist(loaded, to: manifestURL)
        }
    }

    /// Creates the one reconciliation job for a call, or returns the exact same
    /// deterministic job. A different seed cannot silently replace it.
    func createIfNeeded(seed: ReconciliationJobSeed) throws -> ReconciliationStoredJob {
        guard seed.callID == callID else {
            throw ReconciliationJobStoreError.callIDMismatch(
                expected: callID,
                actual: seed.callID
            )
        }
        try Self.validate(seed: seed)
        let candidateID = try ReconciliationJobIdentity(seed: seed).id
        if let existing = document.job {
            guard existing.id == candidateID else {
                throw ReconciliationJobStoreError.jobAlreadyExists(
                    existingID: existing.id,
                    candidateID: candidateID
                )
            }
            return existing
        }

        let timestamp = now()
        let tracks = seed.tracks
            .sorted { Self.trackIndex($0.track) < Self.trackIndex($1.track) }
            .map { track in
                ReconciliationTrackWork(
                    track: track.track,
                    asset: track.asset,
                    missingReason: track.asset == nil
                        ? Self.sanitizedCode(track.missingReason ?? "missing_track")
                        : nil,
                    chunks: track.chunks
                        .sorted(by: Self.chunkDescriptorOrder)
                        .map {
                            ReconciliationChunkWork(
                                descriptor: $0,
                                state: .pending,
                                attempts: 0,
                                lastErrorCode: nil,
                                completedAt: nil,
                                result: nil
                            )
                        }
                )
            }
        let job = ReconciliationStoredJob(
            id: candidateID,
            callID: callID,
            modelID: seed.modelID,
            languages: seed.languages,
            chunkerVersion: seed.chunkerVersion,
            createdAt: timestamp,
            updatedAt: timestamp,
            startedAt: nil,
            completedAt: nil,
            status: .pending,
            attempts: 0,
            retryGeneration: 0,
            lastErrorCode: nil,
            tracks: tracks,
            result: nil
        )
        var updated = document
        updated.job = job
        try commit(updated)
        return job
    }

    func currentJob() -> ReconciliationStoredJob? {
        document.job
    }

    /// Explicitly re-opens a policy/credential-blocked job so the coordinator can
    /// re-check the current key and current spend authorization.
    func resumeBlockedJob() throws {
        guard var job = document.job else {
            throw ReconciliationJobStoreError.noJob
        }
        switch job.status {
        case .blockedByCredential, .blockedBySpendLimit:
            job.status = .pending
            job.completedAt = nil
            job.updatedAt = now()
            var updated = document
            updated.job = job
            try commit(updated)
        default:
            return
        }
    }

    /// An explicit user retry opens a terminal failed job for another bounded
    /// attempt window. Completed chunks remain immutable and are never uploaded
    /// again; only failed chunks are returned to pending.
    func retryFailedJob() throws {
        guard var job = document.job else {
            throw ReconciliationJobStoreError.noJob
        }
        guard job.status == .failed else { return }
        job.retryGeneration = max(0, job.retryGeneration ?? 0) + 1
        for trackIndex in job.tracks.indices {
            for chunkIndex in job.tracks[trackIndex].chunks.indices
            where job.tracks[trackIndex].chunks[chunkIndex].state == .failed {
                job.tracks[trackIndex].chunks[chunkIndex].state = .pending
                job.tracks[trackIndex].chunks[chunkIndex].attempts = 0
                job.tracks[trackIndex].chunks[chunkIndex].lastErrorCode = nil
            }
        }
        job.status = .pending
        job.completedAt = nil
        job.lastErrorCode = nil
        job.result = nil
        job.updatedAt = now()
        try commitJob(job)
    }

    /// Claims work without consuming a provider attempt. Credential and spend
    /// checks happen after this CAS and before `beginAttempt`.
    func claimNextChunk(maximumAttempts: Int) throws -> ClaimedReconciliationChunk? {
        guard maximumAttempts > 0 else { return nil }
        guard var job = document.job else {
            throw ReconciliationJobStoreError.noJob
        }
        guard !Self.isTerminal(job.status) else { return nil }
        guard job.status != .blockedByCredential, job.status != .blockedBySpendLimit else {
            return nil
        }

        var candidates: [(track: Int, chunk: Int)] = []
        for trackIndex in job.tracks.indices where job.tracks[trackIndex].asset != nil {
            for chunkIndex in job.tracks[trackIndex].chunks.indices {
                let chunk = job.tracks[trackIndex].chunks[chunkIndex]
                if chunk.state == .pending
                    || (chunk.state == .failed && chunk.attempts < maximumAttempts) {
                    candidates.append((trackIndex, chunkIndex))
                }
            }
        }
        candidates.sort {
            let lhsTrack = job.tracks[$0.track]
            let rhsTrack = job.tracks[$1.track]
            if lhsTrack.track != rhsTrack.track {
                return Self.trackIndex(lhsTrack.track) < Self.trackIndex(rhsTrack.track)
            }
            let lhs = lhsTrack.chunks[$0.chunk].descriptor
            let rhs = rhsTrack.chunks[$1.chunk].descriptor
            return Self.chunkDescriptorOrder(lhs, rhs)
        }
        guard let selected = candidates.first,
              let asset = job.tracks[selected.track].asset else {
            return nil
        }

        var chunk = job.tracks[selected.track].chunks[selected.chunk]
        chunk.state = .running
        job.tracks[selected.track].chunks[selected.chunk] = chunk
        job.status = .running
        job.startedAt = job.startedAt ?? now()
        job.completedAt = nil
        job.updatedAt = now()

        var updated = document
        updated.job = job
        try commit(updated)
        return ClaimedReconciliationChunk(
            jobID: job.id,
            callID: job.callID,
            modelID: job.modelID,
            languages: job.languages ?? [],
            asset: asset,
            descriptor: chunk.descriptor,
            nextAttempt: chunk.attempts + 1,
            retryGeneration: max(0, job.retryGeneration ?? 0)
        )
    }

    func beginAttempt(jobID: String, chunkID: String) throws -> Int {
        var location = try chunkLocation(jobID: jobID, chunkID: chunkID)
        var job = location.job
        let chunk = job.tracks[location.trackIndex].chunks[location.chunkIndex]
        guard chunk.state == .running else {
            throw ReconciliationJobStoreError.invalidChunkTransition(
                chunkID: chunkID,
                from: chunk.state,
                to: .running
            )
        }
        job.tracks[location.trackIndex].chunks[location.chunkIndex].attempts += 1
        job.attempts += 1
        job.updatedAt = now()
        location.job = job
        try commitJob(location.job)
        return job.tracks[location.trackIndex].chunks[location.chunkIndex].attempts
    }

    func blockClaimedChunk(
        jobID: String,
        chunkID: String,
        status: ReconciliationStatus,
        errorCode: String
    ) throws {
        guard status == .blockedByCredential || status == .blockedBySpendLimit else {
            throw ReconciliationJobStoreError.invalidJobTransition(
                from: document.job?.status ?? .pending,
                to: status
            )
        }
        let location = try chunkLocation(jobID: jobID, chunkID: chunkID)
        var job = location.job
        let chunk = job.tracks[location.trackIndex].chunks[location.chunkIndex]
        guard chunk.state == .running else {
            throw ReconciliationJobStoreError.invalidChunkTransition(
                chunkID: chunkID,
                from: chunk.state,
                to: .pending
            )
        }
        job.tracks[location.trackIndex].chunks[location.chunkIndex].state = .pending
        job.status = status
        job.lastErrorCode = Self.sanitizedCode(errorCode)
        job.updatedAt = now()
        try commitJob(job)
    }

    func markChunkComplete(
        jobID: String,
        chunkID: String,
        result: ReconciliationChunkResult
    ) throws -> ReconciliationChunkCompletion {
        let location = try chunkLocation(jobID: jobID, chunkID: chunkID)
        var job = location.job
        let existing = job.tracks[location.trackIndex].chunks[location.chunkIndex]
        if existing.state == .complete {
            guard existing.result == result else {
                throw ReconciliationJobStoreError.conflictingChunkResult(chunkID)
            }
            return .alreadyCompleted
        }
        guard existing.state == .running else {
            throw ReconciliationJobStoreError.invalidChunkTransition(
                chunkID: chunkID,
                from: existing.state,
                to: .complete
            )
        }

        job.tracks[location.trackIndex].chunks[location.chunkIndex].state = .complete
        job.tracks[location.trackIndex].chunks[location.chunkIndex].lastErrorCode = nil
        job.tracks[location.trackIndex].chunks[location.chunkIndex].completedAt = now()
        job.tracks[location.trackIndex].chunks[location.chunkIndex].result = result
        job.lastErrorCode = nil
        job.updatedAt = now()
        try commitJob(job)
        return .completed
    }

    func markChunkFailed(
        jobID: String,
        chunkID: String,
        errorCode: String
    ) throws {
        let location = try chunkLocation(jobID: jobID, chunkID: chunkID)
        var job = location.job
        let existing = job.tracks[location.trackIndex].chunks[location.chunkIndex]
        guard existing.state == .running else {
            throw ReconciliationJobStoreError.invalidChunkTransition(
                chunkID: chunkID,
                from: existing.state,
                to: .failed
            )
        }
        let code = Self.sanitizedCode(errorCode)
        job.tracks[location.trackIndex].chunks[location.chunkIndex].state = .failed
        job.tracks[location.trackIndex].chunks[location.chunkIndex].lastErrorCode = code
        job.lastErrorCode = code
        job.updatedAt = now()
        try commitJob(job)
    }

    func finalize(
        jobID: String,
        status: ReconciliationStatus,
        result: ReconciliationCanonicalResult,
        errorCode: String? = nil
    ) throws -> ReconciliationStoredJob {
        guard var job = document.job else {
            throw ReconciliationJobStoreError.noJob
        }
        guard job.id == jobID else {
            throw ReconciliationJobStoreError.jobIDMismatch
        }
        guard [.complete, .incomplete, .failed].contains(status) else {
            throw ReconciliationJobStoreError.invalidJobTransition(
                from: job.status,
                to: status
            )
        }
        if Self.isTerminal(job.status) {
            guard job.status == status, job.result == result else {
                throw ReconciliationJobStoreError.invalidTerminalResult
            }
            return job
        }

        let hasFailedChunk = job.tracks
            .flatMap(\.chunks)
            .contains { $0.state == .failed }
        let presentTracksAreComplete = job.tracks
            .filter { $0.asset != nil }
            .allSatisfy { track in
                track.chunks.allSatisfy { $0.state == .complete }
                    && AudioTrackChunker.hasContinuousCoverage(
                        track.chunks.map(\.descriptor),
                        sourceDurationNanoseconds: track.asset!.sourceDurationNanoseconds
                    )
            }
        let hasBothTracks = Set(job.tracks.compactMap { track in
            track.asset == nil ? nil : track.track
        }) == Set(AudioTrack.allCases)

        switch status {
        case .complete:
            guard hasBothTracks, presentTracksAreComplete, !hasFailedChunk else {
                throw ReconciliationJobStoreError.invalidTerminalResult
            }
        case .incomplete:
            guard !hasBothTracks, presentTracksAreComplete, !hasFailedChunk else {
                throw ReconciliationJobStoreError.invalidTerminalResult
            }
        case .failed:
            guard hasFailedChunk || !presentTracksAreComplete else {
                throw ReconciliationJobStoreError.invalidTerminalResult
            }
        default:
            break
        }

        job.status = status
        job.result = result
        job.lastErrorCode = errorCode.map(Self.sanitizedCode)
        job.completedAt = now()
        job.updatedAt = now()
        try commitJob(job)
        return job
    }

    private func chunkLocation(
        jobID: String,
        chunkID: String
    ) throws -> (
        job: ReconciliationStoredJob,
        trackIndex: Int,
        chunkIndex: Int
    ) {
        guard let job = document.job else {
            throw ReconciliationJobStoreError.noJob
        }
        guard job.id == jobID else {
            throw ReconciliationJobStoreError.jobIDMismatch
        }
        for trackIndex in job.tracks.indices {
            if let chunkIndex = job.tracks[trackIndex].chunks.firstIndex(
                where: { $0.id == chunkID }
            ) {
                return (job, trackIndex, chunkIndex)
            }
        }
        throw ReconciliationJobStoreError.chunkNotFound(chunkID)
    }

    private func commitJob(_ job: ReconciliationStoredJob) throws {
        var updated = document
        updated.job = job
        try commit(updated)
    }

    private func commit(_ updated: ReconciliationJobDocument) throws {
        try Self.persist(updated, to: manifestURL)
        document = updated
    }

    private static func validate(seed: ReconciliationJobSeed) throws {
        var seen: Set<AudioTrack> = []
        for track in seed.tracks {
            guard seen.insert(track.track).inserted else {
                throw ReconciliationJobStoreError.duplicateTrack(track.track)
            }
            if let asset = track.asset {
                guard
                    asset.track == track.track,
                    track.missingReason == nil,
                    track.chunks.allSatisfy({ $0.track == track.track }),
                    AudioTrackChunker.hasContinuousCoverage(
                        track.chunks,
                        sourceDurationNanoseconds: asset.sourceDurationNanoseconds
                    )
                else {
                    throw ReconciliationJobStoreError.invalidTrackPlan(track.track)
                }
            } else if !track.chunks.isEmpty {
                throw ReconciliationJobStoreError.invalidTrackPlan(track.track)
            }
        }
        guard seen == Set(AudioTrack.allCases) else {
            let missing = AudioTrack.allCases.first { !seen.contains($0) }!
            throw ReconciliationJobStoreError.invalidTrackPlan(missing)
        }
    }

    private static func isTerminal(_ status: ReconciliationStatus) -> Bool {
        status == .complete || status == .incomplete || status == .failed
    }

    private static func trackIndex(_ track: AudioTrack) -> Int {
        switch track {
        case .incoming: return 0
        case .outgoing: return 1
        }
    }

    private static func chunkDescriptorOrder(
        _ lhs: AudioTrackChunkDescriptor,
        _ rhs: AudioTrackChunkDescriptor
    ) -> Bool {
        if lhs.coverageRange.startNanoseconds != rhs.coverageRange.startNanoseconds {
            return lhs.coverageRange.startNanoseconds < rhs.coverageRange.startNanoseconds
        }
        return lhs.id < rhs.id
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

    private static func persist(
        _ document: ReconciliationJobDocument,
        to url: URL
    ) throws {
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

private struct ReconciliationJobDocument: Codable, Equatable {
    let schemaVersion: Int
    let callID: UUID
    var job: ReconciliationStoredJob?
}

private struct ReconciliationJobIdentity {
    private struct Material: Encodable {
        struct Track: Encodable {
            let track: String
            let audioSHA256: String?
            let sourceDurationNanoseconds: UInt64?
            let sourceByteCount: Int64?
            let callStartOffsetNanoseconds: UInt64?
            let missingReason: String?
            let chunkIDs: [String]
        }

        let callID: String
        let modelID: String
        let languages: [String]
        let chunkerVersion: Int
        let tracks: [Track]
    }

    let id: String

    init(seed: ReconciliationJobSeed) throws {
        let tracks = seed.tracks
            .sorted { lhs, rhs in lhs.track.rawValue < rhs.track.rawValue }
            .map { track in
                Material.Track(
                    track: track.track.rawValue,
                    audioSHA256: track.asset?.sourceSHA256,
                    sourceDurationNanoseconds: track.asset?.sourceDurationNanoseconds,
                    sourceByteCount: track.asset?.sourceByteCount,
                    callStartOffsetNanoseconds: track.asset?.callStartOffsetNanoseconds,
                    missingReason: track.asset == nil
                        ? track.missingReason ?? "missing_track"
                        : nil,
                    chunkIDs: track.chunks.map(\.id).sorted()
                )
            }
        let material = Material(
            callID: seed.callID.uuidString,
            modelID: seed.modelID,
            languages: seed.languages.sorted(),
            chunkerVersion: seed.chunkerVersion,
            tracks: tracks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        id = "reconciliation-job-v1_\(try ReconciliationStableDigest.hex(material))"
    }
}

enum ReconciliationStableDigest {
    static func hex<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
