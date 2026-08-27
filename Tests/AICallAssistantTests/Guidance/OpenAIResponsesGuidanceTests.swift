import Foundation
import XCTest
@testable import AICallAssistant

final class OpenAIResponsesGuidanceTests: XCTestCase {
    func testPromptContainsFullVerbatimSnapshotContextsAndPerspective() throws {
        let snapshot = makeSnapshot(perspective: .postCallRetrospective)

        let request = try GuidancePromptBuilder().makeRequest(for: snapshot)
        let payloadData = try XCTUnwrap(request.input.last?.content.data(using: .utf8))
        let payload = try JSONDecoder().decode(GuidanceSnapshotPromptPayload.self, from: payloadData)

        XCTAssertFalse(request.store)
        XCTAssertEqual(request.model, snapshot.configuration.responsesModelID)
        XCTAssertEqual(request.maxOutputTokens, snapshot.configuration.maxOutputTokens)
        XCTAssertEqual(payload.schemaVersion, snapshot.schemaVersion)
        XCTAssertEqual(payload.snapshotID, snapshot.id)
        XCTAssertEqual(payload.callID, snapshot.callID)
        XCTAssertEqual(payload.conversationRevision, snapshot.conversationRevision)
        XCTAssertEqual(payload.perspective, .postCallRetrospective)
        XCTAssertEqual(payload.triggerTurns, snapshot.triggerTurns)
        XCTAssertEqual(payload.frozenContextSnapshotID, snapshot.frozenContexts.id)
        XCTAssertEqual(payload.configurationID, snapshot.configuration.id)
        XCTAssertEqual(payload.turns.map(\.text), [
            "OUTGOING_VERBATIM_🙂_do-not-change",
            "INCOMING_VERBATIM_e\u{301}_do-not-change"
        ])
        XCTAssertEqual(payload.contexts.map(\.title), ["Context A", "Context B"])
        XCTAssertEqual(payload.contexts.map(\.body), [
            "FULL_CONTEXT_BODY_A\nsecond line",
            "FULL_CONTEXT_BODY_B_🙂"
        ])
        XCTAssertEqual(payload.answerPolicy.style, .brief)
        XCTAssertEqual(payload.answerPolicy.language, .automatic)
    }

    func testStrictSchemaRequiresEvidenceWithoutQuestionCountOrPaginationCap() throws {
        let request = try GuidancePromptBuilder().makeRequest(for: makeSnapshot())
        let data = try JSONEncoder().encode(request)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = try dictionary(root["text"])
        let format = try dictionary(text["format"])
        let schema = try dictionary(format["schema"])
        let rootProperties = try dictionary(schema["properties"])
        let questionAnswers = try dictionary(rootProperties["questionAnswers"])
        let pair = try dictionary(questionAnswers["items"])
        let pairProperties = try dictionary(pair["properties"])
        let sourceSpans = try dictionary(pairProperties["sourceSpans"])
        let sourceSpan = try dictionary(sourceSpans["items"])

        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(questionAnswers["type"] as? String, "array")
        XCTAssertNil(questionAnswers["maxItems"])
        XCTAssertNil(rootProperties["hasMore"])
        XCTAssertFalse((schema["required"] as? [String])?.contains("hasMore") ?? true)
        XCTAssertEqual(pair["additionalProperties"] as? Bool, false)
        XCTAssertEqual(sourceSpans["minItems"] as? Int, 1)
        XCTAssertEqual(sourceSpan["additionalProperties"] as? Bool, false)
        XCTAssertTrue(
            request.input.first?.content.contains(
                "Return exactly one questionAnswers item for every distinct question"
            ) ?? false
        )
    }

    func testPromptBuilderRejectsOutgoingTrigger() {
        let snapshot = makeSnapshot(trigger: Self.outgoingReference)

        XCTAssertThrowsError(try GuidancePromptBuilder().makeRequest(for: snapshot)) { error in
            XCTAssertEqual(
                error as? GuidancePromptBuilderError,
                .outgoingTriggerTurn(Self.outgoingReference)
            )
        }
    }

