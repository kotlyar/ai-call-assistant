import Foundation

struct TimedTranscriptEvidence: Equatable, Sendable {
    let startCallNanoseconds: UInt64
    let endCallNanoseconds: UInt64?
    let text: String
}

/// Detects the conservative subset of cross-track duplicates that can be
/// attributed to acoustic speaker-to-microphone echo. The system-audio track is
/// the authoritative remote-speaker source; this policy never suppresses it.
///
/// Text alone is not sufficient: people legitimately repeat short words. A
/// candidate must also overlap the incoming source on the shared call clock,
/// may not lead it by more than capture jitter, and must contain enough lexical
/// evidence to avoid acknowledgements such as "да" and "угу".
struct CrossTrackEchoSuppressionPolicy: Equatable, Sendable {
    // The two capture APIs expose different source clocks and each VAD keeps
    // its own preroll. Measured built-in MacBook echo can therefore appear to
    // lead the authoritative system-audio turn by about 0.8 s even though the
    // physical echo is later.
    var maximumOutgoingLeadNanoseconds: UInt64 = 1_250_000_000
    var minimumOutgoingOverlapRatio: Double = 0.35
    var minimumSingleTokenScalarCount = 10
    var minimumMultiTokenScalarCount = 7

    func isProbableEcho(
        outgoing: TimedTranscriptEvidence,
        incoming: [TimedTranscriptEvidence]
    ) -> Bool {
        let outgoingTokens = Self.normalizedTokens(outgoing.text)
        guard hasEnoughLexicalEvidence(outgoingTokens) else { return false }

        let alignedIncoming = incoming
            .filter { isTemporallyAligned(outgoing: outgoing, incoming: $0) }
            .sorted {
                if $0.startCallNanoseconds != $1.startCallNanoseconds {
                    return $0.startCallNanoseconds < $1.startCallNanoseconds
                }
                return ($0.endCallNanoseconds ?? UInt64.max)
                    < ($1.endCallNanoseconds ?? UInt64.max)
            }
        guard !alignedIncoming.isEmpty else { return false }

        for evidence in alignedIncoming {
            let sourceTokens = Self.normalizedTokens(evidence.text)
            if Self.matchesEchoFragment(outgoingTokens, in: sourceTokens) {
                return true
            }
        }

        // Independent VADs can split the same acoustic phrase at different
        // boundaries. Compare against the ordered incoming window as well as
        // one-to-one turns so an outgoing combined/fragmented echo still has a
        // deterministic match.
        let combinedSourceTokens = alignedIncoming.flatMap {
            Self.normalizedTokens($0.text)
        }
        return Self.matchesEchoFragment(outgoingTokens, in: combinedSourceTokens)
    }

    private func isTemporallyAligned(
        outgoing: TimedTranscriptEvidence,
        incoming: TimedTranscriptEvidence
    ) -> Bool {
        guard let outgoingEnd = outgoing.endCallNanoseconds,
              let incomingEnd = incoming.endCallNanoseconds,
              outgoingEnd > outgoing.startCallNanoseconds,
              incomingEnd > incoming.startCallNanoseconds else {
            return false
        }

        if incoming.startCallNanoseconds > outgoing.startCallNanoseconds {
            let lead = incoming.startCallNanoseconds - outgoing.startCallNanoseconds
            guard lead <= maximumOutgoingLeadNanoseconds else { return false }
        }

        let overlapStart = max(outgoing.startCallNanoseconds, incoming.startCallNanoseconds)
        let overlapEnd = min(outgoingEnd, incomingEnd)
        guard overlapEnd > overlapStart else { return false }
        let overlap = overlapEnd - overlapStart
        let outgoingDuration = outgoingEnd - outgoing.startCallNanoseconds
        return Double(overlap) / Double(outgoingDuration) >= minimumOutgoingOverlapRatio
    }

    private func hasEnoughLexicalEvidence(_ tokens: [String]) -> Bool {
        let scalarCount = tokens.reduce(0) { $0 + $1.unicodeScalars.count }
        if tokens.count == 1 {
            return scalarCount >= minimumSingleTokenScalarCount
        }
        return tokens.count >= 2 && scalarCount >= minimumMultiTokenScalarCount
    }

    private static func matchesEchoFragment(
        _ outgoing: [String],
        in incoming: [String]
    ) -> Bool {
        guard !outgoing.isEmpty, !incoming.isEmpty else { return false }
        if outgoing == incoming { return true }
        return containsContiguousTokens(incoming, subsequence: outgoing)
    }

    private static func containsContiguousTokens(
        _ source: [String],
        subsequence: [String]
    ) -> Bool {
        guard subsequence.count <= source.count else { return false }
        if subsequence.count == source.count { return source == subsequence }
        for start in 0...(source.count - subsequence.count) {
            if Array(source[start..<(start + subsequence.count)]) == subsequence {
                return true
            }
        }
        return false
    }

    private static func normalizedTokens(_ text: String) -> [String] {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "ru_RU")
            )
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
