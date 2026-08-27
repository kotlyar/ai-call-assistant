import Foundation
@testable import AICallAssistant

struct FinalAnalysisTestFixture {
    let callID = UUID(uuidString: "73000000-0000-0000-0000-000000000001")!
    let canonicalHash = String(repeating: "a", count: 64)

    var turns: [ReconciledTranscriptTurn] {
        [
            ReconciledTranscriptTurn(
                id: "canonical-incoming-1",
                track: .incoming,
                startCallNanoseconds: 0,
                endCallNanoseconds: 9,
                text: "Какой бюджет? И кто согласует?",
                detectorMiss: false,
                sourceChunkIDs: ["incoming-chunk-1"]
            ),
            ReconciledTranscriptTurn(
                id: "canonical-outgoing-1",
                track: .outgoing,
                startCallNanoseconds: 10,
                endCallNanoseconds: 19,
                text: "Бюджет — миллион, согласует директор.",
                detectorMiss: false,
                sourceChunkIDs: ["outgoing-chunk-1"]
            ),
            ReconciledTranscriptTurn(
                id: "canonical-incoming-2",
                track: .incoming,
                startCallNanoseconds: 20,
                endCallNanoseconds: 29,
                text: "Позже уточняю: а срок?",
                detectorMiss: false,
                sourceChunkIDs: ["incoming-chunk-2"]
            ),
            ReconciledTranscriptTurn(
                id: "canonical-outgoing-2",
                track: .outgoing,
                startCallNanoseconds: 30,
                endCallNanoseconds: 39,
                text: "Срок — пятница.",
                detectorMiss: false,
                sourceChunkIDs: ["outgoing-chunk-2"]
            )
        ]
    }

    var contexts: FrozenContextSnapshot {
        FrozenContextSnapshot(
            id: "frozen-contexts-v1",
            frozenAt: Date(timeIntervalSince1970: 1_000),
            contexts: [
                FrozenContext(
                    sourceContextID: UUID(
                        uuidString: "73000000-0000-0000-0000-000000000020"
                    )!,
                    title: "Договор",
                    body: "Полное тело договора — без сокращений.",
                    sourceVersion: 2,
                    contentSHA256: String(repeating: "2", count: 64)
                ),
                FrozenContext(
                    sourceContextID: UUID(
                        uuidString: "73000000-0000-0000-0000-000000000010"
                    )!,
                    title: "Бриф",
                    body: "Полный бриф клиента — тоже без сокращений.",
                    sourceVersion: 1,
                    contentSHA256: String(repeating: "1", count: 64)
                )
            ]
        )
    }

    var configuration: GuidanceConfigurationSnapshot {
        GuidanceConfigurationSnapshot(
            id: "configuration-v1",
            responsesModelID: "gpt-5.6-terra",
            realtimeTranscriptionModelID: "gpt-live-transcribe",
            fileTranscriptionModelID: "gpt-transcribe",
            transcriptionLanguages: ["ru", "en"],
            answerStyle: .brief,
            answerLanguage: .automatic,
            briefAnswerMaxWords: 60,
            detailedAnswerMaxWords: 160,
            adviceMaxWords: 30,
            maxOutputTokens: 4_096,
            initialPerCallSpendLimitUSD: 5,
            priceCatalogVersion: OpenAIPriceCatalog.current.version,
            modelCapabilityProfileID: "capabilities-v1",
            policyVersion: 1
        )
    }

    func reconciliation(
        status: ReconciliationStatus = .complete
    ) -> ReconciliationStoredJob {
        ReconciliationStoredJob(
            id: "reconciliation-job",
            callID: callID,
            modelID: "gpt-transcribe",
            chunkerVersion: 1,
            createdAt: Date(timeIntervalSince1970: 900),
            updatedAt: Date(timeIntervalSince1970: 950),
            startedAt: Date(timeIntervalSince1970: 910),
            completedAt: status == .complete ? Date(timeIntervalSince1970: 950) : nil,
            status: status,
            attempts: 2,
            lastErrorCode: nil,
            tracks: [],
            result: ReconciliationCanonicalResult(
                turns: turns,
                trackCoverage: AudioTrack.allCases.map {
                    ReconciliationTrackCoverage(
                        track: $0,
                        sourceDurationNanoseconds: 100,
                        fullyProcessed: status == .complete,
                        missingReason: nil
                    )
                }
            )
        )
    }

    func snapshot(
        canonicalRevision: Int64 = 7,
        canonicalHash: String? = nil
    ) throws -> FinalAnalysisSnapshot {
        try FinalAnalysisSnapshotBuilder().makeSnapshot(
            reconciliation: reconciliation(),
            canonicalRevision: canonicalRevision,
            canonicalTranscriptHash: canonicalHash ?? self.canonicalHash,
            frozenContexts: contexts,
            configuration: configuration
        )
    }

    func providerRequest(
        snapshot: FinalAnalysisSnapshot
    ) -> FinalAnalysisProviderRequest {
        FinalAnalysisProviderRequest(
            jobID: "job",
            triggerJobID: "trigger-job",
            idempotencyKey: "trigger-job",
            snapshot: snapshot,
            triggerTurnID: turns[0].id,
            attempt: 1,
            apiKey: "test-key"
        )
    }

    func responsePair(
        question: String,
        quote: String
    ) -> FinalAnalysisResponseQuestionAnswer {
        FinalAnalysisResponseQuestionAnswer(
            normalizedQuestion: question,
            sourceSpans: [
                FinalAnalysisResponseSourceSpan(
                    canonicalTurnID: turns[0].id,
                    exactQuote: quote
                )
            ],
            answer: "Ответ на вопрос",
            advice: "Ответьте кратко",
            usedTurnIDs: turns.map(\.id),
            usedContextIDs: contexts.contexts.map(\.sourceContextID)
        )
    }
}
