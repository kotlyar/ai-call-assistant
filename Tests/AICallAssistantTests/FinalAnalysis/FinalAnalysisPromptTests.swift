import Foundation
import XCTest
@testable import AICallAssistant

final class FinalAnalysisPromptTests: XCTestCase {
    func testSnapshotRejectsIncompleteReconciliationAndPreservesFullVerbatimInput() throws {
        let fixture = FinalAnalysisTestFixture()
        let builder = FinalAnalysisSnapshotBuilder()

        XCTAssertThrowsError(try builder.makeSnapshot(
            reconciliation: fixture.reconciliation(status: .incomplete),
            canonicalRevision: 7,
            canonicalTranscriptHash: fixture.canonicalHash,
            frozenContexts: fixture.contexts,
            configuration: fixture.configuration
        )) { error in
            XCTAssertEqual(
                error as? FinalAnalysisSnapshotBuilderError,
                .reconciliationNotComplete(.incomplete)
            )
        }

        let snapshot = try fixture.snapshot()
        let providerRequest = fixture.providerRequest(snapshot: snapshot)
        let request = try FinalAnalysisPromptBuilder(
            maximumInputUTF8Bytes: 1_000_000
        ).makeRequest(for: providerRequest)
        let payloadData = try XCTUnwrap(
            request.input.last?.content.data(using: .utf8)
        )
        let payload = try JSONDecoder().decode(
            FinalAnalysisPromptPayload.self,
            from: payloadData
        )

        XCTAssertEqual(snapshot.perspective, .postCallRetrospective)
        XCTAssertEqual(payload.perspective, .postCallRetrospective)
        XCTAssertEqual(payload.turns.map(\.text), fixture.turns.map(\.text))
        XCTAssertEqual(payload.turns.map(\.track), fixture.turns.map(\.track))
        XCTAssertEqual(
            payload.contexts.map(\.title),
            fixture.contexts.canonicallyOrderedContexts.map(\.title)
        )
        XCTAssertEqual(
            payload.contexts.map(\.body),
            fixture.contexts.canonicallyOrderedContexts.map(\.body)
        )
        XCTAssertEqual(payload.triggerTurnID, fixture.turns[0].id)
        XCTAssertTrue(payload.turns.contains { $0.text == "Позже уточняю: а срок?" })
        XCTAssertTrue(payload.turns.contains { $0.text == "Срок — пятница." })
    }

    func testHardLocalContextLimitRejectsWholeRequestWithoutTransport() async throws {
        let fixture = FinalAnalysisTestFixture()
        let transport = FinalAnalysisTransport(body: Data())
        let provider = OpenAIResponsesFinalAnalysisProvider(
            transport: transport,
            promptBuilder: FinalAnalysisPromptBuilder(maximumInputUTF8Bytes: 1)
        )

        do {
            _ = try await provider.analyze(
                request: fixture.providerRequest(snapshot: try fixture.snapshot())
            )
            XCTFail("Expected a terminal local context rejection")
        } catch let error as FinalAnalysisProviderError {
            XCTAssertEqual(error, .contextLimitExceeded)
        }
        let rejectedSendCount = await transport.sendCount
        XCTAssertEqual(rejectedSendCount, 0)
    }

