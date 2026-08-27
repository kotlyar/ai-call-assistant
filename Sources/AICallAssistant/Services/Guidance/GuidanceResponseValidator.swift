import Foundation

struct GuidanceResponsePage: Codable, Equatable, Sendable {
    let snapshotID: String
    let questionAnswers: [GuidanceResponseQuestionAnswer]
}

struct GuidanceResponseQuestionAnswer: Codable, Equatable, Sendable {
    let normalizedQuestion: String
    let sourceSpans: [GuidanceResponseSourceSpan]
    let answer: String
    let advice: String
    let usedTurnIDs: [UUID]
    let usedContextIDs: [UUID]
}

struct GuidanceResponseSourceSpan: Codable, Equatable, Sendable {
    let turnID: UUID
    let turnRevision: Int
    let exactQuote: String
}

struct ValidatedGuidancePage: Equatable, Sendable {
    let snapshotID: String
    let providerSnapshotID: String
    let questionAnswers: [ValidatedGuidanceQuestionAnswer]
}

struct ValidatedGuidanceQuestionAnswer: Equatable, Sendable {
    let normalizedQuestion: String
    let evidence: [QuestionEvidence]
    let answer: String
    let advice: String
    let usedTurnIDs: [UUID]
    let usedContextIDs: [UUID]
}

struct GuidanceResponseValidator: Sendable {
    func validate(
        _ page: GuidanceResponsePage,
        against snapshot: ConversationSnapshot
    ) throws -> ValidatedGuidancePage {
        let turnsByReference = Dictionary(
            uniqueKeysWithValues: snapshot.turns.map { ($0.reference, $0) }
        )
        let triggerSet = Set(snapshot.triggerTurns)
        let knownTurnIDs = Set(snapshot.turns.map(\.reference.turnID))
        let knownContextIDs = Set(
            snapshot.frozenContexts.contexts.map(\.sourceContextID)
        )

        let validated = try page.questionAnswers.enumerated().map { pairIndex, pair in
            guard !pair.normalizedQuestion.trimmedForGuidance.isEmpty else {
                throw GuidanceResponseValidationError.emptyQuestion(pairIndex: pairIndex)
            }
            guard !pair.answer.trimmedForGuidance.isEmpty else {
                throw GuidanceResponseValidationError.emptyAnswer(pairIndex: pairIndex)
            }
            guard !pair.advice.trimmedForGuidance.isEmpty else {
                throw GuidanceResponseValidationError.emptyAdvice(pairIndex: pairIndex)
            }
            guard !pair.sourceSpans.isEmpty else {
                throw GuidanceResponseValidationError.evidenceRequired(pairIndex: pairIndex)
            }

            let answerWordCount = pair.answer.guidanceWordCount
            guard answerWordCount <= snapshot.configuration.selectedAnswerMaxWords else {
                throw GuidanceResponseValidationError.answerTooLong(
                    pairIndex: pairIndex,
                    actual: answerWordCount,
                    maximum: snapshot.configuration.selectedAnswerMaxWords
                )
            }
            let adviceWordCount = pair.advice.guidanceWordCount
            guard adviceWordCount <= snapshot.configuration.adviceMaxWords else {
                throw GuidanceResponseValidationError.adviceTooLong(
                    pairIndex: pairIndex,
                    actual: adviceWordCount,
                    maximum: snapshot.configuration.adviceMaxWords
                )
            }

            for turnID in pair.usedTurnIDs where !knownTurnIDs.contains(turnID) {
                throw GuidanceResponseValidationError.unknownUsedTurn(
                    pairIndex: pairIndex,
                    turnID: turnID
                )
            }
            for contextID in pair.usedContextIDs where !knownContextIDs.contains(contextID) {
                throw GuidanceResponseValidationError.unknownUsedContext(
                    pairIndex: pairIndex,
                    contextID: contextID
                )
            }

            let evidence = try pair.sourceSpans.enumerated().map { evidenceIndex, span in
                let reference = TurnReference(turnID: span.turnID, revision: span.turnRevision)
                guard
                    triggerSet.contains(reference),
                    let turn = turnsByReference[reference],
                    turn.track == .incoming
                else {
                    throw GuidanceResponseValidationError.evidenceOutsideIncomingTrigger(
                        pairIndex: pairIndex,
                        evidenceIndex: evidenceIndex,
                        reference: reference
                    )
                }
                guard !span.exactQuote.isEmpty else {
                    throw GuidanceResponseValidationError.emptyEvidenceQuote(
                        pairIndex: pairIndex,
                        evidenceIndex: evidenceIndex
                    )
                }

                let ranges = Self.unicodeScalarRanges(of: span.exactQuote, in: turn.text)
                guard !ranges.isEmpty else {
                    throw GuidanceResponseValidationError.quoteNotFound(
                        pairIndex: pairIndex,
                        evidenceIndex: evidenceIndex,
                        reference: reference
                    )
                }

                return QuestionEvidence(
                    turn: reference,
                    exactQuote: span.exactQuote,
                    unicodeScalarRange: ranges.count == 1 ? ranges[0] : nil
                )
            }

            return ValidatedGuidanceQuestionAnswer(
                normalizedQuestion: pair.normalizedQuestion,
                evidence: evidence,
                answer: pair.answer,
                advice: pair.advice,
                usedTurnIDs: pair.usedTurnIDs,
                usedContextIDs: pair.usedContextIDs
            )
        }

        return ValidatedGuidancePage(
            snapshotID: snapshot.id,
            providerSnapshotID: page.snapshotID,
            questionAnswers: validated
        )
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
            guard textScalars[start..<end].elementsEqual(quoteScalars) else {
                return nil
            }
            return start..<end
        }
    }
}

enum GuidanceResponseValidationError: Error, Equatable, Sendable {
    case emptyQuestion(pairIndex: Int)
    case emptyAnswer(pairIndex: Int)
    case emptyAdvice(pairIndex: Int)
    case evidenceRequired(pairIndex: Int)
    case evidenceOutsideIncomingTrigger(
        pairIndex: Int,
        evidenceIndex: Int,
        reference: TurnReference
    )
    case emptyEvidenceQuote(pairIndex: Int, evidenceIndex: Int)
    case quoteNotFound(pairIndex: Int, evidenceIndex: Int, reference: TurnReference)
    case answerTooLong(pairIndex: Int, actual: Int, maximum: Int)
    case adviceTooLong(pairIndex: Int, actual: Int, maximum: Int)
    case unknownUsedTurn(pairIndex: Int, turnID: UUID)
    case unknownUsedContext(pairIndex: Int, contextID: UUID)
}

private extension String {
    var trimmedForGuidance: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var guidanceWordCount: Int {
        split(whereSeparator: { $0.isWhitespace }).count
    }
}
