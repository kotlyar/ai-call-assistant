import Foundation

struct PendingLocalTranscriptTurn: Equatable, Sendable {
    let id: UUID
    let track: AudioTrack
    let sessionEpoch: Int
    let startCallNanoseconds: UInt64
    let endCallNanoseconds: UInt64
}

struct TranscriptReducerCompletion: Equatable, Sendable {
    /// The current state of the provider item that completed.
    let turn: LiveTranscriptTurn
    /// Every changed turn, ordered so cross-track tombstones are observed
    /// before a newly final incoming turn can trigger guidance.
    let updates: [LiveTranscriptTurn]
}

enum TranscriptReducerError: Error, Equatable {
    case noPendingCommit(track: AudioTrack, sessionEpoch: Int)
    case unknownProviderItem(TranscriptProviderCorrelation)
}

struct TranscriptReducer: Sendable {
    private struct SessionKey: Hashable, Sendable {
        let track: AudioTrack
        let epoch: Int
    }

    private var pendingCommits: [SessionKey: [PendingLocalTranscriptTurn]] = [:]
    private var correlationToTurnID: [TranscriptProviderCorrelation: UUID] = [:]
    private var turnsByID: [UUID: LiveTranscriptTurn] = [:]
    private var echoSupersededOutgoingTurnIDs = Set<UUID>()
    private let echoSuppressionPolicy: CrossTrackEchoSuppressionPolicy
    private(set) var conversationRevision: Int64 = 0

    init(
        echoSuppressionPolicy: CrossTrackEchoSuppressionPolicy = .init()
    ) {
        self.echoSuppressionPolicy = echoSuppressionPolicy
    }

    var turns: [LiveTranscriptTurn] {
        turnsByID.values.sorted(by: LiveTranscriptTurn.canonicalTimelineOrder)
    }

    mutating func enqueueCommittedLocalTurn(_ pending: PendingLocalTranscriptTurn) {
        let key = SessionKey(track: pending.track, epoch: pending.sessionEpoch)
        pendingCommits[key, default: []].append(pending)
    }

    /// The server returns a new item_id and does not echo the local commit id.
    /// Binding is therefore deliberately FIFO and scoped to one track/epoch.
    mutating func bindNextCommittedItem(
        track: AudioTrack,
        sessionEpoch: Int,
        providerItemID: String,
        contentIndex: Int = 0
    ) throws -> LiveTranscriptTurn {
        let key = SessionKey(track: track, epoch: sessionEpoch)
        guard var queue = pendingCommits[key], !queue.isEmpty else {
            throw TranscriptReducerError.noPendingCommit(
                track: track,
                sessionEpoch: sessionEpoch
            )
        }
        let pending = queue.removeFirst()
        pendingCommits[key] = queue
        let correlation = TranscriptProviderCorrelation(
            track: track,
            sessionEpoch: sessionEpoch,
            providerItemID: providerItemID,
            contentIndex: contentIndex
        )
        correlationToTurnID[correlation] = pending.id

        let turn = LiveTranscriptTurn(
            id: pending.id,
            track: pending.track,
            startCallNanoseconds: pending.startCallNanoseconds,
            endCallNanoseconds: pending.endCallNanoseconds,
            text: "",
            revision: 0,
            state: .partial,
            sessionEpoch: sessionEpoch,
            providerItemID: providerItemID,
            providerContentIndex: contentIndex
        )
        turnsByID[pending.id] = turn
        return turn
    }

    mutating func applyDelta(
        track: AudioTrack,
        sessionEpoch: Int,
        providerItemID: String,
        contentIndex: Int,
        delta: String
    ) throws -> LiveTranscriptTurn {
        let correlation = TranscriptProviderCorrelation(
            track: track,
            sessionEpoch: sessionEpoch,
            providerItemID: providerItemID,
            contentIndex: contentIndex
        )
        guard let turnID = correlationToTurnID[correlation],
              var turn = turnsByID[turnID] else {
            throw TranscriptReducerError.unknownProviderItem(correlation)
        }
        guard turn.state == .partial else { return turn }
        turn.text += delta
        turnsByID[turnID] = turn
        return turn
    }