    func testFinalSpendEstimateUsesFullEncodedResponsesRequest() throws {
        let fixture = FinalAnalysisTestFixture()
        let providerRequest = fixture.providerRequest(
            snapshot: try fixture.snapshot()
        )
        let apiRequest = try FinalAnalysisPromptBuilder(
            maximumInputUTF8Bytes: Int.max
        ).makeRequest(for: providerRequest)
        let requestBody = try OpenAIResponsesRequestEncoding.encode(apiRequest)
        let estimate = try FinalAnalysisRequestSpendEstimator().estimate(
            for: providerRequest
        )
        let snapshotOnlyBytes = try JSONEncoder().encode(
            providerRequest.snapshot
        ).count

        XCTAssertEqual(estimate.encodedRequestUTF8Bytes, requestBody.count)
        XCTAssertEqual(
            estimate.reservedInputTokens,
            requestBody.count
                + OpenAIResponsesRequestSpendEstimator.defaultFixedInputTokenMargin
        )
        XCTAssertGreaterThan(requestBody.count, snapshotOnlyBytes)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        XCTAssertTrue((input.first?["content"] as? String)?.contains(
            "fully reconciled post-call conversation"
        ) ?? false)
        let text = try XCTUnwrap(root["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertNotNil(format["schema"])
    }

    func testResponsesProviderReturnsEveryQuestionAndRejectsNonTriggerEvidence() async throws {
        let fixture = FinalAnalysisTestFixture()
        let snapshot = try fixture.snapshot()
        let request = fixture.providerRequest(snapshot: snapshot)
        let page = FinalAnalysisResponsePage(
            snapshotID: snapshot.id,
            triggerTurnID: fixture.turns[0].id,
            complete: true,
            questionAnswers: [
                fixture.responsePair(
                    question: "Какой бюджет?",
                    quote: "Какой бюджет?"
                ),
                fixture.responsePair(
                    question: "Кто согласует?",
                    quote: "кто согласует?"
                )
            ]
        )
        let transport = FinalAnalysisTransport(body: try responseBody(page: page))
        let provider = OpenAIResponsesFinalAnalysisProvider(
            transport: transport,
            promptBuilder: FinalAnalysisPromptBuilder(
                maximumInputUTF8Bytes: 1_000_000
            )
        )

        let result = try await provider.analyze(request: request)
        XCTAssertEqual(result.triggerTurnID, fixture.turns[0].id)
        XCTAssertEqual(result.cards.map(\.normalizedQuestion), [
            "Какой бюджет?", "Кто согласует?"
        ])
        XCTAssertEqual(result.cards.count, 2)
        let successfulSendCount = await transport.sendCount
        XCTAssertEqual(successfulSendCount, 1)

        let invalidPage = FinalAnalysisResponsePage(
            snapshotID: snapshot.id,
            triggerTurnID: fixture.turns[0].id,
            complete: true,
            questionAnswers: [
                FinalAnalysisResponseQuestionAnswer(
                    normalizedQuestion: "Bad evidence",
                    sourceSpans: [
                        FinalAnalysisResponseSourceSpan(
                            canonicalTurnID: fixture.turns[1].id,
                            exactQuote: fixture.turns[1].text
                        )
                    ],
                    answer: "Answer",
                    advice: "Advice",
                    usedTurnIDs: [fixture.turns[1].id],
                    usedContextIDs: []
                )
            ]
        )
        XCTAssertThrowsError(try FinalAnalysisResponseValidator().validate(
            invalidPage,
            request: request
        )) { error in
            XCTAssertEqual(
                error as? FinalAnalysisResponseValidationError,
                .evidenceOutsideIncomingTrigger(pairIndex: 0, evidenceIndex: 0)
            )
        }
    }

    func testProviderRejectsNonCompletedStatusAndSnapshotMismatch() async throws {
        let fixture = FinalAnalysisTestFixture()
        let snapshot = try fixture.snapshot()
        let request = fixture.providerRequest(snapshot: snapshot)
        let validPage = FinalAnalysisResponsePage(
            snapshotID: snapshot.id,
            triggerTurnID: fixture.turns[0].id,
            complete: true,
            questionAnswers: []
        )
        let pageData = try JSONEncoder().encode(validPage)
        let pageString = try XCTUnwrap(String(data: pageData, encoding: .utf8))
        let nonCompletedBody = try JSONSerialization.data(withJSONObject: [
            "status": "in_progress",
            "output": [["content": [[
                "type": "output_text",
                "text": pageString
            ]]]]
        ])
        let provider = OpenAIResponsesFinalAnalysisProvider(
            transport: FinalAnalysisTransport(body: nonCompletedBody),
            promptBuilder: FinalAnalysisPromptBuilder(
                maximumInputUTF8Bytes: 1_000_000
            )
        )

        do {
            _ = try await provider.analyze(request: request)
            XCTFail("Expected a non-completed response to be rejected")
        } catch let error as FinalAnalysisProviderError {
            XCTAssertEqual(error, .incomplete(reason: "in_progress"))
        }

        let mismatch = FinalAnalysisResponsePage(
            snapshotID: "another-snapshot",
            triggerTurnID: fixture.turns[0].id,
            complete: true,
            questionAnswers: []
        )
        XCTAssertThrowsError(try FinalAnalysisResponseValidator().validate(
            mismatch,
            request: request
        )) { error in
            XCTAssertEqual(
                error as? FinalAnalysisResponseValidationError,
                .snapshotMismatch(
                    expected: snapshot.id,
                    actual: "another-snapshot"
                )
            )
        }
    }

    private func responseBody(page: FinalAnalysisResponsePage) throws -> Data {
        let pageData = try JSONEncoder().encode(page)
        let pageString = try XCTUnwrap(String(data: pageData, encoding: .utf8))
        return try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [[
                "content": [[
                    "type": "output_text",
                    "text": pageString
                ]]
            ]]
        ])
    }
}

private actor FinalAnalysisTransport: OpenAIResponsesFinalAnalysisTransport {
    private let body: Data
    private(set) var sendCount = 0

    init(body: Data) {
        self.body = body
    }

    func send(
        requestBody: Data,
        idempotencyKey: String,
        apiKey: String
    ) async throws -> OpenAIResponsesFinalAnalysisTransportResponse {
        sendCount += 1
        return OpenAIResponsesFinalAnalysisTransportResponse(
            statusCode: 200,
            body: body
        )
    }
}