    func testValidatorRejectsEmptyEvidence() {
        let page = GuidanceResponsePage(
            snapshotID: "diagnostic",
            questionAnswers: [makeQuestion(sourceSpans: [])]
        )

        XCTAssertThrowsError(
            try GuidanceResponseValidator().validate(page, against: makeSnapshot())
        ) { error in
            XCTAssertEqual(
                error as? GuidanceResponseValidationError,
                .evidenceRequired(pairIndex: 0)
            )
        }
    }

    func testValidatorRejectsOutgoingEvidenceEvenWhenTurnExists() {
        let outgoingSpan = GuidanceResponseSourceSpan(
            turnID: Self.outgoingReference.turnID,
            turnRevision: Self.outgoingReference.revision,
            exactQuote: "OUTGOING_VERBATIM_🙂_do-not-change"
        )
        let page = GuidanceResponsePage(
            snapshotID: "diagnostic",
            questionAnswers: [makeQuestion(sourceSpans: [outgoingSpan])]
        )

        XCTAssertThrowsError(
            try GuidanceResponseValidator().validate(page, against: makeSnapshot())
        ) { error in
            XCTAssertEqual(
                error as? GuidanceResponseValidationError,
                .evidenceOutsideIncomingTrigger(
                    pairIndex: 0,
                    evidenceIndex: 0,
                    reference: Self.outgoingReference
                )
            )
        }
    }

    func testValidatorKeepsAmbiguousQuoteWithoutHighlightRange() throws {
        let snapshot = makeSnapshot(incomingText: "Когда? Потом. Когда?")
        let span = GuidanceResponseSourceSpan(
            turnID: Self.incomingReference.turnID,
            turnRevision: Self.incomingReference.revision,
            exactQuote: "Когда?"
        )
        let page = GuidanceResponsePage(
            snapshotID: "provider-echo",
            questionAnswers: [makeQuestion(sourceSpans: [span])]
        )

        let validated = try GuidanceResponseValidator().validate(page, against: snapshot)

        XCTAssertEqual(validated.snapshotID, snapshot.id)
        XCTAssertEqual(validated.providerSnapshotID, "provider-echo")
        XCTAssertEqual(validated.questionAnswers.count, 1)
        XCTAssertNil(validated.questionAnswers[0].evidence[0].unicodeScalarRange)
    }

    func testValidatorComputesUniqueUnicodeScalarRange() throws {
        let prefix = "🙂 e\u{301} "
        let quote = "Когда?"
        let snapshot = makeSnapshot(incomingText: prefix + quote)
        let page = GuidanceResponsePage(
            snapshotID: snapshot.id,
            questionAnswers: [
                makeQuestion(sourceSpans: [
                    GuidanceResponseSourceSpan(
                        turnID: Self.incomingReference.turnID,
                        turnRevision: Self.incomingReference.revision,
                        exactQuote: quote
                    )
                ])
            ]
        )

        let validated = try GuidanceResponseValidator().validate(page, against: snapshot)

        XCTAssertEqual(
            validated.questionAnswers[0].evidence[0].unicodeScalarRange,
            prefix.unicodeScalars.count..<(prefix.unicodeScalars.count + quote.unicodeScalars.count)
        )
    }

