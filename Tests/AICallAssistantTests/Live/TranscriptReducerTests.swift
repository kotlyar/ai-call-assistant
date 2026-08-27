import XCTest
@testable import AICallAssistant

final class TranscriptReducerTests: XCTestCase {
    func testCommitBindingIsFIFOAndScopedPerTrack() throws {
        let firstID = UUID()
        let secondID = UUID()
        var reducer = TranscriptReducer()
        reducer.enqueueCommittedLocalTurn(
            pending(id: firstID, track: .incoming, start: 100, end: 200)
        )
        reducer.enqueueCommittedLocalTurn(
            pending(id: secondID, track: .incoming, start: 300, end: 400)
        )

        let first = try reducer.bindNextCommittedItem(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "server-b"
        )
        let second = try reducer.bindNextCommittedItem(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "server-a"
        )

        XCTAssertEqual(first.id, firstID)
        XCTAssertEqual(second.id, secondID)
        XCTAssertEqual(reducer.pendingCommitCount(track: .incoming, sessionEpoch: 1), 0)
    }

    func testSameProviderItemIDsOnTwoSocketsNeverCollide() throws {
        let incomingID = UUID()
        let outgoingID = UUID()
        var reducer = TranscriptReducer()
        reducer.enqueueCommittedLocalTurn(
            pending(id: incomingID, track: .incoming, start: 0, end: 100)
        )
        reducer.enqueueCommittedLocalTurn(
            pending(id: outgoingID, track: .outgoing, start: 0, end: 100)
        )
        _ = try reducer.bindNextCommittedItem(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "same"
        )
        _ = try reducer.bindNextCommittedItem(
            track: .outgoing,
            sessionEpoch: 1,
            providerItemID: "same"
        )

        let incoming = try reducer.applyCompleted(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "same",
            contentIndex: 0,
            transcript: "Question"
        )
        let outgoing = try reducer.applyCompleted(
            track: .outgoing,
            sessionEpoch: 1,
            providerItemID: "same",
            contentIndex: 0,
            transcript: "Answer"
        )

        XCTAssertEqual(incoming.turn.id, incomingID)
        XCTAssertEqual(outgoing.turn.id, outgoingID)
        XCTAssertEqual(reducer.conversationRevision, 2)
    }

    func testFinalReplacesPartialAndDuplicateFinalIsIdempotent() throws {
        let id = UUID()
        var reducer = TranscriptReducer()
        reducer.enqueueCommittedLocalTurn(pending(id: id, track: .incoming, start: 0, end: 10))
        _ = try reducer.bindNextCommittedItem(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "item"
        )
        let partial = try reducer.applyDelta(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "item",
            contentIndex: 0,
            delta: "How "
        )
        XCTAssertEqual(partial.text, "How ")

        let final = try reducer.applyCompleted(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "item",
            contentIndex: 0,
            transcript: "How are you?"
        )
        let duplicate = try reducer.applyCompleted(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "item",
            contentIndex: 0,
            transcript: "How are you?"
        )

        XCTAssertEqual(final.turn.state, .liveFinal)
        XCTAssertEqual(final.turn.text, "How are you?")
        XCTAssertEqual(duplicate.turn, final.turn)
        XCTAssertTrue(duplicate.updates.isEmpty)
        XCTAssertEqual(reducer.conversationRevision, 1)
    }

    func testOverlappingOutgoingEchoFragmentIsSupersededWhenIncomingFinalArrivesLater() throws {
        let outgoingID = UUID()
        let incomingID = UUID()
        var reducer = TranscriptReducer()
        bind(
            &reducer,
            id: outgoingID,
            track: .outgoing,
            start: 300_000_000,
            end: 1_200_000_000,
            itemID: "outgoing"
        )
        bind(
            &reducer,
            id: incomingID,
            track: .incoming,
            start: 0,
            end: 1_500_000_000,
            itemID: "incoming"
        )

        let outgoing = try reducer.applyCompleted(
            track: .outgoing,
            sessionEpoch: 1,
            providerItemID: "outgoing",
            contentIndex: 0,
            transcript: "Фраза от"
        )
        XCTAssertEqual(outgoing.turn.state, .liveFinal)

        let incoming = try reducer.applyCompleted(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "incoming",
            contentIndex: 0,
            transcript: "Почему дублируется фраза «от»?"
        )

        XCTAssertEqual(incoming.turn.state, .liveFinal)
        XCTAssertEqual(incoming.updates.map(\.id), [outgoingID, incomingID])
        XCTAssertEqual(incoming.updates.first?.state, .superseded)
        XCTAssertEqual(
            reducer.turns.first(where: { $0.id == outgoingID })?.state,
            .superseded
        )
    }

    func testMeasuredMacBookEchoLeadAndFragmentTimingIsSuppressed() throws {
        let outgoingID = UUID()
        let incomingID = UUID()
        var reducer = TranscriptReducer()
        bind(
            &reducer,
            id: outgoingID,
            track: .outgoing,
            start: 263_498_000_000,
            end: 264_898_000_000,
            itemID: "measured-outgoing"
        )
        bind(
            &reducer,
            id: incomingID,
            track: .incoming,
            start: 263_907_000_000,
            end: 265_607_000_000,
            itemID: "measured-incoming"
        )
        _ = try complete(
            &reducer,
            track: .outgoing,
            itemID: "measured-outgoing",
            text: "Собеседника"
        )

        let completion = try complete(
            &reducer,
            track: .incoming,
            itemID: "measured-incoming",
            text: "Собеседника"
        )

        XCTAssertEqual(completion.updates.map(\.id), [outgoingID, incomingID])
        XCTAssertEqual(completion.updates.first?.state, .superseded)
    }

