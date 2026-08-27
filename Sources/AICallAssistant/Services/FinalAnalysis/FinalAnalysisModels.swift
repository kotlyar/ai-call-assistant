import CryptoKit
import Foundation

/// Canonical post-call turns deliberately use reconciliation IDs rather than
/// live TurnReference values. Live and final cards therefore cannot be mixed by
/// accident and final evidence always points at the published final transcript.
struct FinalAnalysisTurn: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let track: AudioTrack
    let startCallNanoseconds: UInt64
    let endCallNanoseconds: UInt64
    let text: String

    static func canonicalOrder(_ lhs: FinalAnalysisTurn, _ rhs: FinalAnalysisTurn) -> Bool {
        if lhs.startCallNanoseconds != rhs.startCallNanoseconds {
            return lhs.startCallNanoseconds < rhs.startCallNanoseconds
        }
        if lhs.track != rhs.track {
            return Self.trackIndex(lhs.track) < Self.trackIndex(rhs.track)
        }
        return lhs.id < rhs.id
    }

    private static func trackIndex(_ track: AudioTrack) -> Int {
        switch track {
        case .incoming: return 0
        case .outgoing: return 1
        }
    }
}
struct FinalAnalysisSnapshot: Identifiable, Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let callID: UUID
    let canonicalRevision: Int64
    let canonicalTranscriptHash: String
    let turns: [FinalAnalysisTurn]
    let frozenContexts: FrozenContextSnapshot
    let configuration: GuidanceConfigurationSnapshot
    let perspective: AnalysisPerspective

    var canonicallyOrderedTurns: [FinalAnalysisTurn] {
        turns.sorted(by: FinalAnalysisTurn.canonicalOrder)
    }
}

enum FinalAnalysisSnapshotBuilderError: Error, Equatable, Sendable {
    case reconciliationNotComplete(ReconciliationStatus)
    case missingCanonicalResult
    case incompleteTrackCoverage
    case invalidCanonicalRevision
    case invalidCanonicalTranscriptHash
    case duplicateCanonicalTurnID(String)
}

struct FinalAnalysisSnapshotBuilder: Sendable {
    func makeSnapshot(
        reconciliation: ReconciliationStoredJob,
        canonicalRevision: Int64,
        canonicalTranscriptHash: String,
        frozenContexts: FrozenContextSnapshot,
        configuration: GuidanceConfigurationSnapshot
    ) throws -> FinalAnalysisSnapshot {
        guard reconciliation.status == .complete else {
            throw FinalAnalysisSnapshotBuilderError.reconciliationNotComplete(
                reconciliation.status
            )
        }
        guard let canonical = reconciliation.result else {
            throw FinalAnalysisSnapshotBuilderError.missingCanonicalResult
        }
        let coverage = Dictionary(
            uniqueKeysWithValues: canonical.trackCoverage.map { ($0.track, $0) }
        )
        guard AudioTrack.allCases.allSatisfy({ coverage[$0]?.fullyProcessed == true }) else {
            throw FinalAnalysisSnapshotBuilderError.incompleteTrackCoverage
        }
        guard canonicalRevision >= 0 else {
            throw FinalAnalysisSnapshotBuilderError.invalidCanonicalRevision
        }
        guard Self.isSHA256(canonicalTranscriptHash) else {
            throw FinalAnalysisSnapshotBuilderError.invalidCanonicalTranscriptHash
        }

        let turns = canonical.turns.map {
            FinalAnalysisTurn(
                id: $0.id,
                track: $0.track,
                startCallNanoseconds: $0.startCallNanoseconds,
                endCallNanoseconds: $0.endCallNanoseconds,
                text: $0.text
            )
        }.sorted(by: FinalAnalysisTurn.canonicalOrder)
        var seenTurnIDs: Set<String> = []
        for turn in turns where !seenTurnIDs.insert(turn.id).inserted {
            throw FinalAnalysisSnapshotBuilderError.duplicateCanonicalTurnID(turn.id)
        }

        let material = SnapshotIdentityMaterial(
            schemaVersion: 1,
            callID: reconciliation.callID,
            canonicalRevision: canonicalRevision,
            canonicalTranscriptHash: canonicalTranscriptHash.lowercased(),
            turns: turns,
            frozenContexts: FrozenContextSnapshot(
                id: frozenContexts.id,
                frozenAt: frozenContexts.frozenAt,
                contexts: frozenContexts.canonicallyOrderedContexts
            ),
            configuration: configuration,
            perspective: .postCallRetrospective
        )
        let snapshotID = "final-snapshot-v1_\(try FinalAnalysisStableDigest.hex(material))"
        return FinalAnalysisSnapshot(
            schemaVersion: 1,
            id: snapshotID,
            callID: reconciliation.callID,
            canonicalRevision: canonicalRevision,
            canonicalTranscriptHash: canonicalTranscriptHash.lowercased(),
            turns: turns,
            frozenContexts: frozenContexts,
            configuration: configuration,
            perspective: .postCallRetrospective
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.unicodeScalars.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...70).contains($0.value)
                || (97...102).contains($0.value)
        }
    }
}

private struct SnapshotIdentityMaterial: Encodable {
    let schemaVersion: Int
    let callID: UUID
    let canonicalRevision: Int64
    let canonicalTranscriptHash: String
    let turns: [FinalAnalysisTurn]
    let frozenContexts: FrozenContextSnapshot
    let configuration: GuidanceConfigurationSnapshot
    let perspective: AnalysisPerspective
}

struct FinalTranscriptEvidence: Codable, Equatable, Sendable {
    let canonicalTurnID: String
    let exactQuote: String
    /// Nil means the quote is valid but occurs more than once, so UI must not
    /// draw a potentially false highlight.
    let unicodeScalarRange: Range<Int>?
}

/// A post-call card is a separate domain type from live QuestionAnswerPair.
struct FinalQuestionAnswerCard: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let snapshotID: String
    let normalizedQuestion: String
    let evidence: [FinalTranscriptEvidence]
    let answer: String
    let advice: String
    let usedCanonicalTurnIDs: [String]
    let usedContextIDs: [UUID]
}

struct FinalAnalysisArtifact: Identifiable, Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let callID: UUID
    let snapshotID: String
    let canonicalRevision: Int64
    let canonicalTranscriptHash: String
    let perspective: AnalysisPerspective
    let cards: [FinalQuestionAnswerCard]
}

/// This can be copied into recording metadata without embedding the analysis.
struct FinalAnalysisResultPointer: Codable, Equatable, Sendable {
    let canonicalRevision: Int64
    let canonicalTranscriptHash: String
    let analysisHash: String
    let fileName: String

    func matches(canonicalRevision: Int64, canonicalTranscriptHash: String) -> Bool {
        self.canonicalRevision == canonicalRevision
            && self.canonicalTranscriptHash == canonicalTranscriptHash.lowercased()
    }
}

struct FinalAnalysisPublishedResult: Codable, Equatable, Sendable {
    let pointer: FinalAnalysisResultPointer
    let artifact: FinalAnalysisArtifact
}

enum FinalAnalysisStableDigest {
    static func hex<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
