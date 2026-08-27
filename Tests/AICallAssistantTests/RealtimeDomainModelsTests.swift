import Foundation
import XCTest
@testable import AICallAssistant

final class RealtimeDomainModelsTests: XCTestCase {
    func testLiveTranscriptTurnRoundTripsWithProviderCorrelation() throws {
        let turn = LiveTranscriptTurn(
            id: Self.incomingTurnID,
            track: .incoming,
            startCallNanoseconds: 1_250_000_000,
            endCallNanoseconds: 2_000_000_000,
            text: "Как это внедрить?",
            revision: 3,
            state: .liveFinal,
            sessionEpoch: 2,
            providerItemID: "item-42",
            providerContentIndex: 0
        )

        XCTAssertEqual(try roundTrip(turn), turn)
        XCTAssertEqual(turn.reference, TurnReference(turnID: Self.incomingTurnID, revision: 3))
        XCTAssertEqual(
            turn.providerCorrelation,
            TranscriptProviderCorrelation(
                track: .incoming,
                sessionEpoch: 2,
                providerItemID: "item-42",
                contentIndex: 0
            )
        )
    }

    func testProviderCorrelationRequiresEveryProviderField() {
        let partialIdentity = LiveTranscriptTurn(
            id: Self.incomingTurnID,
            track: .incoming,
            startCallNanoseconds: 0,
            endCallNanoseconds: nil,
            text: "",
            revision: 0,
            state: .partial,
            sessionEpoch: 1,
            providerItemID: nil,
            providerContentIndex: 0
        )

        XCTAssertNil(partialIdentity.providerCorrelation)
    }

    func testCanonicalTranscriptOrderingUsesTimeTrackAndStableID() {
        let later = makeLiveTurn(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            track: .incoming,
            start: 20
        )
        let outgoing = makeLiveTurn(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            track: .outgoing,
            start: 10
        )
        let incoming = makeLiveTurn(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            track: .incoming,
            start: 10
        )

        XCTAssertEqual(
            [later, outgoing, incoming].sorted(by: LiveTranscriptTurn.canonicalTimelineOrder).map(\.id),
            [incoming.id, outgoing.id, later.id]
        )
    }

    func testFrozenContextSnapshotAcceptsEmptyAndCanonicalizesBySourceID() throws {
        let empty = FrozenContextSnapshot(
            id: "contexts-empty",
            frozenAt: Date(timeIntervalSince1970: 1_000),
            contexts: []
        )
        XCTAssertEqual(try roundTrip(empty), empty)

        let high = makeContext(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            title: "High"
        )
        let low = makeContext(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Low"
        )
        let snapshot = FrozenContextSnapshot(
            id: "contexts",
            frozenAt: Date(timeIntervalSince1970: 1_000),
            contexts: [high, low]
        )

        XCTAssertEqual(snapshot.canonicallyOrderedContexts, [low, high])
    }

