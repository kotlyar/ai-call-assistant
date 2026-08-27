import Foundation
import XCTest
@testable import AICallAssistant

final class LiveTranscriptJournalTests: XCTestCase {
    func testTerminalTurnsAreDurableIdempotentAndCanonicallyOrdered() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let callID = UUID()
        let later = makeTurn(track: .outgoing, start: 20)
        let earlier = makeTurn(track: .incoming, start: 10)
        let journal = try LiveTranscriptJournal(callFolderURL: folder, callID: callID)

        let firstRevision = try await journal.upsert(later)
        let secondRevision = try await journal.upsert(earlier)
        let duplicateRevision = try await journal.upsert(earlier)
        XCTAssertEqual(firstRevision, 1)
        XCTAssertEqual(secondRevision, 2)
        XCTAssertEqual(duplicateRevision, 2)
        try await journal.seal(at: Date(timeIntervalSince1970: 123))

        let reopened = try LiveTranscriptJournal(callFolderURL: folder, callID: callID)
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.turns.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(snapshot.sealedAt, Date(timeIntervalSince1970: 123))
    }

    func testNewerTurnRevisionReplacesOlderAndStaleRevisionIsIgnored() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let callID = UUID()
        let journal = try LiveTranscriptJournal(callFolderURL: folder, callID: callID)
        let original = makeTurn(start: 10, text: "First", revision: 1)
        let revised = makeTurn(
            id: original.id,
            start: 10,
            text: "Revised",
            revision: 2
        )

        _ = try await journal.upsert(original)
        _ = try await journal.upsert(revised)
        _ = try await journal.upsert(original)

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.turns, [revised])
    }

    func testPartialTurnIsNotAcceptedAndCallIdentityIsChecked() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = try LiveTranscriptJournal(callFolderURL: folder, callID: UUID())
        var partial = makeTurn(start: 10)
        partial.state = .partial

        do {
            _ = try await journal.upsert(partial)
            XCTFail("Expected unsupported state")
        } catch let error as LiveTranscriptJournalError {
            XCTAssertEqual(error, .unsupportedState(.partial))
        }

        do {
            _ = try LiveTranscriptJournal(callFolderURL: folder, callID: UUID())
            XCTFail("Expected call ID mismatch")
        } catch let error as LiveTranscriptJournalError {
            guard case .callIDMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSupersededEchoTombstoneReplacesPreviouslyPersistedFinal() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = try LiveTranscriptJournal(callFolderURL: folder, callID: UUID())
        let original = makeTurn(track: .outgoing, start: 10, revision: 1)
        var superseded = original
        superseded.revision = 2
        superseded.state = .superseded

        _ = try await journal.upsert(original)
        _ = try await journal.upsert(superseded)

        let snapshot = await journal.snapshot()
        XCTAssertEqual(snapshot.turns, [superseded])
    }

    private func makeTurn(
        id: UUID = UUID(),
        track: AudioTrack = .incoming,
        start: UInt64,
        text: String = "Question?",
        revision: Int = 1
    ) -> LiveTranscriptTurn {
        LiveTranscriptTurn(
            id: id,
            track: track,
            startCallNanoseconds: start,
            endCallNanoseconds: start + 5,
            text: text,
            revision: revision,
            state: .liveFinal,
            sessionEpoch: 1,
            providerItemID: "item-\(id.uuidString)",
            providerContentIndex: 0
        )
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTranscriptJournalTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