    func testClientMapsProviderContextLengthErrorToTerminalState() async throws {
        let body = Data(
            #"{"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"too long"}}"#.utf8
        )
        let transport = FakeGuidanceTransport(
            response: OpenAIResponsesTransportResponse(statusCode: 400, body: body)
        )
        let client = OpenAIResponsesGuidanceClient(transport: transport)

        do {
            _ = try await client.analyze(snapshot: makeSnapshot())
            XCTFail("Expected contextLimitReached")
        } catch let error as OpenAIResponsesGuidanceClientError {
            XCTAssertEqual(error, .contextLimitReached)
            XCTAssertTrue(error.isTerminal)
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testClientDecodesAndValidatesStructuredOutput() async throws {
        let page = GuidanceResponsePage(
            snapshotID: "provider-diagnostic",
            questionAnswers: [makeQuestion(sourceSpans: [Self.incomingSpan])]
        )
        let pageData = try JSONEncoder().encode(page)
        let pageText = try XCTUnwrap(String(data: pageData, encoding: .utf8))
        let envelope = ResponsesFixture(
            status: "completed",
            output: [
                .init(content: [.init(type: "output_text", text: pageText)])
            ]
        )
        let body = try JSONEncoder().encode(envelope)
        let transport = FakeGuidanceTransport(
            response: OpenAIResponsesTransportResponse(statusCode: 200, body: body)
        )
        let client = OpenAIResponsesGuidanceClient(transport: transport)

        let validated = try await client.analyze(snapshot: makeSnapshot())

        XCTAssertEqual(validated.questionAnswers.count, 1)
        XCTAssertEqual(validated.questionAnswers[0].normalizedQuestion, "Как это внедрить?")
        XCTAssertNotNil(validated.questionAnswers[0].evidence[0].unicodeScalarRange)
        let sentBody = await transport.lastRequestBody
        XCTAssertNotNil(sentBody)
    }

    func testProviderReturnsEveryQuestionBeyondFormerThreeItemLimit() async throws {
        let questions = [
            "Как запустить пилот?",
            "Кто будет владельцем?",
            "Какие нужны сроки?",
            "Как измерить результат?"
        ]
        let snapshot = makeSnapshot(incomingText: questions.joined(separator: " "))
        let page = GuidanceResponsePage(
            snapshotID: "provider-all-questions",
            questionAnswers: questions.map { question in
                makeQuestion(
                    normalizedQuestion: question,
                    sourceSpans: [
                        GuidanceResponseSourceSpan(
                            turnID: Self.incomingReference.turnID,
                            turnRevision: Self.incomingReference.revision,
                            exactQuote: question
                        )
                    ]
                )
            }
        )
        let pageData = try JSONEncoder().encode(page)
        let pageText = try XCTUnwrap(String(data: pageData, encoding: .utf8))
        let envelope = ResponsesFixture(
            status: "completed",
            output: [
                .init(content: [.init(type: "output_text", text: pageText)])
            ]
        )
        let transport = FakeGuidanceTransport(
            response: OpenAIResponsesTransportResponse(
                statusCode: 200,
                body: try JSONEncoder().encode(envelope)
            )
        )
        let provider = OpenAIResponsesLiveGuidanceProvider(
            client: OpenAIResponsesGuidanceClient(transport: transport)
        )

        let result = try await provider.analyze(snapshot: snapshot)

        XCTAssertEqual(result.questionAnswers.map(\.normalizedQuestion), questions)
    }

    func testProviderRejectsIncompleteResponseEvenWhenPartialOutputIsValid() async throws {
        let page = GuidanceResponsePage(
            snapshotID: "provider-partial",
            questionAnswers: [makeQuestion(sourceSpans: [Self.incomingSpan])]
        )
        let pageData = try JSONEncoder().encode(page)
        let pageText = try XCTUnwrap(String(data: pageData, encoding: .utf8))
        let envelope = ResponsesFixture(
            status: "incomplete",
            incompleteDetails: .init(reason: "max_output_tokens"),
            output: [
                .init(content: [.init(type: "output_text", text: pageText)])
            ]
        )
        let transport = FakeGuidanceTransport(
            response: OpenAIResponsesTransportResponse(
                statusCode: 200,
                body: try JSONEncoder().encode(envelope)
            )
        )
        let provider = OpenAIResponsesLiveGuidanceProvider(
            client: OpenAIResponsesGuidanceClient(transport: transport)
        )

        do {
            _ = try await provider.analyze(snapshot: makeSnapshot())
            XCTFail("An incomplete response must not produce a publishable result")
        } catch let error as OpenAIResponsesGuidanceClientError {
            XCTAssertEqual(error, .incomplete(reason: "max_output_tokens"))
        }
    }

    private func makeSnapshot(
        perspective: AnalysisPerspective = .livePointInTime,
        trigger: TurnReference = incomingReference,
        incomingText: String = "INCOMING_VERBATIM_e\u{301}_do-not-change"
    ) -> ConversationSnapshot {
        let outgoing = SnapshotTurn(
            reference: Self.outgoingReference,
            track: .outgoing,
            startCallNanoseconds: 10,
            endCallNanoseconds: 20,
            text: "OUTGOING_VERBATIM_🙂_do-not-change"
        )
        let incoming = SnapshotTurn(
            reference: Self.incomingReference,
            track: .incoming,
            startCallNanoseconds: 30,
            endCallNanoseconds: 40,
            text: incomingText
        )
        let contexts = [
            FrozenContext(
                sourceContextID: Self.contextAID,
                title: "Context A",
                body: "FULL_CONTEXT_BODY_A\nsecond line",
                sourceVersion: 1,
                contentSHA256: "hash-a"
            ),
            FrozenContext(
                sourceContextID: Self.contextBID,
                title: "Context B",
                body: "FULL_CONTEXT_BODY_B_🙂",
                sourceVersion: 2,
                contentSHA256: "hash-b"
            )
        ]

        return ConversationSnapshot(
            schemaVersion: 1,
            id: "local-snapshot-id",
            callID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            conversationRevision: 2,
            turns: [incoming, outgoing],
            triggerTurns: [trigger],
            frozenContexts: FrozenContextSnapshot(
                id: "contexts",
                frozenAt: Date(timeIntervalSince1970: 1_000),
                contexts: contexts
            ),
            configuration: GuidanceConfigurationSnapshot(
                id: "configuration",
                responsesModelID: "gpt-test",
                realtimeTranscriptionModelID: "stt-live-test",
                fileTranscriptionModelID: "stt-file-test",
                transcriptionLanguages: ["ru", "en"],
                answerStyle: .brief,
                answerLanguage: .automatic,
                briefAnswerMaxWords: 60,
                detailedAnswerMaxWords: 160,
                adviceMaxWords: 30,
                maxOutputTokens: 4_096,
                initialPerCallSpendLimitUSD: 5,
                priceCatalogVersion: "test-prices",
                modelCapabilityProfileID: "test-capabilities",
                policyVersion: 1
            ),
            perspective: perspective
        )
    }

    private func makeQuestion(
        normalizedQuestion: String = "Как это внедрить?",
        sourceSpans: [GuidanceResponseSourceSpan]
    ) -> GuidanceResponseQuestionAnswer {
        GuidanceResponseQuestionAnswer(
            normalizedQuestion: normalizedQuestion,
            sourceSpans: sourceSpans,
            answer: "Начните с небольшого пилота.",
            advice: "Назовите следующий шаг.",
            usedTurnIDs: [Self.incomingReference.turnID, Self.outgoingReference.turnID],
            usedContextIDs: [Self.contextAID]
        )
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private static let incomingReference = TurnReference(
        turnID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        revision: 1
    )
    private static let outgoingReference = TurnReference(
        turnID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        revision: 1
    )
    private static let contextAID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private static let contextBID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    private static let incomingSpan = GuidanceResponseSourceSpan(
        turnID: incomingReference.turnID,
        turnRevision: incomingReference.revision,
        exactQuote: "INCOMING_VERBATIM_e\u{301}_do-not-change"
    )
}

private actor FakeGuidanceTransport: OpenAIResponsesGuidanceTransport {
    private let response: OpenAIResponsesTransportResponse
    private(set) var requestCount = 0
    private(set) var lastRequestBody: Data?

    init(response: OpenAIResponsesTransportResponse) {
        self.response = response
    }

    func send(requestBody: Data) async throws -> OpenAIResponsesTransportResponse {
        requestCount += 1
        lastRequestBody = requestBody
        return response
    }
}

private struct ResponsesFixture: Encodable {
    struct IncompleteDetails: Encodable {
        let reason: String
    }

    struct Output: Encodable {
        struct Content: Encodable {
            let type: String
            let text: String
        }

        let content: [Content]
    }

    let status: String
    let incompleteDetails: IncompleteDetails?
    let output: [Output]

    init(
        status: String,
        incompleteDetails: IncompleteDetails? = nil,
        output: [Output]
    ) {
        self.status = status
        self.incompleteDetails = incompleteDetails
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case incompleteDetails = "incomplete_details"
        case output
    }
}