    func testGuidanceConfigurationAndSpendRevisionRoundTrip() throws {
        let configuration = makeConfiguration(style: .detailed)
        let authorization = SpendAuthorizationRevision(
            id: "spend-2",
            callID: Self.callID,
            revision: 2,
            authorizedLimitUSD: Decimal(string: "7.50")!,
            priceCatalogVersion: "prices-2026-08-15",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(configuration.selectedAnswerMaxWords, 160)
        XCTAssertEqual(try roundTrip(configuration), configuration)
        XCTAssertEqual(try roundTrip(authorization), authorization)
        XCTAssertEqual(configuration.initialPerCallSpendLimitUSD, Decimal(string: "5.00")!)
        XCTAssertEqual(authorization.authorizedLimitUSD, Decimal(string: "7.50")!)
    }

    func testConversationSnapshotRoundTripsBothTracksAndTriggerScope() throws {
        let incomingReference = TurnReference(turnID: Self.incomingTurnID, revision: 1)
        let outgoingReference = TurnReference(turnID: Self.outgoingTurnID, revision: 1)
        let incoming = SnapshotTurn(
            reference: incomingReference,
            track: .incoming,
            startCallNanoseconds: 20,
            endCallNanoseconds: 30,
            text: "Как это внедрить?"
        )
        let outgoing = SnapshotTurn(
            reference: outgoingReference,
            track: .outgoing,
            startCallNanoseconds: 10,
            endCallNanoseconds: 15,
            text: "Сейчас объясню контекст."
        )
        let snapshot = ConversationSnapshot(
            schemaVersion: 1,
            id: "sha256:snapshot",
            callID: Self.callID,
            conversationRevision: 9,
            turns: [incoming, outgoing],
            triggerTurns: [incomingReference],
            frozenContexts: FrozenContextSnapshot(
                id: "contexts",
                frozenAt: Date(timeIntervalSince1970: 1_000),
                contexts: [makeContext(id: Self.contextID, title: "Product")]
            ),
            configuration: makeConfiguration(style: .brief),
            perspective: .livePointInTime
        )

        XCTAssertEqual(try roundTrip(snapshot), snapshot)
        XCTAssertEqual(snapshot.canonicallyOrderedTurns, [outgoing, incoming])
        XCTAssertEqual(snapshot.triggerTurns, [incomingReference])
        XCTAssertEqual(Set(snapshot.turns.map(\.track)), Set(AudioTrack.allCases))
    }

    func testQuestionRunPersistsSeparateCardsAndAmbiguousEvidence() throws {
        let reference = TurnReference(turnID: Self.incomingTurnID, revision: 1)
        let runID = "run-1"
        let firstPair = QuestionAnswerPair(
            id: QuestionAnswerPair.deterministicID(runID: runID, canonicalOrdinal: 0),
            snapshotID: "snapshot-1",
            normalizedQuestion: "Когда запуск?",
            evidence: [
                QuestionEvidence(
                    turn: reference,
                    exactQuote: "Когда запуск?",
                    unicodeScalarRange: 0..<13
                )
            ],
            answer: "Запуск запланирован на понедельник.",
            advice: "Назовите дату и следующий шаг.",
            usedTurnIDs: [Self.incomingTurnID, Self.outgoingTurnID],
            usedContextIDs: [Self.contextID],
            isLate: false
        )
        let secondPair = QuestionAnswerPair(
            id: QuestionAnswerPair.deterministicID(runID: runID, canonicalOrdinal: 1),
            snapshotID: "snapshot-1",
            normalizedQuestion: "Кто отвечает?",
            evidence: [
                QuestionEvidence(
                    turn: reference,
                    exactQuote: "Кто отвечает?",
                    unicodeScalarRange: nil
                )
            ],
            answer: "Ответственный — команда продукта.",
            advice: "Уточните имя владельца.",
            usedTurnIDs: [Self.incomingTurnID],
            usedContextIDs: [],
            isLate: true
        )
        let run = AnalysisRun(
            id: runID,
            snapshotID: "snapshot-1",
            trigger: [reference],
            pairs: [firstPair, secondPair],
            status: .published
        )

        XCTAssertEqual(try roundTrip(run), run)
        XCTAssertEqual(run.pairs.map(\.id), ["run-1:pair:0", "run-1:pair:1"])
        XCTAssertNil(run.pairs[1].evidence[0].unicodeScalarRange)
        XCTAssertTrue(run.pairs[1].isLate)
    }

    func testAssistantMomentHighlightsOnlyUniqueEvidenceAndCarriesLateFlag() {
        let reference = TurnReference(turnID: Self.incomingTurnID, revision: 1)
        let turn = LiveTranscriptTurn(
            id: Self.incomingTurnID,
            track: .incoming,
            startCallNanoseconds: 1,
            endCallNanoseconds: 2,
            text: "Before When launch? After",
            revision: 1,
            state: .liveFinal,
            sessionEpoch: 1,
            providerItemID: "item",
            providerContentIndex: 0
        )
        let unique = QuestionAnswerPair(
            id: "unique",
            snapshotID: "snapshot",
            normalizedQuestion: "When launch?",
            evidence: [
                QuestionEvidence(
                    turn: reference,
                    exactQuote: "When launch?",
                    unicodeScalarRange: 7..<19
                )
            ],
            answer: "Monday.",
            advice: "Give the date.",
            usedTurnIDs: [Self.incomingTurnID],
            usedContextIDs: [],
            isLate: true
        )
        let ambiguous = QuestionAnswerPair(
            id: "ambiguous",
            snapshotID: "snapshot",
            normalizedQuestion: "When?",
            evidence: [
                QuestionEvidence(
                    turn: reference,
                    exactQuote: "When?",
                    unicodeScalarRange: nil
                )
            ],
            answer: "Unknown.",
            advice: "Clarify.",
            usedTurnIDs: [Self.incomingTurnID],
            usedContextIDs: [],
            isLate: false
        )

        let highlighted = AssistantMoment(
            guidancePair: unique,
            transcriptTurns: [turn]
        )
        let plain = AssistantMoment(
            guidancePair: ambiguous,
            transcriptTurns: [turn]
        )

        XCTAssertEqual(highlighted.heardText, turn.text)
        XCTAssertEqual(highlighted.heardTextHighlightRange, 7..<19)
        XCTAssertTrue(highlighted.isLate)
        XCTAssertEqual(plain.heardText, "When?")
        XCTAssertNil(plain.heardTextHighlightRange)
        XCTAssertFalse(plain.isLate)
    }

    func testPersistedStateRawValuesMatchThePlan() throws {
        XCTAssertEqual(PersistedCallState.allCases.map(\.rawValue), [
            "draft", "capturing", "interrupted", "saved"
        ])
        XCTAssertEqual(LiveTranscriptionStatus.allCases.map(\.rawValue), [
            "notStarted", "running", "complete", "incomplete", "failed", "budgetStopped"
        ])
        XCTAssertEqual(ReconciliationStatus.allCases.map(\.rawValue), [
            "pending", "running", "blockedByCredential", "blockedBySpendLimit",
            "complete", "incomplete", "failed"
        ])
        XCTAssertEqual(FinalAnalysisStatus.allCases.map(\.rawValue), [
            "waitingForReconciliation", "pending", "running", "blockedByCredential",
            "blockedBySpendLimit", "contextLimitExceeded", "complete", "failed"
        ])
        XCTAssertEqual(try roundTrip(RealtimeTrackStatus.reconnecting), .reconnecting)
        XCTAssertEqual(try roundTrip(LiveGuidanceStatus.contextLimitReached), .contextLimitReached)
    }

    func testRealtimeFailureDiagnosticRoundTripsWithoutProviderMessageField() throws {
        let diagnostic = RealtimeFailureDiagnostic(
            code: "http_401",
            reason: .authentication,
            httpStatus: 401
        )

        XCTAssertEqual(try roundTrip(diagnostic), diagnostic)
        let encoded = try JSONEncoder().encode(diagnostic)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set(["code", "reason", "httpStatus"]))
        XCTAssertNil(object["message"])
    }

