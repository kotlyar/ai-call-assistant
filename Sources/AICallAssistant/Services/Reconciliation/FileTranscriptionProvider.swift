import Foundation

/// An immutable description of one complete source recording. The URL points to
/// the original M4A (or another file-backed asset); providers are responsible for
/// exporting only `request.chunk.uploadRange` before uploading it.
struct ReconciliationAudioAsset: Codable, Equatable, Sendable {
    let track: AudioTrack
    let fileURL: URL
    let sourceDurationNanoseconds: UInt64
    let sourceByteCount: Int64
    let sourceSHA256: String
    let callStartOffsetNanoseconds: UInt64

    init(
        track: AudioTrack,
        fileURL: URL,
        sourceDurationNanoseconds: UInt64,
        sourceByteCount: Int64,
        sourceSHA256: String,
        callStartOffsetNanoseconds: UInt64
    ) {
        precondition(sourceByteCount >= 0, "Audio byte count cannot be negative")
        self.track = track
        self.fileURL = fileURL
        self.sourceDurationNanoseconds = sourceDurationNanoseconds
        self.sourceByteCount = sourceByteCount
        self.sourceSHA256 = sourceSHA256
        self.callStartOffsetNanoseconds = callStartOffsetNanoseconds
    }
}

/// A provider segment is relative to the beginning of the uploaded chunk, not
/// to the call. The coordinator restores both the source and call clocks.
struct FileTranscriptionSegment: Codable, Equatable, Sendable {
    let startOffsetNanoseconds: UInt64
    let endOffsetNanoseconds: UInt64
    let text: String
}

struct FileTranscriptionResult: Codable, Equatable, Sendable {
    let providerResultID: String?
    let segments: [FileTranscriptionSegment]

    init(
        providerResultID: String? = nil,
        segments: [FileTranscriptionSegment]
    ) {
        self.providerResultID = providerResultID
        self.segments = segments
    }
}

/// This value deliberately is not Codable: the current credential is ephemeral
/// and must never enter the durable reconciliation manifest.
struct FileTranscriptionRequest: Sendable {
    let callID: UUID
    let jobID: String
    /// Stable across process restarts and retries of this exact source range.
    let idempotencyKey: String
    let modelID: String
    let languages: [String]
    let asset: ReconciliationAudioAsset
    let chunk: AudioTrackChunkDescriptor
    let attempt: Int
    let apiKey: String

    init(
        callID: UUID,
        jobID: String,
        idempotencyKey: String,
        modelID: String,
        languages: [String] = [],
        asset: ReconciliationAudioAsset,
        chunk: AudioTrackChunkDescriptor,
        attempt: Int,
        apiKey: String
    ) {
        self.callID = callID
        self.jobID = jobID
        self.idempotencyKey = idempotencyKey
        self.modelID = modelID
        self.languages = languages
        self.asset = asset
        self.chunk = chunk
        self.attempt = attempt
        self.apiKey = apiKey
    }
}

protocol FileTranscriptionProvider: Sendable {
    func transcribe(
        request: FileTranscriptionRequest
    ) async throws -> FileTranscriptionResult
}

/// Provider implementations can opt into stable, sanitized retry semantics.
/// Arbitrary errors are treated as retryable `provider_failure` errors.
protocol FileTranscriptionFailure: Error {
    var reconciliationFailureCode: String { get }
    var isRetryableForReconciliation: Bool { get }
    var reconciliationBlockingReason: FileTranscriptionBlockingReason? { get }
}

enum FileTranscriptionBlockingReason: String, Equatable, Sendable {
    case credential
}

extension FileTranscriptionFailure {
    var reconciliationBlockingReason: FileTranscriptionBlockingReason? { nil }
}