    mutating func applyCompleted(
        track: AudioTrack,
        sessionEpoch: Int,
        providerItemID: String,
        contentIndex: Int,
        transcript: String
    ) throws -> TranscriptReducerCompletion {
        let correlation = TranscriptProviderCorrelation(
            track: track,
            sessionEpoch: sessionEpoch,
            providerItemID: providerItemID,
            contentIndex: contentIndex
        )
        guard let turnID = correlationToTurnID[correlation],
              var turn = turnsByID[turnID] else {
            throw TranscriptReducerError.unknownProviderItem(correlation)
        }
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if (turn.state == .liveFinal || turn.state == .superseded),
           turn.text == normalized {
            return TranscriptReducerCompletion(turn: turn, updates: [])
        }
        conversationRevision += 1
        turn.text = normalized
        turn.revision += 1
        turn.state = .liveFinal
        turnsByID[turnID] = turn
        echoSupersededOutgoingTurnIDs.remove(turnID)

        var changedByID: [UUID: LiveTranscriptTurn] = [turnID: turn]
        reconcileCrossTrackEchoes(changedByID: &changedByID)
        let current = turnsByID[turnID] ?? turn
        let sideEffects = changedByID.values
            .filter { $0.id != turnID }
            .sorted(by: LiveTranscriptTurn.canonicalTimelineOrder)
        let updates = sideEffects + (changedByID[turnID].map { [$0] } ?? [])
        return TranscriptReducerCompletion(turn: current, updates: updates)
    }

    private mutating func reconcileCrossTrackEchoes(
        changedByID: inout [UUID: LiveTranscriptTurn]
    ) {
        let incomingEvidence = turnsByID.values
            .filter { $0.track == .incoming && $0.state == .liveFinal }
            .map {
                TimedTranscriptEvidence(
                    startCallNanoseconds: $0.startCallNanoseconds,
                    endCallNanoseconds: $0.endCallNanoseconds,
                    text: $0.text
                )
            }

        let outgoingIDs = turnsByID.values
            .filter {
                $0.track == .outgoing
                    && ($0.state == .liveFinal
                        || echoSupersededOutgoingTurnIDs.contains($0.id))
            }
            .map(\.id)
        for id in outgoingIDs {
            guard var outgoing = turnsByID[id] else { continue }
            let shouldSuppress = echoSuppressionPolicy.isProbableEcho(
                outgoing: TimedTranscriptEvidence(
                    startCallNanoseconds: outgoing.startCallNanoseconds,
                    endCallNanoseconds: outgoing.endCallNanoseconds,
                    text: outgoing.text
                ),
                incoming: incomingEvidence
            )

            if shouldSuppress, outgoing.state == .liveFinal {
                conversationRevision += 1
                outgoing.revision += 1
                outgoing.state = .superseded
                turnsByID[id] = outgoing
                echoSupersededOutgoingTurnIDs.insert(id)
                changedByID[id] = outgoing
            } else if !shouldSuppress,
                      echoSupersededOutgoingTurnIDs.contains(id),
                      outgoing.state == .superseded {
                conversationRevision += 1
                outgoing.revision += 1
                outgoing.state = .liveFinal
                turnsByID[id] = outgoing
                echoSupersededOutgoingTurnIDs.remove(id)
                changedByID[id] = outgoing
            }
        }
    }

    @discardableResult
    mutating func insertGap(
        id: UUID = UUID(),
        track: AudioTrack,
        startCallNanoseconds: UInt64,
        endCallNanoseconds: UInt64?
    ) -> LiveTranscriptTurn {
        if let existing = turnsByID[id], existing.state == .gap {
            let mergedStart = min(existing.startCallNanoseconds, startCallNanoseconds)
            let mergedEnd: UInt64?
            switch (existing.endCallNanoseconds, endCallNanoseconds) {
            case let (existingEnd?, newEnd?):
                mergedEnd = max(existingEnd, newEnd)
            case let (existingEnd?, nil):
                mergedEnd = existingEnd
            case let (nil, newEnd?):
                mergedEnd = newEnd
            case (nil, nil):
                mergedEnd = nil
            }
            guard existing.track != track
                    || existing.startCallNanoseconds != mergedStart
                    || existing.endCallNanoseconds != mergedEnd else {
                return existing
            }
            conversationRevision += 1
            let updated = LiveTranscriptTurn(
                id: id,
                track: track,
                startCallNanoseconds: mergedStart,
                endCallNanoseconds: mergedEnd,
                text: "",
                revision: existing.revision + 1,
                state: .gap,
                sessionEpoch: nil,
                providerItemID: nil,
                providerContentIndex: nil
            )
            turnsByID[id] = updated
            return updated
        }
        conversationRevision += 1
        let turn = LiveTranscriptTurn(
            id: id,
            track: track,
            startCallNanoseconds: startCallNanoseconds,
            endCallNanoseconds: endCallNanoseconds,
            text: "",
            revision: 1,
            state: .gap,
            sessionEpoch: nil,
            providerItemID: nil,
            providerContentIndex: nil
        )
        turnsByID[id] = turn
        return turn
    }

    func pendingCommitCount(track: AudioTrack, sessionEpoch: Int) -> Int {
        pendingCommits[SessionKey(track: track, epoch: sessionEpoch)]?.count ?? 0
    }
}
