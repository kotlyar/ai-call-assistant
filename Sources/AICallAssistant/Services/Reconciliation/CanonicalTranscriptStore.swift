import CryptoKit
import Foundation

struct CanonicalTranscriptDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let callID: UUID
    let canonicalRevision: Int64
    let providerModelID: String
    let result: ReconciliationCanonicalResult
}

struct CanonicalTranscriptCommit: Equatable, Sendable {
    let document: CanonicalTranscriptDocument
    let filename: String
    let sha256: String
    let turns: [TranscriptTurn]
}

enum CanonicalTranscriptStoreError: Error, Equatable, Sendable {
    case callIDMismatch
    case conflictingArtifact
    case digestMismatch
}

struct CanonicalTranscriptStore: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Writes the immutable canonical artifact before metadata points at it.
    /// Repeating the same commit is byte-for-byte idempotent.
    func commit(
        result: ReconciliationCanonicalResult,
        for recording: Recording,
        callFolderURL: URL,
        providerModelID: String
    ) throws -> CanonicalTranscriptCommit {
        let current = recording.transcription
        let revision: Int64
        if let existing = current?.canonicalRevision,
           current?.canonicalTranscriptFilename != nil {
            revision = existing
        } else {
            revision = max(current?.liveRevision ?? 0, current?.canonicalRevision ?? 0) + 1
        }
        let document = CanonicalTranscriptDocument(
            schemaVersion: 1,
            callID: recording.id,
            canonicalRevision: revision,
            providerModelID: providerModelID,
            result: result
        )
        let data = try Self.encoder.encode(document)
        let sha256 = Self.sha256(data)
        let filename = "transcript.canonical.\(sha256).json"
        let url = callFolderURL.appendingPathComponent(filename, isDirectory: false)

        if fileManager.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == data else {
                throw CanonicalTranscriptStoreError.conflictingArtifact
            }
        } else {
            try data.write(to: url, options: .atomic)
        }

        return CanonicalTranscriptCommit(
            document: document,
            filename: filename,
            sha256: sha256,
            turns: Self.transcriptTurns(from: result)
        )
    }

    func load(
        filename: String,
        expectedSHA256: String,
        callID: UUID,
        callFolderURL: URL
    ) throws -> CanonicalTranscriptDocument {
        let url = callFolderURL.appendingPathComponent(filename, isDirectory: false)
        let data = try Data(contentsOf: url)
        guard Self.sha256(data) == expectedSHA256 else {
            throw CanonicalTranscriptStoreError.digestMismatch
        }
        let document = try JSONDecoder().decode(CanonicalTranscriptDocument.self, from: data)
        guard document.callID == callID else {
            throw CanonicalTranscriptStoreError.callIDMismatch
        }
        return document
    }

    static func transcriptTurns(from result: ReconciliationCanonicalResult) -> [TranscriptTurn] {
        result.turns.map(makeTranscriptTurn)
    }

    private static func makeTranscriptTurn(_ turn: ReconciledTranscriptTurn) -> TranscriptTurn {
        TranscriptTurn(
            id: stableUUID(turn.id),
            speaker: turn.track == .incoming ? .participant : .you,
            timestamp: TimeInterval(turn.startCallNanoseconds) / 1_000_000_000,
            text: turn.text
        )
    }

    static func stableUUID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
