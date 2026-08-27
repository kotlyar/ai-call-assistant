import Foundation

enum AudioTrack: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case incoming
    case outgoing

    fileprivate var canonicalSortIndex: Int {
        switch self {
        case .incoming:
            return 0
        case .outgoing:
            return 1
        }
    }
}

struct TurnReference: Codable, Equatable, Hashable, Sendable {
    let turnID: UUID
    let revision: Int
}

struct TranscriptProviderCorrelation: Codable, Equatable, Hashable, Sendable {
    let track: AudioTrack
    let sessionEpoch: Int
    let providerItemID: String
    let contentIndex: Int
}

struct LiveTranscriptTurn: Identifiable, Codable, Equatable, Sendable {
    enum State: String, Codable, CaseIterable, Equatable, Sendable {
        case partial
        case liveFinal
        case reconciled
        case superseded
        case gap
    }

    let id: UUID
    let track: AudioTrack
    var startCallNanoseconds: UInt64
    var endCallNanoseconds: UInt64?
    var text: String
    var revision: Int
    var state: State
    var sessionEpoch: Int?
    var providerItemID: String?
    var providerContentIndex: Int?

    var reference: TurnReference {
        TurnReference(turnID: id, revision: revision)
    }

    var providerCorrelation: TranscriptProviderCorrelation? {
        guard
            let sessionEpoch,
            let providerItemID,
            let providerContentIndex
        else {
            return nil
        }

        return TranscriptProviderCorrelation(
            track: track,
            sessionEpoch: sessionEpoch,
            providerItemID: providerItemID,
            contentIndex: providerContentIndex
        )
    }

    static func canonicalTimelineOrder(
        _ lhs: LiveTranscriptTurn,
        _ rhs: LiveTranscriptTurn
    ) -> Bool {
        if lhs.startCallNanoseconds != rhs.startCallNanoseconds {
            return lhs.startCallNanoseconds < rhs.startCallNanoseconds
        }
        if lhs.track != rhs.track {
            return lhs.track.canonicalSortIndex < rhs.track.canonicalSortIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
