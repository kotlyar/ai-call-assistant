import Foundation
import XCTest
@testable import AICallAssistant

final class ConversationContextStoreTests: XCTestCase {
    func testLegacyCallContextDecodesWithEmptyAttachments() throws {
        let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "title": "Legacy",
              "body": "Manual body",
              "isSelected": true
            }
            """.utf8
        )

        let context = try JSONDecoder().decode(CallContext.self, from: data)

        XCTAssertEqual(context.id, id)
        XCTAssertEqual(context.title, "Legacy")
        XCTAssertEqual(context.body, "Manual body")
        XCTAssertTrue(context.isSelected)
        XCTAssertTrue(context.attachments.isEmpty)
    }

    func testCallContextRoundTripsAttachments() throws {
        let context = makeContext()

        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(CallContext.self, from: encoded)

        XCTAssertEqual(decoded, context)
    }

    func testFreezeUsesManualBodyAndAllAttachmentTextsInSavedOrder() async {
        let context = makeContext()
        let store = ConversationContextStore(
            callID: UUID(),
            contexts: [context],
            configuration: .frozen(from: .default)
        )

        let frozenSnapshot = await store.frozenContexts
        let frozen = frozenSnapshot.contexts.first
        XCTAssertEqual(
            frozen?.body,
            """
            VISIBLE_MANUAL_BODY

            <<< BEGIN CONTEXT FILE: first file.pdf >>>
            FIRST_EXACT_TEXT
            <<< END CONTEXT FILE: first file.pdf >>>

            <<< BEGIN CONTEXT FILE: second file.docx >>>
            SECOND_EXACT_TEXT
            <<< END CONTEXT FILE: second file.docx >>>
            """
        )
        XCTAssertEqual(frozen?.body, context.assistantContextBody)
    }

    func testFrozenHashChangesWhenAttachmentTextChangesOrAttachmentIsRemoved() async {
        let original = makeContext()
        var changedText = original
        changedText.attachments[0].extractedText = "CHANGED_EXACT_TEXT"
        var removedAttachment = original
        removedAttachment.attachments.removeLast()

        let originalStore = makeStore(context: original)
        let changedTextStore = makeStore(context: changedText)
        let removedAttachmentStore = makeStore(context: removedAttachment)
        let originalSnapshot = await originalStore.frozenContexts
        let changedTextSnapshot = await changedTextStore.frozenContexts
        let removedAttachmentSnapshot = await removedAttachmentStore.frozenContexts

        XCTAssertNotEqual(
            originalSnapshot.contexts.first?.contentSHA256,
            changedTextSnapshot.contexts.first?.contentSHA256
        )
        XCTAssertNotEqual(
            originalSnapshot.contexts.first?.contentSHA256,
            removedAttachmentSnapshot.contexts.first?.contentSHA256
        )
        XCTAssertNotEqual(originalSnapshot.id, changedTextSnapshot.id)
        XCTAssertNotEqual(originalSnapshot.id, removedAttachmentSnapshot.id)
    }

    func testAssistantContextBodyDoesNotMutateVisibleManualBody() {
        let context = makeContext()

        XCTAssertEqual(context.body, "VISIBLE_MANUAL_BODY")
        XCTAssertFalse(context.body.contains("FIRST_EXACT_TEXT"))
        XCTAssertTrue(context.assistantContextBody.contains("FIRST_EXACT_TEXT"))
    }

    func testSupersededOutgoingEchoIsRemovedFromLaterGuidanceSnapshot() async throws {
        let store = ConversationContextStore(
            callID: UUID(),
            contexts: [],
            configuration: .frozen(from: .default)
        )
        let outgoingID = UUID()
        let incomingID = UUID()
        let outgoing = turn(
            id: outgoingID,
            track: .outgoing,
            start: 100,
            end: 300,
            text: "Повтор собеседника",
            revision: 1,
            state: .liveFinal
        )
        let incoming = turn(
            id: incomingID,
            track: .incoming,
            start: 0,
            end: 400,
            text: "Повтор собеседника",
            revision: 1,
            state: .liveFinal
        )
        var tombstone = outgoing
        tombstone.revision = 2
        tombstone.state = .superseded

        _ = try await store.acceptFinal(outgoing)
        _ = try await store.acceptFinal(tombstone)
        _ = try await store.acceptFinal(incoming)

        let snapshot = try await store.makeLiveSnapshot(trigger: incoming.reference)
        let allFinalTurns = await store.allFinalTurns()
        XCTAssertEqual(snapshot.turns.map(\.reference.turnID), [incomingID])
        XCTAssertEqual(allFinalTurns.map(\.id), [incomingID])
    }

    func testStaleFinalCannotResurrectSupersededTombstone() async throws {
        let store = ConversationContextStore(
            callID: UUID(),
            contexts: [],
            configuration: .frozen(from: .default)
        )
        let original = turn(
            id: UUID(),
            track: .outgoing,
            start: 0,
            end: 100,
            text: "Повтор собеседника",
            revision: 1,
            state: .liveFinal
        )
        var tombstone = original
        tombstone.revision = 2
        tombstone.state = .superseded

        _ = try await store.acceptFinal(original)
        _ = try await store.acceptFinal(tombstone)
        let revision = try await store.acceptFinal(original)
        let allFinalTurns = await store.allFinalTurns()

        XCTAssertEqual(revision, 2)
        XCTAssertTrue(allFinalTurns.isEmpty)
    }

    private func turn(
        id: UUID,
        track: AudioTrack,
        start: UInt64,
        end: UInt64,
        text: String,
        revision: Int,
        state: LiveTranscriptTurn.State
    ) -> LiveTranscriptTurn {
        LiveTranscriptTurn(
            id: id,
            track: track,
            startCallNanoseconds: start,
            endCallNanoseconds: end,
            text: text,
            revision: revision,
            state: state,
            sessionEpoch: 1,
            providerItemID: id.uuidString,
            providerContentIndex: 0
        )
    }

    private func makeStore(context: CallContext) -> ConversationContextStore {
        ConversationContextStore(
            callID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            contexts: [context],
            configuration: .frozen(from: .default),
            frozenAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeContext() -> CallContext {
        CallContext(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            title: "Context with files",
            body: "VISIBLE_MANUAL_BODY",
            isSelected: true,
            attachments: [
                ContextFileAttachment(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                    fileName: "first\r\nfile.pdf",
                    mediaType: "application/pdf",
                    byteCount: 111,
                    contentSHA256: String(repeating: "a", count: 64),
                    extractedText: "FIRST_EXACT_TEXT"
                ),
                ContextFileAttachment(
                    id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
                    fileName: "second file.docx",
                    mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    byteCount: 222,
                    contentSHA256: String(repeating: "b", count: 64),
                    extractedText: "SECOND_EXACT_TEXT"
                )
            ]
        )
    }
}
