import CryptoKit
import Foundation

enum ConversationContextStoreError: Error, Equatable, Sendable {
    case nonFinalTurn
    case unknownTrigger
    case outgoingTrigger
    case contextLimitReached(estimatedInputTokens: Int, maximumInputTokens: Int)
}

actor ConversationContextStore {
    let callID: UUID
    let frozenContexts: FrozenContextSnapshot
    let configuration: GuidanceConfigurationSnapshot

    private let maximumInputTokens: Int
    private var turnsByID: [UUID: LiveTranscriptTurn] = [:]
    private var conversationRevision: Int64 = 0

    init(
        callID: UUID,
        contexts: [CallContext],
        configuration: GuidanceConfigurationSnapshot,
        frozenAt: Date = Date(),
        maximumInputTokens: Int = 96_000
    ) {
        self.callID = callID
        self.configuration = configuration
        self.maximumInputTokens = maximumInputTokens

        let frozen = contexts
            .filter(\.isSelected)
            .map { context in
                let assistantContextBody = context.assistantContextBody
                return FrozenContext(
                    sourceContextID: context.id,
                    title: context.title,
                    body: assistantContextBody,
                    sourceVersion: nil,
                    contentSHA256: Self.sha256Hex(
                        context.title + "\u{0}" + assistantContextBody
                    )
                )
            }
        let contextIdentity = frozen
            .sorted { $0.sourceContextID.uuidString < $1.sourceContextID.uuidString }
            .map { "\($0.sourceContextID.uuidString):\($0.contentSHA256)" }
            .joined(separator: "|")
        frozenContexts = FrozenContextSnapshot(
            id: "ctx-\(Self.sha256Hex(contextIdentity))",
            frozenAt: frozenAt,
            contexts: frozen
        )
    }

    @discardableResult
    func acceptFinal(_ turn: LiveTranscriptTurn) throws -> Int64 {
        guard turn.state == .liveFinal
                || turn.state == .gap
                || turn.state == .reconciled
                || turn.state == .superseded else {
            throw ConversationContextStoreError.nonFinalTurn
        }
        if let existing = turnsByID[turn.id] {
            if existing.revision > turn.revision { return conversationRevision }
            if existing == turn { return conversationRevision }
        }
        turnsByID[turn.id] = turn
        conversationRevision += 1
        return conversationRevision
    }

    func makeLiveSnapshot(trigger: TurnReference) throws -> ConversationSnapshot {
        guard let triggerTurn = turnsByID[trigger.turnID],
              triggerTurn.revision == trigger.revision else {
            throw ConversationContextStoreError.unknownTrigger
        }
        guard triggerTurn.track == .incoming else {
            throw ConversationContextStoreError.outgoingTrigger
        }

        let triggerEnd = triggerTurn.endCallNanoseconds ?? triggerTurn.startCallNanoseconds
        let turns = turnsByID.values
            .filter { turn in
                turn.state == .liveFinal || turn.state == .gap || turn.state == .reconciled
            }
            .filter { $0.startCallNanoseconds <= triggerEnd }
            .sorted(by: LiveTranscriptTurn.canonicalTimelineOrder)
            .map { turn in
                SnapshotTurn(
                    reference: turn.reference,
                    track: turn.track,
                    startCallNanoseconds: turn.startCallNanoseconds,
                    endCallNanoseconds: turn.endCallNanoseconds,
                    text: turn.text
                )
            }

        let estimatedTokens = Self.conservativeTokenEstimate(
            turns: turns,
            contexts: frozenContexts.contexts,
            outputTokens: configuration.maxOutputTokens
        )
        guard estimatedTokens <= maximumInputTokens else {
            throw ConversationContextStoreError.contextLimitReached(
                estimatedInputTokens: estimatedTokens,
                maximumInputTokens: maximumInputTokens
            )
        }

        let identity = [
            callID.uuidString,
            String(conversationRevision),
            trigger.turnID.uuidString,
            String(trigger.revision),
            frozenContexts.id,
            configuration.id
        ].joined(separator: "|")
        return ConversationSnapshot(
            schemaVersion: 1,
            id: "live-\(Self.sha256Hex(identity))",
            callID: callID,
            conversationRevision: conversationRevision,
            turns: turns,
            triggerTurns: [trigger],
            frozenContexts: frozenContexts,
            configuration: configuration,
            perspective: .livePointInTime
        )
    }

    func allFinalTurns() -> [LiveTranscriptTurn] {
        turnsByID.values
            .filter { $0.state == .liveFinal || $0.state == .reconciled || $0.state == .gap }
            .sorted(by: LiveTranscriptTurn.canonicalTimelineOrder)
    }

    func revision() -> Int64 {
        conversationRevision
    }

    private static func conservativeTokenEstimate(
        turns: [SnapshotTurn],
        contexts: [FrozenContext],
        outputTokens: Int
    ) -> Int {
        let scalarCount = turns.reduce(0) { $0 + $1.text.unicodeScalars.count }
            + contexts.reduce(0) {
                $0 + $1.title.unicodeScalars.count + $1.body.unicodeScalars.count
            }
        // RU text and JSON escaping can be substantially denser than the usual
        // four-characters-per-token rule, so reserve at two scalars per token.
        return scalarCount / 2 + turns.count * 32 + contexts.count * 32 + outputTokens + 1_024
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension GuidanceConfigurationSnapshot {
    static func frozen(
        from configuration: GuidanceConfiguration,
        perCallSpendLimitUSD: Decimal? = nil,
        priceCatalogVersion: String = OpenAIPriceCatalog.current.version
    ) -> GuidanceConfigurationSnapshot {
        let effectiveSpendLimit = perCallSpendLimitUSD ?? configuration.perCallSpendLimitUSD
        let identity = [
            configuration.responsesModelID,
            configuration.realtimeTranscriptionModelID,
            configuration.fileTranscriptionModelID,
            configuration.transcriptionLanguages.joined(separator: ","),
            configuration.answerStyle.rawValue,
            configuration.answerLanguage.rawValue,
            String(configuration.briefAnswerMaxWords),
            String(configuration.detailedAnswerMaxWords),
            String(configuration.adviceMaxWords),
            String(configuration.maxOutputTokens),
            NSDecimalNumber(decimal: effectiveSpendLimit).stringValue,
            priceCatalogVersion
        ].joined(separator: "|")
        let hash = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return GuidanceConfigurationSnapshot(
            id: "cfg-\(hash)",
            responsesModelID: configuration.responsesModelID,
            realtimeTranscriptionModelID: configuration.realtimeTranscriptionModelID,
            fileTranscriptionModelID: configuration.fileTranscriptionModelID,
            transcriptionLanguages: configuration.transcriptionLanguages,
            answerStyle: configuration.answerStyle,
            answerLanguage: configuration.answerLanguage,
            briefAnswerMaxWords: configuration.briefAnswerMaxWords,
            detailedAnswerMaxWords: configuration.detailedAnswerMaxWords,
            adviceMaxWords: configuration.adviceMaxWords,
            maxOutputTokens: configuration.maxOutputTokens,
            initialPerCallSpendLimitUSD: effectiveSpendLimit,
            priceCatalogVersion: priceCatalogVersion,
            modelCapabilityProfileID: "openai-responses-realtime-v1",
            policyVersion: 1
        )
    }
}
