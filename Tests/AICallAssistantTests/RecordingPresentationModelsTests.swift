import Foundation
import XCTest
@testable import AICallAssistant

final class RecordingPresentationModelsTests: XCTestCase {
    func testLegacyRecordingIsReadyWithoutFinalAnalysisSection() {
        let presentation = RecordingPostCallPresentation.make(
            for: Recording(
                title: "Legacy",
                startedAt: .distantPast,
                duration: 1,
                folderName: "legacy",
                turns: []
            )
        )

        XCTAssertEqual(presentation.transcription.label, .ready)
        XCTAssertNil(presentation.finalAnalysis)
        XCTAssertEqual(presentation.overallLabel, .ready)
        XCTAssertFalse(presentation.canRetryPostCallProcessing)
    }

    func testPendingReconciliationIsProcessing() {
        let presentation = makePresentation(
            reconciliation: .pending,
            finalAnalysis: .waitingForReconciliation
        )

        XCTAssertEqual(presentation.transcription.label, .processing)
        XCTAssertEqual(presentation.finalAnalysis?.label, .processing)
        XCTAssertEqual(presentation.overallLabel, .processing)
        XCTAssertFalse(presentation.canRetryPostCallProcessing)
    }

    func testRecoverableReconciliationFailuresOfferRetryButIncompleteDoesNot() {
        let retryable: [ReconciliationStatus] = [
            .blockedByCredential,
            .blockedBySpendLimit,
            .failed
        ]

        for status in retryable {
            let presentation = makePresentation(
                reconciliation: status,
                finalAnalysis: .waitingForReconciliation
            )

            XCTAssertEqual(presentation.transcription.label, .failed, "status: \(status)")
            XCTAssertEqual(presentation.overallLabel, .failed, "status: \(status)")
            XCTAssertTrue(presentation.canRetryPostCallProcessing, "status: \(status)")
        }

        let incomplete = makePresentation(
            reconciliation: .incomplete,
            finalAnalysis: .waitingForReconciliation
        )
        XCTAssertFalse(incomplete.canRetryPostCallProcessing)
    }

    func testCompleteReconciliationWaitsForFinalAnalysis() {
        let presentation = makePresentation(
            reconciliation: .complete,
            finalAnalysis: .running
        )

        XCTAssertEqual(presentation.transcription.label, .ready)
        XCTAssertEqual(presentation.finalAnalysis?.label, .processing)
        XCTAssertEqual(presentation.overallLabel, .processing)
        XCTAssertFalse(presentation.canRetryPostCallProcessing)
    }

    func testCompleteFinalAnalysisIsReady() {
        let presentation = makePresentation(
            reconciliation: .complete,
            finalAnalysis: .complete
        )

        XCTAssertEqual(presentation.transcription.label, .ready)
        XCTAssertEqual(presentation.finalAnalysis?.label, .ready)
        XCTAssertEqual(presentation.overallLabel, .ready)
    }

    func testRecoverableFinalAnalysisFailureOffersPostCallRetry() {
        let presentation = makePresentation(
            reconciliation: .complete,
            finalAnalysis: .failed
        )

        XCTAssertEqual(presentation.finalAnalysis?.label, .failed)
        XCTAssertEqual(presentation.overallLabel, .failed)
        XCTAssertTrue(presentation.canRetryPostCallProcessing)
    }

    func testLocalizedLabelsCoverProcessingReadyAndFailed() {
        XCTAssertEqual(RecordingProcessingLabel.processing.title, "Обработка")
        XCTAssertEqual(RecordingProcessingLabel.ready.title, "Готово")
        XCTAssertEqual(RecordingProcessingLabel.failed.title, "Ошибка")
    }

    private func makePresentation(
        reconciliation: ReconciliationStatus,
        finalAnalysis: FinalAnalysisStatus
    ) -> RecordingPostCallPresentation {
        RecordingPostCallPresentation.make(
            for: Recording(
                title: "Call",
                startedAt: .distantPast,
                duration: 1,
                folderName: "call",
                turns: [],
                transcription: RecordingTranscriptionMetadata(
                    callState: .saved,
                    liveStatus: .complete,
                    reconciliationStatus: reconciliation,
                    finalAnalysisStatus: finalAnalysis,
                    incomingRealtimeStatus: .live,
                    outgoingRealtimeStatus: .live,
                    liveRevision: 1,
                    canonicalRevision: reconciliation == .complete ? 2 : nil,
                    liveJournalSealedAt: .distantPast,
                    provider: "openai",
                    realtimeModelID: "realtime",
                    fileTranscriptionModelID: "transcribe",
                    responsesModelID: "responses",
                    frozenContexts: FrozenContextSnapshot(
                        id: "contexts",
                        frozenAt: .distantPast,
                        contexts: []
                    ),
                    frozenConfiguration: GuidanceConfigurationSnapshot(
                        id: "configuration",
                        responsesModelID: "responses",
                        realtimeTranscriptionModelID: "realtime",
                        fileTranscriptionModelID: "transcribe",
                        transcriptionLanguages: ["ru"],
                        answerStyle: .brief,
                        answerLanguage: .automatic,
                        briefAnswerMaxWords: 60,
                        detailedAnswerMaxWords: 160,
                        adviceMaxWords: 30,
                        maxOutputTokens: 4_096,
                        initialPerCallSpendLimitUSD: Decimal(string: "1.00")!,
                        priceCatalogVersion: "prices-v1",
                        modelCapabilityProfileID: "capabilities-v1",
                        policyVersion: 1
                    ),
                    lastErrorCode: nil
                )
            )
        )
    }
}
