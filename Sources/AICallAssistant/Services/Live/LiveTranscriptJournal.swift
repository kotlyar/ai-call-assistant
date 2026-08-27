import Foundation

struct LiveTranscriptJournalDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let callID: UUID
    var revision: Int64
    var sealedAt: Date?
    var turns: [LiveTranscriptTurn]
}

enum LiveTranscriptJournalError: Error, Equatable, Sendable {
    case callIDMismatch(expected: UUID, actual: UUID)
    case unsupportedState(LiveTranscriptTurn.State)
    case revisionCollision(turnID: UUID, revision: Int)
}

/// A small write-ahead journal for terminal Realtime turns. It is deliberately
/// independent from metadata.json so a crash between capture and normal stop
/// can still recover the best live transcript available at that instant.
actor LiveTranscriptJournal {
    nonisolated let url: URL

    private let callID: UUID
    private var document: LiveTranscriptJournalDocument

    init(callFolderURL: URL, callID: UUID) throws {
        self.callID = callID
        url = callFolderURL.appendingPathComponent("transcript.live.json")

        if FileManager.default.fileExists(atPath: url.path) {
            let loaded = try Self.makeDecoder().decode(
                LiveTranscriptJournalDocument.self,
                from: Data(contentsOf: url)
            )
            guard loaded.callID == callID else {
                throw LiveTranscriptJournalError.callIDMismatch(
                    expected: callID,
                    actual: loaded.callID
                )
            }
            document = loaded
        } else {
            let initial = LiveTranscriptJournalDocument(
                schemaVersion: 1,
                callID: callID,
                revision: 0,
                sealedAt: nil,
                turns: []
            )
            document = initial
            try Self.persist(initial, to: url)
        }
    }

    @discardableResult
    func upsert(_ turn: LiveTranscriptTurn) throws -> Int64 {
        guard turn.state == .liveFinal
                || turn.state == .reconciled
                || turn.state == .superseded
                || turn.state == .gap else {
            throw LiveTranscriptJournalError.unsupportedState(turn.state)
        }

        var updated = document
        if let index = updated.turns.firstIndex(where: { $0.id == turn.id }) {
            let existing = updated.turns[index]
            if turn.revision < existing.revision { return document.revision }
            if turn.revision == existing.revision {
                guard turn == existing else {
                    throw LiveTranscriptJournalError.revisionCollision(
                        turnID: turn.id,
                        revision: turn.revision
                    )
                }
                return document.revision
            }
            updated.turns[index] = turn
        } else {
            updated.turns.append(turn)
        }
        updated.turns.sort(by: LiveTranscriptTurn.canonicalTimelineOrder)
        updated.revision += 1
        try commit(updated)
        return updated.revision
    }

    func seal(at date: Date = Date()) throws {
        guard document.sealedAt == nil else { return }
        var updated = document
        updated.sealedAt = date
        try commit(updated)
    }

    func snapshot() -> LiveTranscriptJournalDocument {
        document
    }

    private func commit(_ updated: LiveTranscriptJournalDocument) throws {
        try Self.persist(updated, to: url)
        document = updated
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func persist(
        _ document: LiveTranscriptJournalDocument,
        to url: URL
    ) throws {
        try makeEncoder().encode(document).write(to: url, options: .atomic)
    }
}
