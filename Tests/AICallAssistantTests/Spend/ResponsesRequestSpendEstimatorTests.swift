import Foundation
import XCTest
@testable import AICallAssistant

final class ResponsesRequestSpendEstimatorTests: XCTestCase {
    func testEstimateUsesFullDoubleEncodedRequestWithRussianEscapingAndSchema() throws {
        let sourceText = "Русский: \"да\"\nПуть C:\\temp\\🙂?"
        let snapshot = makeSnapshot(incomingText: sourceText)
        let request = try GuidancePromptBuilder().makeRequest(for: snapshot)
        let requestBody = try OpenAIResponsesRequestEncoding.encode(request)
        let estimate = try OpenAIResponsesRequestSpendEstimator().estimate(
            request: request
        )

        XCTAssertEqual(estimate.encodedRequestUTF8Bytes, requestBody.count)
        XCTAssertEqual(
            estimate.reservedInputTokens,
            requestBody.count
                + OpenAIResponsesRequestSpendEstimator.defaultFixedInputTokenMargin
        )
        XCTAssertGreaterThan(
            estimate.reservedInputTokens,
            sourceText.utf8.count
        )

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        let input = try XCTUnwrap(root["input"] as? [[String: Any]])
        let encodedPayload = try XCTUnwrap(input.last?["content"] as? String)
        XCTAssertEqual(encodedPayload, request.input.last?.content)
        XCTAssertTrue(encodedPayload.contains(#"\"да\""#))
        XCTAssertTrue(encodedPayload.contains(#"\n"#))
        XCTAssertTrue(encodedPayload.contains(#"\\temp"#))

        let payload = try JSONDecoder().decode(
            GuidanceSnapshotPromptPayload.self,
            from: Data(encodedPayload.utf8)
        )
        XCTAssertEqual(payload.turns.last?.text, sourceText)
        XCTAssertEqual(payload.contexts.first?.body, "Контекст \"как есть\"\nстрока \\ два")

        let text = try XCTUnwrap(root["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"])
        XCTAssertEqual(root["max_output_tokens"] as? Int, 128)
    }

    func testBudgetedLiveProviderReservesExactEstimateBeforeCallingBase() async throws {
        let snapshot = makeSnapshot()
        let request = try GuidancePromptBuilder().makeRequest(for: snapshot)
        let estimate = try OpenAIResponsesRequestSpendEstimator().estimate(
            request: request
        )
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: snapshot.callID,
            initialLimitUSD: 10
        )
        let base = SpendEstimatorLiveProvider()
        let provider = BudgetedLiveGuidanceProvider(base: base, ledger: ledger)

        _ = try await provider.analyze(snapshot: snapshot)

        let calls = await base.callCount
        let ledgerSnapshot = await ledger.currentSnapshot()
        let reservation = try XCTUnwrap(ledgerSnapshot.reservations.first)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(ledgerSnapshot.reservations.count, 1)
        XCTAssertEqual(reservation.kind, .responses)
        XCTAssertEqual(
            reservation.reservedNanoUSD,
            try OpenAIPriceCatalog.current.responsesNanoUSD(
                modelID: snapshot.configuration.responsesModelID,
                inputTokens: estimate.reservedInputTokens,
                maximumOutputTokens: snapshot.configuration.maxOutputTokens
            )
        )
    }

    func testBudgetRejectionDoesNotCallLiveProvider() async throws {
        let snapshot = makeSnapshot()
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: snapshot.callID,
            initialLimitUSD: 0
        )
        let base = SpendEstimatorLiveProvider()
        let provider = BudgetedLiveGuidanceProvider(base: base, ledger: ledger)

        do {
            _ = try await provider.analyze(snapshot: snapshot)
            XCTFail("Expected the hard spend cap to reject the request")
        } catch let error as SpendLedgerError {
            guard case .limitExceeded = error else {
                return XCTFail("Unexpected spend error: \(error)")
            }
        }

        let calls = await base.callCount
        let ledgerSnapshot = await ledger.currentSnapshot()
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(ledgerSnapshot.reservations.isEmpty)
    }

    func testRecoveredLiveAttemptMustReserveFreshBudget() async throws {
        let snapshot = makeSnapshot()
        let request = try GuidancePromptBuilder().makeRequest(for: snapshot)
        let estimate = try OpenAIResponsesRequestSpendEstimator().estimate(
            request: request
        )
        let exactAttemptCost = try OpenAIPriceCatalog.current.responsesNanoUSD(
            modelID: snapshot.configuration.responsesModelID,
            inputTokens: estimate.reservedInputTokens,
            maximumOutputTokens: snapshot.configuration.maxOutputTokens
        )
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: snapshot.callID,
            initialLimitUSD: Decimal(exactAttemptCost) / Decimal(1_000_000_000)
        )
        let base = SpendEstimatorLiveProvider()
        let provider = BudgetedLiveGuidanceProvider(base: base, ledger: ledger)

        _ = try await provider.analyze(snapshot: snapshot)
        do {
            _ = try await provider.analyze(snapshot: snapshot)
            XCTFail("Expected a recovered attempt to require a fresh reservation")
        } catch let error as SpendLedgerError {
            guard case .limitExceeded = error else {
                return XCTFail("Unexpected spend error: \(error)")
            }
        }

        let calls = await base.callCount
        let ledgerSnapshot = await ledger.currentSnapshot()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(ledgerSnapshot.reservations.count, 1)
        XCTAssertEqual(ledgerSnapshot.reservedNanoUSD, exactAttemptCost)
    }

    private func makeSnapshot(
        incomingText: String = "Как внедрить это безопасно?"
    ) -> ConversationSnapshot {
        let incomingReference = TurnReference(
            turnID: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!,
            revision: 1
        )
        return ConversationSnapshot(
            schemaVersion: 1,
            id: "spend-estimator-snapshot",
            callID: UUID(uuidString: "81000000-0000-0000-0000-000000000010")!,
            conversationRevision: 2,
            turns: [
                SnapshotTurn(
                    reference: TurnReference(
                        turnID: UUID(
                            uuidString: "81000000-0000-0000-0000-000000000002"
                        )!,
                        revision: 1
                    ),
                    track: .outgoing,
                    startCallNanoseconds: 0,
                    endCallNanoseconds: 10,
                    text: "Полный исходящий ответ"
                ),
                SnapshotTurn(
                    reference: incomingReference,
                    track: .incoming,
                    startCallNanoseconds: 11,
                    endCallNanoseconds: 20,
                    text: incomingText
                )
            ],
            triggerTurns: [incomingReference],
            frozenContexts: FrozenContextSnapshot(
                id: "spend-contexts",
                frozenAt: Date(timeIntervalSince1970: 1_000),
                contexts: [
                    FrozenContext(
                        sourceContextID: UUID(
                            uuidString: "81000000-0000-0000-0000-000000000020"
                        )!,
                        title: "Контекст / договор",
                        body: "Контекст \"как есть\"\nстрока \\ два",
                        sourceVersion: 1,
                        contentSHA256: String(repeating: "a", count: 64)
                    )
                ]
            ),
            configuration: GuidanceConfigurationSnapshot(
                id: "spend-configuration",
                responsesModelID: "gpt-5.6-terra",
                realtimeTranscriptionModelID: "gpt-live-transcribe",
                fileTranscriptionModelID: "gpt-transcribe",
                transcriptionLanguages: ["ru", "en"],
                answerStyle: .brief,
                answerLanguage: .automatic,
                briefAnswerMaxWords: 60,
                detailedAnswerMaxWords: 160,
                adviceMaxWords: 30,
                maxOutputTokens: 128,
                initialPerCallSpendLimitUSD: 10,
                priceCatalogVersion: OpenAIPriceCatalog.current.version,
                modelCapabilityProfileID: "capabilities-v1",
                policyVersion: 1
            ),
            perspective: .livePointInTime
        )
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ResponsesRequestSpendEstimatorTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

private actor SpendEstimatorLiveProvider: LiveGuidanceProvider {
    private(set) var callCount = 0

    func analyze(
        snapshot: ConversationSnapshot
    ) async throws -> LiveGuidanceProviderResult {
        callCount += 1
        return LiveGuidanceProviderResult(questionAnswers: [])
    }
}