    func testLegacyRecordingMetadataDecodesWithoutRealtimeFailureDiagnostics() throws {
        let configuration = makeConfiguration(style: .brief)
        let metadata = RecordingTranscriptionMetadata(
            callState: .saved,
            liveStatus: .incomplete,
            reconciliationStatus: .pending,
            finalAnalysisStatus: .waitingForReconciliation,
            incomingRealtimeStatus: .failed,
            outgoingRealtimeStatus: .live,
            incomingRealtimeFailure: RealtimeFailureDiagnostic(
                code: "http_401",
                reason: .authentication,
                httpStatus: 401
            ),
            outgoingRealtimeFailure: nil,
            liveRevision: 0,
            canonicalRevision: nil,
            liveJournalSealedAt: nil,
            provider: "openai",
            realtimeModelID: configuration.realtimeTranscriptionModelID,
            fileTranscriptionModelID: configuration.fileTranscriptionModelID,
            responsesModelID: configuration.responsesModelID,
            frozenContexts: FrozenContextSnapshot(
                id: "ctx-empty",
                frozenAt: Date(timeIntervalSince1970: 1),
                contexts: []
            ),
            frozenConfiguration: configuration,
            lastErrorCode: nil
        )
        let encoded = try JSONEncoder().encode(metadata)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "incomingRealtimeFailure")
        object.removeValue(forKey: "outgoingRealtimeFailure")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            RecordingTranscriptionMetadata.self,
            from: legacyData
        )

        XCTAssertNil(decoded.incomingRealtimeFailure)
        XCTAssertNil(decoded.outgoingRealtimeFailure)
    }

    func testRealtimeFailurePresentationUsesActionableLocalizedReasons() {
        XCTAssertEqual(
            RealtimeFailurePresentation(
                RealtimeFailureDiagnostic(
                    code: "insufficient_quota",
                    reason: .quotaExceeded,
                    httpStatus: 429
                )
            ).message,
            "Закончился баланс OpenAI API."
        )
        XCTAssertEqual(
            RealtimeFailurePresentation(
                RealtimeFailureDiagnostic(
                    code: "invalid_session_configuration",
                    reason: .invalidConfiguration,
                    httpStatus: 400
                )
            ).message,
            "Проверьте модель и настройки Realtime."
        )
    }

    func testCoreModelsConformToSendable() {
        assertSendable(AudioTrack.self)
        assertSendable(LiveTranscriptTurn.self)
        assertSendable(GuidanceConfigurationSnapshot.self)
        assertSendable(ConversationSnapshot.self)
        assertSendable(AnalysisRun.self)
        assertSendable(FinalAnalysisStatus.self)
        assertSendable(RealtimeFailureDiagnostic.self)
    }

    private func makeLiveTurn(id: UUID, track: AudioTrack, start: UInt64) -> LiveTranscriptTurn {
        LiveTranscriptTurn(
            id: id,
            track: track,
            startCallNanoseconds: start,
            endCallNanoseconds: start + 1,
            text: "turn",
            revision: 1,
            state: .liveFinal,
            sessionEpoch: nil,
            providerItemID: nil,
            providerContentIndex: nil
        )
    }

    private func makeContext(id: UUID, title: String) -> FrozenContext {
        FrozenContext(
            sourceContextID: id,
            title: title,
            body: "Full context body",
            sourceVersion: 4,
            contentSHA256: "sha256:\(id.uuidString.lowercased())"
        )
    }

    private func makeConfiguration(style: AnswerStyle) -> GuidanceConfigurationSnapshot {
        GuidanceConfigurationSnapshot(
            id: "configuration-1",
            responsesModelID: GuidanceConfigurationDefaults.responsesModelID,
            realtimeTranscriptionModelID: GuidanceConfigurationDefaults.realtimeTranscriptionModelID,
            fileTranscriptionModelID: GuidanceConfigurationDefaults.fileTranscriptionModelID,
            transcriptionLanguages: GuidanceConfigurationDefaults.transcriptionLanguages,
            answerStyle: style,
            answerLanguage: .automatic,
            briefAnswerMaxWords: GuidanceConfigurationDefaults.briefAnswerMaxWords,
            detailedAnswerMaxWords: GuidanceConfigurationDefaults.detailedAnswerMaxWords,
            adviceMaxWords: GuidanceConfigurationDefaults.adviceMaxWords,
            maxOutputTokens: GuidanceConfigurationDefaults.maxOutputTokens,
            initialPerCallSpendLimitUSD: Decimal(string: "5.00")!,
            priceCatalogVersion: "prices-2026-08-15",
            modelCapabilityProfileID: "openai-default-v1",
            policyVersion: 1
        )
    }

    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        let encoded = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: encoded)
    }

    private func assertSendable<Value: Sendable>(_: Value.Type) {}

    private static let callID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private static let incomingTurnID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private static let outgoingTurnID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private static let contextID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
}
