import Foundation

struct FinalAnalysisProviderRequest: Sendable {
    let jobID: String
    let triggerJobID: String
    let idempotencyKey: String
    let snapshot: FinalAnalysisSnapshot
    let triggerTurnID: String
    let attempt: Int
    /// Ephemeral runtime credential. The request is intentionally not Codable.
    let apiKey: String
}

struct FinalAnalysisCardDraft: Codable, Equatable, Sendable {
    let normalizedQuestion: String
    let evidence: [FinalTranscriptEvidence]
    let answer: String
    let advice: String
    let usedCanonicalTurnIDs: [String]
    let usedContextIDs: [UUID]
}

struct FinalAnalysisTriggerResult: Codable, Equatable, Sendable {
    let triggerTurnID: String
    let cards: [FinalAnalysisCardDraft]
}

protocol FinalAnalysisProvider: Sendable {
    func analyze(
        request: FinalAnalysisProviderRequest
    ) async throws -> FinalAnalysisTriggerResult
}

protocol FinalAnalysisProviderFailure: Error {
    var finalAnalysisFailureCode: String { get }
    var isRetryableForFinalAnalysis: Bool { get }
}

enum FinalAnalysisProviderError: Error, Equatable, Sendable,
    FinalAnalysisProviderFailure {
    case contextLimitExceeded
    case providerError(statusCode: Int, code: String?)
    case incomplete(reason: String?)
    case refusal
    case malformedResponse
    case invalidStructuredOutput
    case invalidRequest
    case validationFailed(FinalAnalysisResponseValidationError)

    var finalAnalysisFailureCode: String {
        switch self {
        case .contextLimitExceeded: return "context_limit_exceeded"
        case .providerError: return "provider_error"
        case .incomplete: return "incomplete_response"
        case .refusal: return "refusal"
        case .malformedResponse: return "malformed_response"
        case .invalidStructuredOutput: return "invalid_structured_output"
        case .invalidRequest: return "invalid_request"
        case .validationFailed: return "validation_failed"
        }
    }

    var isRetryableForFinalAnalysis: Bool {
        switch self {
        case .contextLimitExceeded, .refusal, .invalidRequest, .validationFailed:
            return false
        case .providerError, .incomplete, .malformedResponse, .invalidStructuredOutput:
            return true
        }
    }
}

struct FinalAnalysisResponsePage: Codable, Equatable, Sendable {
    let snapshotID: String
    let triggerTurnID: String
    let complete: Bool
    let questionAnswers: [FinalAnalysisResponseQuestionAnswer]
}

struct FinalAnalysisResponseQuestionAnswer: Codable, Equatable, Sendable {
    let normalizedQuestion: String
    let sourceSpans: [FinalAnalysisResponseSourceSpan]
    let answer: String
    let advice: String
    let usedTurnIDs: [String]
    let usedContextIDs: [UUID]
}

struct FinalAnalysisResponseSourceSpan: Codable, Equatable, Sendable {
    let canonicalTurnID: String
    let exactQuote: String
}

enum FinalAnalysisResponseValidationError: Error, Equatable, Sendable {
    case incompleteTrigger
    case snapshotMismatch(expected: String, actual: String)
    case triggerMismatch(expected: String, actual: String)
    case missingTriggerTurn(String)
    case outgoingTriggerTurn(String)
    case emptyQuestion(pairIndex: Int)
    case emptyAnswer(pairIndex: Int)
    case emptyAdvice(pairIndex: Int)
    case evidenceRequired(pairIndex: Int)
    case evidenceOutsideIncomingTrigger(pairIndex: Int, evidenceIndex: Int)
    case emptyEvidenceQuote(pairIndex: Int, evidenceIndex: Int)
    case quoteNotFound(pairIndex: Int, evidenceIndex: Int)
    case answerTooLong(pairIndex: Int, actual: Int, maximum: Int)
    case adviceTooLong(pairIndex: Int, actual: Int, maximum: Int)
    case unknownUsedTurn(pairIndex: Int, turnID: String)
    case unknownUsedContext(pairIndex: Int, contextID: UUID)
}