    func testMeasuredEightHundredMillisecondCrossClockLeadIsSuppressed() throws {
        let outgoingID = UUID()
        let incomingID = UUID()
        var reducer = TranscriptReducer()
        bind(
            &reducer,
            id: outgoingID,
            track: .outgoing,
            start: 258_998_000_000,
            end: 261_000_000_000,
            itemID: "lead-outgoing"
        )
        bind(
            &reducer,
            id: incomingID,
            track: .incoming,
            start: 259_807_000_000,
            end: 261_500_000_000,
            itemID: "lead-incoming"
        )
        _ = try complete(
            &reducer,
            track: .outgoing,
            itemID: "lead-outgoing",
            text: "Почему дублируется"
        )

        let completion = try complete(
            &reducer,
            track: .incoming,
            itemID: "lead-incoming",
            text: "Почему дублируется фраза от"
        )

        XCTAssertEqual(completion.updates.first?.id, outgoingID)
        XCTAssertEqual(completion.updates.first?.state, .superseded)
    }

    func testOverlappingOutgoingEchoIsImmediatelySupersededWhenIncomingFinalExists() throws {
        let incomingID = UUID()
        let outgoingID = UUID()
        var reducer = TranscriptReducer()
        bind(
            &reducer,
            id: incomingID,
            track: .incoming,
            start: 0,
            end: 1_000_000_000,
            itemID: "incoming"
        )
        bind(
            &reducer,
            id: outgoingID,
            track: .outgoing,
            start: 100_000_000,
            end: 1_050_000_000,
            itemID: "outgoing"
        )
        _ = try reducer.applyCompleted(
            track: .incoming,
            sessionEpoch: 1,
            providerItemID: "incoming",
            contentIndex: 0,
            transcript: "Собеседника"
        )

        let outgoing = try reducer.applyCompleted(
            track: .outgoing,
            sessionEpoch: 1,
            providerItemID: "outgoing",
            contentIndex: 0,
            transcript: "Собеседника."
        )

        XCTAssertEqual(outgoing.turn.state, .superseded)
        XCTAssertEqual(outgoing.updates, [outgoing.turn])
    }

    func testShortAcknowledgementAndNonOverlappingRepeatAreNotSuppressed() throws {
        var reducer = TranscriptReducer()
        bind(
            &reducer,
            id: UUID(),
            track: .incoming,
            start: 0,
            end: 1_000_000_000,
            itemID: "incoming-short"
        )
        bind(
            &reducer,
            id: UUID(),
            track: .outgoing,
            start: 100_000_000,
            end: 900_000_000,
            itemID: "outgoing-short"
        )
        bind(
            &reducer,
            id: UUID(),
            track: .incoming,
            start: 2_000_000_000,
            end: 3_000_000_000,
            itemID: "incoming-later"
        )
        bind(
            &reducer,
            id: UUID(),
            track: .outgoing,
            start: 3_100_000_000,
            end: 4_000_000_000,
            itemID: "outgoing-later"
        )
        _ = try complete(&reducer, track: .incoming, itemID: "incoming-short", text: "Да")
        let short = try complete(
            &reducer,
            track: .outgoing,
            itemID: "outgoing-short",
            text: "Да"
        )
        _ = try complete(
            &reducer,
            track: .incoming,
            itemID: "incoming-later",
            text: "Собеседника"
        )
        let later = try complete(
            &reducer,
            track: .outgoing,
            itemID: "outgoing-later",
            text: "Собеседника"
        )

        XCTAssertEqual(short.turn.state, .liveFinal)
        XCTAssertEqual(later.turn.state, .liveFinal)
    }

    private func bind(
        _ reducer: inout TranscriptReducer,
        id: UUID,
        track: AudioTrack,
        start: UInt64,
        end: UInt64,
        itemID: String
    ) {
        reducer.enqueueCommittedLocalTurn(
            PendingLocalTranscriptTurn(
                id: id,
                track: track,
                sessionEpoch: 1,
                startCallNanoseconds: start,
                endCallNanoseconds: end
            )
        )
        _ = try? reducer.bindNextCommittedItem(
            track: track,
            sessionEpoch: 1,
            providerItemID: itemID
        )
    }

    private func complete(
        _ reducer: inout TranscriptReducer,
        track: AudioTrack,
        itemID: String,
        text: String
    ) throws -> TranscriptReducerCompletion {
        try reducer.applyCompleted(
            track: track,
            sessionEpoch: 1,
            providerItemID: itemID,
            contentIndex: 0,
            transcript: text
        )
    }

    private func pending(
        id: UUID,
        track: AudioTrack,
        start: UInt64,
        end: UInt64
    ) -> PendingLocalTranscriptTurn {
        PendingLocalTranscriptTurn(
            id: id,
            track: track,
            sessionEpoch: 1,
            startCallNanoseconds: start,
            endCallNanoseconds: end
        )
    }
}
