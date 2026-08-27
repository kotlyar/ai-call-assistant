import Foundation

enum PersistedCallState: String, Codable, CaseIterable, Equatable, Sendable {
    case draft
    case capturing
    case interrupted
    case saved
}

enum LiveTranscriptionStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case notStarted
    case running
    case complete
    case incomplete
    case failed
    case budgetStopped
}

enum ReconciliationStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case pending
    case running
    case blockedByCredential
    case blockedBySpendLimit
    case complete
    case incomplete
    case failed
}

enum FinalAnalysisStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case waitingForReconciliation
    case pending
    case running
    case blockedByCredential
    case blockedBySpendLimit
    case contextLimitExceeded
    case complete
    case failed
}

enum RealtimeTrackStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case connecting
    case live
    case reconnecting
    case degraded
    case failed
    case budgetStopped
}

/// Persistable Realtime failure data is deliberately limited to stable,
/// sanitized classifications. Provider messages may contain request details
/// and must not cross this boundary into recording metadata.
struct RealtimeFailureDiagnostic: Codable, Equatable, Sendable {
    let code: String
    let reason: RealtimeConnectionFailure.Reason
    let httpStatus: Int?
}

enum LiveGuidanceStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case inactive
    case active
    case contextLimitReached
    case budgetStopped
    case failed
}