struct FinalAnalysisResponseValidator: Sendable {
    func validate(
        _ page: FinalAnalysisResponsePage,
        request: FinalAnalysisProviderRequest
    ) throws -> FinalAnalysisTriggerResult {
        guard page.complete else {
            throw FinalAnalysisResponseValidationError.incompleteTrigger
        }
        guard page.snapshotID == request.snapshot.id else {
            throw FinalAnalysisResponseValidationError.snapshotMismatch(
                expected: request.snapshot.id,
                actual: page.snapshotID
            )
        }
        guard page.triggerTurnID == request.triggerTurnID else {
            throw FinalAnalysisResponseValidationError.triggerMismatch(
                expected: request.triggerTurnID,
                actual: page.triggerTurnID
            )
        }
        guard let trigger = request.snapshot.turns.first(where: {
            $0.id == request.triggerTurnID
        }) else {
            throw FinalAnalysisResponseValidationError.missingTriggerTurn(
                request.triggerTurnID
            )
        }
        guard trigger.track == .incoming else {
            throw FinalAnalysisResponseValidationError.outgoingTriggerTurn(
                request.triggerTurnID
            )
        }

        let knownTurnIDs = Set(request.snapshot.turns.map(\.id))
        let knownContextIDs = Set(
            request.snapshot.frozenContexts.contexts.map(\.sourceContextID)
        )
        let cards = try page.questionAnswers.enumerated().map { pairIndex, pair in
            guard !pair.normalizedQuestion.finalAnalysisTrimmed.isEmpty else {
                throw FinalAnalysisResponseValidationError.emptyQuestion(
                    pairIndex: pairIndex
                )
            }
            guard !pair.answer.finalAnalysisTrimmed.isEmpty else {
                throw FinalAnalysisResponseValidationError.emptyAnswer(
                    pairIndex: pairIndex
                )
            }
            guard !pair.advice.finalAnalysisTrimmed.isEmpty else {
                throw FinalAnalysisResponseValidationError.emptyAdvice(
                    pairIndex: pairIndex
                )
            }
            guard !pair.sourceSpans.isEmpty else {
                throw FinalAnalysisResponseValidationError.evidenceRequired(
                    pairIndex: pairIndex
                )
            }

            let answerWords = pair.answer.finalAnalysisWordCount
            guard answerWords <= request.snapshot.configuration.selectedAnswerMaxWords else {
                throw FinalAnalysisResponseValidationError.answerTooLong(
                    pairIndex: pairIndex,
                    actual: answerWords,
                    maximum: request.snapshot.configuration.selectedAnswerMaxWords
                )
            }
            let adviceWords = pair.advice.finalAnalysisWordCount
            guard adviceWords <= request.snapshot.configuration.adviceMaxWords else {
                throw FinalAnalysisResponseValidationError.adviceTooLong(
                    pairIndex: pairIndex,
                    actual: adviceWords,
                    maximum: request.snapshot.configuration.adviceMaxWords
                )
            }

            for turnID in pair.usedTurnIDs where !knownTurnIDs.contains(turnID) {
                throw FinalAnalysisResponseValidationError.unknownUsedTurn(
                    pairIndex: pairIndex,
                    turnID: turnID
                )
            }
            for contextID in pair.usedContextIDs where !knownContextIDs.contains(contextID) {
                throw FinalAnalysisResponseValidationError.unknownUsedContext(
                    pairIndex: pairIndex,
                    contextID: contextID
                )
            }

            let evidence = try pair.sourceSpans.enumerated().map { evidenceIndex, span in
                guard span.canonicalTurnID == trigger.id else {
                    throw FinalAnalysisResponseValidationError.evidenceOutsideIncomingTrigger(
                        pairIndex: pairIndex,
                        evidenceIndex: evidenceIndex
                    )
                }
                guard !span.exactQuote.isEmpty else {
                    throw FinalAnalysisResponseValidationError.emptyEvidenceQuote(
                        pairIndex: pairIndex,
                        evidenceIndex: evidenceIndex
                    )
                }
                let ranges = Self.unicodeScalarRanges(
                    of: span.exactQuote,
                    in: trigger.text
                )
                guard !ranges.isEmpty else {
                    throw FinalAnalysisResponseValidationError.quoteNotFound(
                        pairIndex: pairIndex,
                        evidenceIndex: evidenceIndex
                    )
                }
                return FinalTranscriptEvidence(
                    canonicalTurnID: trigger.id,
                    exactQuote: span.exactQuote,
                    unicodeScalarRange: ranges.count == 1 ? ranges[0] : nil
                )
            }

            return FinalAnalysisCardDraft(
                normalizedQuestion: pair.normalizedQuestion,
                evidence: evidence,
                answer: pair.answer,
                advice: pair.advice,
                usedCanonicalTurnIDs: pair.usedTurnIDs,
                usedContextIDs: pair.usedContextIDs
            )
        }

        return FinalAnalysisTriggerResult(
            triggerTurnID: trigger.id,
            cards: Self.canonicalCardOrder(cards)
        )
    }

    private static func canonicalCardOrder(
        _ cards: [FinalAnalysisCardDraft]
    ) -> [FinalAnalysisCardDraft] {
        cards.sorted { lhs, rhs in
            let lhsOffset = lhs.evidence.compactMap {
                $0.unicodeScalarRange?.lowerBound
            }.min() ?? Int.max
            let rhsOffset = rhs.evidence.compactMap {
                $0.unicodeScalarRange?.lowerBound
            }.min() ?? Int.max
            if lhsOffset != rhsOffset { return lhsOffset < rhsOffset }
            return lhs.normalizedQuestion < rhs.normalizedQuestion
        }
    }

    private static func unicodeScalarRanges(
        of quote: String,
        in text: String
    ) -> [Range<Int>] {
        let textScalars = Array(text.unicodeScalars)
        let quoteScalars = Array(quote.unicodeScalars)
        guard !quoteScalars.isEmpty, quoteScalars.count <= textScalars.count else {
            return []
        }
        let finalStart = textScalars.count - quoteScalars.count
        return (0...finalStart).compactMap { start in
            let end = start + quoteScalars.count
            return textScalars[start..<end].elementsEqual(quoteScalars)
                ? start..<end
                : nil
        }
    }
}

private extension String {
    var finalAnalysisTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var finalAnalysisWordCount: Int {
        split(whereSeparator: { $0.isWhitespace }).count
    }
}
