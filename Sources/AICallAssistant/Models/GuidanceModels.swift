import Foundation

struct FrozenContext: Codable, Equatable, Hashable, Sendable {
    let sourceContextID: UUID
    let title: String
    let body: String
    let sourceVersion: Int?
    let contentSHA256: String
}

struct FrozenContextSnapshot: Codable, Equatable, Sendable {
    let id: String
    let frozenAt: Date
    let contexts: [FrozenContext]

    var canonicallyOrderedContexts: [FrozenContext] {
        contexts.sorted {
            $0.sourceContextID.uuidString < $1.sourceContextID.uuidString
        }
    }
}

enum AnswerStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case brief
    case detailed
}

enum AnswerLanguage: String, Codable, CaseIterable, Equatable, Sendable {
    case automatic
    case russian
    case english
}

enum GuidanceConfigurationDefaults {
    static let responsesModelID = "gpt-5.6-terra"
    static let realtimeTranscriptionModelID = "gpt-live-transcribe"
    static let fileTranscriptionModelID = "gpt-transcribe"
    static let transcriptionLanguages = ["ru", "en"]
    static let briefAnswerMaxWords = 60
    static let detailedAnswerMaxWords = 160
    static let adviceMaxWords = 30
    static let maxOutputTokens = 4_096
}

struct GuidanceConfigurationSnapshot: Codable, Equatable, Sendable {
    let id: String
    let responsesModelID: String
    let realtimeTranscriptionModelID: String
    let fileTranscriptionModelID: String
    let transcriptionLanguages: [String]
    let answerStyle: AnswerStyle
    let answerLanguage: AnswerLanguage
    let briefAnswerMaxWords: Int
    let detailedAnswerMaxWords: Int
    let adviceMaxWords: Int
    let maxOutputTokens: Int
    let initialPerCallSpendLimitUSD: Decimal
    let priceCatalogVersion: String
    let modelCapabilityProfileID: String
    let policyVersion: Int

    var selectedAnswerMaxWords: Int {
        switch answerStyle {
        case .brief:
            return briefAnswerMaxWords
        case .detailed:
            return detailedAnswerMaxWords
        }
    }
}

struct SpendAuthorizationRevision: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let callID: UUID
    let revision: Int
    let authorizedLimitUSD: Decimal
    let priceCatalogVersion: String
    let createdAt: Date
}

struct SnapshotTurn: Codable, Equatable, Hashable, Sendable {
    let reference: TurnReference
    let track: AudioTrack
    let startCallNanoseconds: UInt64
    let endCallNanoseconds: UInt64?
    let text: String

    static func canonicalTimelineOrder(_ lhs: SnapshotTurn, _ rhs: SnapshotTurn) -> Bool {
        if lhs.startCallNanoseconds != rhs.startCallNanoseconds {
            return lhs.startCallNanoseconds < rhs.startCallNanoseconds
        }
        if lhs.track != rhs.track {
            return lhs.track.rawValue < rhs.track.rawValue
        }
        return lhs.reference.turnID.uuidString < rhs.reference.turnID.uuidString
    }
}

enum AnalysisPerspective: String, Codable, CaseIterable, Equatable, Sendable {
    case livePointInTime
    case postCallRetrospective
}

struct ConversationSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let callID: UUID
    let conversationRevision: Int64
    let turns: [SnapshotTurn]
    let triggerTurns: [TurnReference]
    let frozenContexts: FrozenContextSnapshot
    let configuration: GuidanceConfigurationSnapshot
    let perspective: AnalysisPerspective

    var canonicallyOrderedTurns: [SnapshotTurn] {
        turns.sorted(by: SnapshotTurn.canonicalTimelineOrder)
    }
}

struct QuestionEvidence: Codable, Equatable, Sendable {
    let turn: TurnReference
    let exactQuote: String
    let unicodeScalarRange: Range<Int>?
}

struct QuestionAnswerPair: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let snapshotID: String
    let normalizedQuestion: String
    let evidence: [QuestionEvidence]
    let answer: String
    let advice: String
    let usedTurnIDs: [UUID]
    let usedContextIDs: [UUID]
    let isLate: Bool

    static func deterministicID(runID: String, canonicalOrdinal: Int) -> String {
        precondition(canonicalOrdinal >= 0, "Canonical pair ordinal must not be negative")
        return "\(runID):pair:\(canonicalOrdinal)"
    }
}

struct AnalysisRun: Identifiable, Codable, Equatable, Sendable {
    enum Status: String, Codable, CaseIterable, Equatable, Sendable {
        case queued
        case running
        case published
        case superseded
        case failed
    }

    let id: String
    let snapshotID: String
    let trigger: [TurnReference]
    let pairs: [QuestionAnswerPair]
    let status: Status
}
