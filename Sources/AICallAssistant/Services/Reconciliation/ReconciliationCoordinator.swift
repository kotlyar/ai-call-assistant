import Foundation

struct ReconciliationTrackInput: Equatable, Sendable {
    let track: AudioTrack
    let asset: ReconciliationAudioAsset?
    let missingReason: String?
    let preferredSpeechRanges: [AudioSourceRange]

    init(
        track: AudioTrack,
        asset: ReconciliationAudioAsset?,
        missingReason: String? = nil,
        preferredSpeechRanges: [AudioSourceRange] = []
    ) {
        self.track = track
        self.asset = asset
        self.missingReason = missingReason
        self.preferredSpeechRanges = preferredSpeechRanges
    }
}

struct ReconciliationRequest: Equatable, Sendable {
    let callID: UUID
    let modelID: String
    let languages: [String]
    let tracks: [ReconciliationTrackInput]

    init(
        callID: UUID,
        modelID: String,
        languages: [String] = [],
        tracks: [ReconciliationTrackInput]
    ) {
        self.callID = callID
        self.modelID = modelID
        self.languages = languages
        self.tracks = tracks
    }
}

protocol ReconciliationCredentialProvider: Sendable {
    /// Implementations must read the current secret on every invocation.
    func currentAPIKey() async throws -> String?
}

struct ReconciliationSpendRequest: Equatable, Sendable {
    let callID: UUID
    let jobID: String
    let chunkID: String
    let modelID: String
    let estimatedUploadBytes: Int64
    let durationNanoseconds: UInt64
    let attempt: Int
    let retryGeneration: Int

    init(
        callID: UUID,
        jobID: String,
        chunkID: String,
        modelID: String,
        estimatedUploadBytes: Int64,
        durationNanoseconds: UInt64,
        attempt: Int,
        retryGeneration: Int = 0
    ) {
        self.callID = callID
        self.jobID = jobID
        self.chunkID = chunkID
        self.modelID = modelID
        self.estimatedUploadBytes = estimatedUploadBytes
        self.durationNanoseconds = durationNanoseconds
        self.attempt = attempt
        self.retryGeneration = retryGeneration
    }
}

protocol ReconciliationSpendAuthorizer: Sendable {
    func authorize(request: ReconciliationSpendRequest) async throws -> Bool
}

struct AllowAllReconciliationSpendAuthorizer: ReconciliationSpendAuthorizer {
    func authorize(request: ReconciliationSpendRequest) async throws -> Bool {
        true
    }
}

enum ReconciliationCoordinatorError: Error, Equatable, Sendable {
    case duplicateTrack(AudioTrack)
    case assetTrackMismatch(expected: AudioTrack, actual: AudioTrack)
    case invalidProviderTimestamp(chunkID: String)
    case timestampOverflow(chunkID: String)
}

actor ReconciliationCoordinator {
    private struct NormalizedToken {
        let value: String
        let sourceRange: Range<String.Index>
    }

    private struct CrossTrackEchoMatch {
        let incomingTurn: ReconciledTranscriptTurn
        let outgoingTokenRange: Range<Int>
        let matchedTokenCount: Int
        let matchedCharacterCount: Int
        let temporalOverlapNanoseconds: UInt64
    }

    // Short agreements and interruptions are too ambiguous to classify as
    // acoustic echo. Both limits must be met before canonical text is changed.
    private static let minimumCrossTrackEchoTokens = 4
    private static let minimumCrossTrackEchoCharacters = 16

    private let store: ReconciliationJobStore
    private let provider: any FileTranscriptionProvider
    private let credentialProvider: any ReconciliationCredentialProvider
    private let spendAuthorizer: any ReconciliationSpendAuthorizer
    private let chunker: AudioTrackChunker
    private let maximumAttemptsPerChunk: Int

    init(
        store: ReconciliationJobStore,
        provider: any FileTranscriptionProvider,
        credentialProvider: any ReconciliationCredentialProvider,
        spendAuthorizer: any ReconciliationSpendAuthorizer = AllowAllReconciliationSpendAuthorizer(),
        chunker: AudioTrackChunker = AudioTrackChunker(),
        maximumAttemptsPerChunk: Int = 3
    ) {
        precondition(maximumAttemptsPerChunk > 0)
        self.store = store
        self.provider = provider
        self.credentialProvider = credentialProvider
        self.spendAuthorizer = spendAuthorizer
        self.chunker = chunker
        self.maximumAttemptsPerChunk = maximumAttemptsPerChunk
    }

    /// Creates the deterministic call job and drives it until it becomes
    /// terminal or is blocked by a missing credential/spend authorization.
    func start(request: ReconciliationRequest) async throws -> ReconciliationStoredJob {
        let seed = try makeSeed(request: request)
        _ = try await store.createIfNeeded(seed: seed)
        return try await processExistingJob()
    }

    /// Re-checks policy and the current key without rebuilding or replacing the
    /// durable job. Completed chunks remain complete.
    func resume() async throws -> ReconciliationStoredJob {
        try await processExistingJob()
    }

    func retryFailed() async throws -> ReconciliationStoredJob {
        try await store.retryFailedJob()
        return try await processExistingJob()
    }

    private func processExistingJob() async throws -> ReconciliationStoredJob {
        guard let initial = await store.currentJob() else {
            throw ReconciliationJobStoreError.noJob
        }
        if Self.isTerminal(initial.status) {
            return initial
        }
        try await store.resumeBlockedJob()

        var forceTerminalFailure = false
        while let claim = try await store.claimNextChunk(
            maximumAttempts: maximumAttemptsPerChunk
        ) {
            let currentKey: String?
            do {
                currentKey = try await credentialProvider.currentAPIKey()
            } catch {
                try await store.blockClaimedChunk(
                    jobID: claim.jobID,
                    chunkID: claim.descriptor.id,
                    status: .blockedByCredential,
                    errorCode: "credential_lookup_failed"
                )
                return try await requiredCurrentJob()
            }
            guard let apiKey = currentKey?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !apiKey.isEmpty else {
                try await store.blockClaimedChunk(
                    jobID: claim.jobID,
                    chunkID: claim.descriptor.id,
                    status: .blockedByCredential,
                    errorCode: "credential_missing"
                )
                return try await requiredCurrentJob()
            }

            let spendRequest = ReconciliationSpendRequest(
                callID: claim.callID,
                jobID: claim.jobID,
                chunkID: claim.descriptor.id,
                modelID: claim.modelID,
                estimatedUploadBytes: claim.descriptor.estimatedUploadBytes,
                durationNanoseconds: claim.descriptor.uploadRange.durationNanoseconds,
                attempt: claim.nextAttempt,
                retryGeneration: claim.retryGeneration
            )
            let authorized: Bool
            do {
                authorized = try await spendAuthorizer.authorize(request: spendRequest)
            } catch {
                try await store.blockClaimedChunk(
                    jobID: claim.jobID,
                    chunkID: claim.descriptor.id,
                    status: .blockedBySpendLimit,
                    errorCode: "spend_authorization_failed"
                )
                return try await requiredCurrentJob()
            }
            guard authorized else {
                try await store.blockClaimedChunk(
                    jobID: claim.jobID,
                    chunkID: claim.descriptor.id,
                    status: .blockedBySpendLimit,
                    errorCode: "spend_limit_reached"
                )
                return try await requiredCurrentJob()
            }

            let attempt = try await store.beginAttempt(
                jobID: claim.jobID,
                chunkID: claim.descriptor.id
            )
            do {
                let providerResult = try await provider.transcribe(
                    request: FileTranscriptionRequest(
                        callID: claim.callID,
                        jobID: claim.jobID,
                        idempotencyKey: claim.descriptor.id,
                        modelID: claim.modelID,
                        languages: claim.languages,
                        asset: claim.asset,
                        chunk: claim.descriptor,
                        attempt: attempt,
                        apiKey: apiKey
                    )
                )
                let result = try makeChunkResult(
                    providerResult,
                    claim: claim
                )
                _ = try await store.markChunkComplete(
                    jobID: claim.jobID,
                    chunkID: claim.descriptor.id,
                    result: result
                )
            } catch {
                if let providerFailure = error as? any FileTranscriptionFailure,
                   providerFailure.reconciliationBlockingReason == .credential {
                    try await store.blockClaimedChunk(
                        jobID: claim.jobID,
                        chunkID: claim.descriptor.id,
                        status: .blockedByCredential,
                        errorCode: providerFailure.reconciliationFailureCode
                    )
                    return try await requiredCurrentJob()
                }
                let failure = Self.classify(error: error)
                try await store.markChunkFailed(
                    jobID: claim.jobID,
                    chunkID: claim.descriptor.id,
                    errorCode: failure.code
                )
                if !failure.retryable {
                    forceTerminalFailure = true
                    break
                }
            }
        }

        return try await finalizeCurrentJob(forceFailure: forceTerminalFailure)
    }

    private func makeSeed(request: ReconciliationRequest) throws -> ReconciliationJobSeed {
        var inputsByTrack: [AudioTrack: ReconciliationTrackInput] = [:]
        for input in request.tracks {
            guard inputsByTrack[input.track] == nil else {
                throw ReconciliationCoordinatorError.duplicateTrack(input.track)
            }
            inputsByTrack[input.track] = input
        }

        let tracks = try AudioTrack.allCases.map { track -> ReconciliationTrackSeed in
            guard let input = inputsByTrack[track], let asset = input.asset else {
                return ReconciliationTrackSeed(
                    track: track,
                    asset: nil,
                    missingReason: inputsByTrack[track]?.missingReason ?? "missing_track"
                )
            }
            guard asset.track == track else {
                throw ReconciliationCoordinatorError.assetTrackMismatch(
                    expected: track,
                    actual: asset.track
                )
            }
            return ReconciliationTrackSeed(
                track: track,
                asset: asset,
                chunks: try chunker.chunks(
                    callID: request.callID,
                    asset: asset,
                    modelID: request.modelID,
                    preferredSpeechRanges: input.preferredSpeechRanges
                )
            )
        }
        return ReconciliationJobSeed(
            callID: request.callID,
            modelID: request.modelID,
            languages: request.languages,
            chunkerVersion: chunker.version,
            tracks: tracks
        )
    }

    private func makeChunkResult(
        _ providerResult: FileTranscriptionResult,
        claim: ClaimedReconciliationChunk
    ) throws -> ReconciliationChunkResult {
        let uploadDuration = claim.descriptor.uploadRange.durationNanoseconds
        let usesCoarseChunkTiming = claim.modelID == "gpt-transcribe"
            && providerResult.segments.count == 1
            && providerResult.segments[0].startOffsetNanoseconds == 0
            && providerResult.segments[0].endOffsetNanoseconds == uploadDuration
        var restored: [ReconciledTranscriptSegment] = []
        for segment in providerResult.segments {
            guard
                segment.endOffsetNanoseconds >= segment.startOffsetNanoseconds,
                segment.endOffsetNanoseconds <= uploadDuration
            else {
                throw ReconciliationCoordinatorError.invalidProviderTimestamp(
                    chunkID: claim.descriptor.id
                )
            }
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let sourceStart: UInt64
            let sourceEnd: UInt64
            if usesCoarseChunkTiming {
                // The text covers the overlapped upload, but gpt-transcribe does
                // not provide timestamps inside it. Assign the text to this
                // chunk's non-overlapping coverage window so adjacent tracks can
                // be merged on a useful, deterministic call clock.
                sourceStart = claim.descriptor.coverageRange.startNanoseconds
                sourceEnd = claim.descriptor.coverageRange.endNanoseconds
            } else {
                sourceStart = try Self.adding(
                    claim.descriptor.uploadRange.startNanoseconds,
                    segment.startOffsetNanoseconds,
                    chunkID: claim.descriptor.id
                )
                sourceEnd = try Self.adding(
                    claim.descriptor.uploadRange.startNanoseconds,
                    segment.endOffsetNanoseconds,
                    chunkID: claim.descriptor.id
                )
            }
            guard sourceEnd <= claim.asset.sourceDurationNanoseconds else {
                throw ReconciliationCoordinatorError.invalidProviderTimestamp(
                    chunkID: claim.descriptor.id
                )
            }
            let callStart = try Self.adding(
                claim.asset.callStartOffsetNanoseconds,
                sourceStart,
                chunkID: claim.descriptor.id
            )
            let callEnd = try Self.adding(
                claim.asset.callStartOffsetNanoseconds,
                sourceEnd,
                chunkID: claim.descriptor.id
            )
            restored.append(ReconciledTranscriptSegment(
                chunkID: claim.descriptor.id,
                track: claim.asset.track,
                sourceStartNanoseconds: sourceStart,
                sourceEndNanoseconds: sourceEnd,
                startCallNanoseconds: callStart,
                endCallNanoseconds: callEnd,
                text: text,
                detectorMiss: !claim.descriptor.vadClassifiedSpeech
            ))
        }
        restored.sort(by: Self.segmentOrder)
        let hash = try ReconciliationStableDigest.hex(providerResult)
        return ReconciliationChunkResult(
            providerResultID: providerResult.providerResultID,
            resultHash: hash,
            segments: restored
        )
    }

    private func finalizeCurrentJob(
        forceFailure: Bool
    ) async throws -> ReconciliationStoredJob {
        let job = try await requiredCurrentJob()
        let hasFailedChunk = job.tracks
            .flatMap(\.chunks)
            .contains { $0.state == .failed }
        let hasMissingTrack = job.tracks.contains { $0.asset == nil }
        let result = try makeCanonicalResult(job: job)
        let status: ReconciliationStatus
        let errorCode: String?
        if forceFailure || hasFailedChunk {
            status = .failed
            errorCode = job.lastErrorCode ?? "chunk_retry_exhausted"
        } else if hasMissingTrack {
            status = .incomplete
            errorCode = "missing_track"
        } else {
            status = .complete
            errorCode = nil
        }
        return try await store.finalize(
            jobID: job.id,
            status: status,
            result: result,
            errorCode: errorCode
        )
    }

    private func makeCanonicalResult(
        job: ReconciliationStoredJob
    ) throws -> ReconciliationCanonicalResult {
        let coverage = job.tracks
            .sorted { Self.trackIndex($0.track) < Self.trackIndex($1.track) }
            .map { track in
                ReconciliationTrackCoverage(
                    track: track.track,
                    sourceDurationNanoseconds: track.asset?.sourceDurationNanoseconds,
                    fullyProcessed: track.asset != nil
                        && track.chunks.allSatisfy { $0.state == .complete }
                        && AudioTrackChunker.hasContinuousCoverage(
                            track.chunks.map(\.descriptor),
                            sourceDurationNanoseconds: track.asset!.sourceDurationNanoseconds
                        ),
                    missingReason: track.missingReason
                )
            }

        var turns: [ReconciledTranscriptTurn] = []
        for track in AudioTrack.allCases {
            let segments = job.tracks
                .first(where: { $0.track == track })?
                .chunks
                .compactMap(\.result)
                .flatMap(\.segments)
                .sorted(by: Self.segmentOrder) ?? []
            turns.append(contentsOf: try Self.deduplicatedTurns(
                segments,
                track: track,
                preserveCoarseChunkWindows: job.modelID == "gpt-transcribe"
            ))
        }
        turns = try Self.removingProbableCrossTrackEchoes(from: turns)
        turns.sort(by: Self.turnOrder)
        return ReconciliationCanonicalResult(
            turns: turns,
            trackCoverage: coverage
        )
    }

    /// Raw per-track audio remains the durable evidence. Canonical publication
    /// only removes outgoing text that the shared-clock/text policy identifies
    /// as speaker output acoustically recaptured by the microphone. Incoming
    /// turns are authoritative and are never changed.
    ///
    /// A positive shared-clock overlap is deliberate here: gpt-transcribe
    /// provides one timestamp for a complete coarse (normally 30 second)
    /// coverage window. The text gate compensates by requiring every normalized
    /// token of the shorter turn to appear contiguously in the longer turn.
    private static func removingProbableCrossTrackEchoes(
        from turns: [ReconciledTranscriptTurn]
    ) throws -> [ReconciledTranscriptTurn] {
        let incomingTurns = turns
            .filter { $0.track == .incoming }
            .sorted(by: turnOrder)
        let outgoingTurns = turns
            .filter { $0.track == .outgoing }
            .sorted(by: turnOrder)

        var result = incomingTurns
        for originalOutgoing in outgoingTurns {
            var outgoing: ReconciledTranscriptTurn? = originalOutgoing
            var consumedIncomingTurnIDs: Set<String> = []

            while let current = outgoing,
                  let match = bestCrossTrackEchoMatch(
                    for: current,
                    incomingTurns: incomingTurns,
                    excludingIncomingTurnIDs: consumedIncomingTurnIDs
                  ) {
                consumedIncomingTurnIDs.insert(match.incomingTurn.id)
                let remainingText = removingTokenRange(
                    match.outgoingTokenRange,
                    from: current.text
                )
                guard !remainingText.isEmpty else {
                    outgoing = nil
                    break
                }
                guard remainingText != current.text else { break }
                outgoing = try replacingText(in: current, with: remainingText)
            }

            if let outgoing {
                result.append(outgoing)
            }
        }
        return result
    }

    private static func bestCrossTrackEchoMatch(
        for outgoingTurn: ReconciledTranscriptTurn,
        incomingTurns: [ReconciledTranscriptTurn],
        excludingIncomingTurnIDs: Set<String>
    ) -> CrossTrackEchoMatch? {
        let outgoingTokens = normalizedTokens(in: outgoingTurn.text)
        guard !outgoingTokens.isEmpty else { return nil }

        var best: CrossTrackEchoMatch?
        for incomingTurn in incomingTurns
        where !excludingIncomingTurnIDs.contains(incomingTurn.id) {
            guard let temporalOverlap = positiveTemporalOverlap(
                incomingTurn,
                outgoingTurn
            ) else { continue }

            let incomingTokens = normalizedTokens(in: incomingTurn.text)
            guard let outgoingRange = containedShorterSequenceRange(
                incomingTokens: incomingTokens,
                outgoingTokens: outgoingTokens
            ) else { continue }

            let matchedTokens = outgoingTokens[outgoingRange]
            let matchedCharacterCount = matchedTokens.reduce(0) {
                $0 + $1.value.count
            }
            guard matchedTokens.count >= minimumCrossTrackEchoTokens,
                  matchedCharacterCount >= minimumCrossTrackEchoCharacters
            else { continue }

            let candidate = CrossTrackEchoMatch(
                incomingTurn: incomingTurn,
                outgoingTokenRange: outgoingRange,
                matchedTokenCount: matchedTokens.count,
                matchedCharacterCount: matchedCharacterCount,
                temporalOverlapNanoseconds: temporalOverlap
            )
            if best.map({ isPreferredEchoMatch(candidate, over: $0) }) ?? true {
                best = candidate
            }
        }
        return best
    }

    private static func isPreferredEchoMatch(
        _ lhs: CrossTrackEchoMatch,
        over rhs: CrossTrackEchoMatch
    ) -> Bool {
        if lhs.matchedTokenCount != rhs.matchedTokenCount {
            return lhs.matchedTokenCount > rhs.matchedTokenCount
        }
        if lhs.matchedCharacterCount != rhs.matchedCharacterCount {
            return lhs.matchedCharacterCount > rhs.matchedCharacterCount
        }
        if lhs.temporalOverlapNanoseconds != rhs.temporalOverlapNanoseconds {
            return lhs.temporalOverlapNanoseconds > rhs.temporalOverlapNanoseconds
        }
        if lhs.incomingTurn.startCallNanoseconds
            != rhs.incomingTurn.startCallNanoseconds {
            return lhs.incomingTurn.startCallNanoseconds
                < rhs.incomingTurn.startCallNanoseconds
        }
        if lhs.incomingTurn.id != rhs.incomingTurn.id {
            return lhs.incomingTurn.id < rhs.incomingTurn.id
        }
        return lhs.outgoingTokenRange.lowerBound < rhs.outgoingTokenRange.lowerBound
    }

    /// A match is accepted only when the complete shorter utterance is a
    /// normalized contiguous sequence in the longer one. Arbitrary common
    /// substrings therefore cannot erase genuine overlapping speech.
    private static func containedShorterSequenceRange(
        incomingTokens: [NormalizedToken],
        outgoingTokens: [NormalizedToken]
    ) -> Range<Int>? {
        guard !incomingTokens.isEmpty, !outgoingTokens.isEmpty else { return nil }
        if incomingTokens.count <= outgoingTokens.count {
            return firstOccurrence(
                needle: incomingTokens.map(\.value),
                haystack: outgoingTokens.map(\.value)
            )
        }
        guard firstOccurrence(
            needle: outgoingTokens.map(\.value),
            haystack: incomingTokens.map(\.value)
        ) != nil else { return nil }
        return outgoingTokens.startIndex..<outgoingTokens.endIndex
    }

    private static func firstOccurrence(
        needle: [String],
        haystack: [String]
    ) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let lastStart = haystack.count - needle.count
        for start in 0...lastStart {
            let end = start + needle.count
            if Array(haystack[start..<end]) == needle {
                return start..<end
            }
        }
        return nil
    }

    private static func normalizedTokens(in text: String) -> [NormalizedToken] {
        var result: [NormalizedToken] = []
        var tokenStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if tokenStart == nil { tokenStart = index }
            } else if let start = tokenStart {
                appendNormalizedToken(
                    source: text,
                    range: start..<index,
                    to: &result
                )
                tokenStart = nil
            }
            index = text.index(after: index)
        }
        if let start = tokenStart {
            appendNormalizedToken(
                source: text,
                range: start..<text.endIndex,
                to: &result
            )
        }
        return result
    }

    private static func appendNormalizedToken(
        source: String,
        range: Range<String.Index>,
        to tokens: inout [NormalizedToken]
    ) {
        let value = String(source[range])
            .lowercased()
            .precomposedStringWithCanonicalMapping
        guard !value.isEmpty else { return }
        tokens.append(NormalizedToken(value: value, sourceRange: range))
    }

    private static func removingTokenRange(
        _ range: Range<Int>,
        from text: String
    ) -> String {
        let tokens = normalizedTokens(in: text)
        guard range.lowerBound >= tokens.startIndex,
              range.upperBound <= tokens.endIndex,
              !range.isEmpty else { return text }

        var prefix = String(text[..<tokens[range.lowerBound].sourceRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = prefix.last, isOpeningBoundaryPunctuation(last) {
            prefix.removeLast()
            prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let suffix: String
        if range.upperBound < tokens.endIndex {
            suffix = String(text[tokens[range.upperBound].sourceRange.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            suffix = ""
        }

        if prefix.isEmpty { return suffix }
        if suffix.isEmpty { return prefix }
        return "\(prefix) \(suffix)"
    }

    private static func isOpeningBoundaryPunctuation(_ character: Character) -> Bool {
        "([{«“‘\"".contains(character)
    }

    private static func positiveTemporalOverlap(
        _ lhs: ReconciledTranscriptTurn,
        _ rhs: ReconciledTranscriptTurn
    ) -> UInt64? {
        let start = max(lhs.startCallNanoseconds, rhs.startCallNanoseconds)
        let end = min(lhs.endCallNanoseconds, rhs.endCallNanoseconds)
        guard end > start else { return nil }
        return end - start
    }

    private static func replacingText(
        in turn: ReconciledTranscriptTurn,
        with text: String
    ) throws -> ReconciledTranscriptTurn {
        struct Identity: Encodable {
            let track: String
            let start: UInt64
            let end: UInt64
            let text: String
            let chunks: [String]
        }
        let identity = Identity(
            track: turn.track.rawValue,
            start: turn.startCallNanoseconds,
            end: turn.endCallNanoseconds,
            text: text,
            chunks: turn.sourceChunkIDs
        )
        return ReconciledTranscriptTurn(
            id: "reconciled-turn-v1_\(try ReconciliationStableDigest.hex(identity))",
            track: turn.track,
            startCallNanoseconds: turn.startCallNanoseconds,
            endCallNanoseconds: turn.endCallNanoseconds,
            text: text,
            detectorMiss: turn.detectorMiss,
            sourceChunkIDs: turn.sourceChunkIDs
        )
    }

    private static func deduplicatedTurns(
        _ segments: [ReconciledTranscriptSegment],
        track: AudioTrack,
        preserveCoarseChunkWindows: Bool
    ) throws -> [ReconciledTranscriptTurn] {
        struct Draft {
            var start: UInt64
            var end: UInt64
            var text: String
            var detectorMiss: Bool
            var chunkIDs: [String]
        }

        var drafts: [Draft] = []
        for segment in segments where segment.track == track {
            var nextText = segment.text
            if var previous = drafts.last,
               previous.end >= segment.startCallNanoseconds {
                let overlap = tokenOverlap(previous.text, segment.text)
                if overlap > 0 {
                    let nextTokens = segment.text.split(whereSeparator: \.isWhitespace)
                    let suffix = nextTokens.dropFirst(overlap).joined(separator: " ")
                    if preserveCoarseChunkWindows {
                        // Keep one bounded turn per coarse timing window while
                        // removing the exact text repeated by upload overlap.
                        guard !suffix.isEmpty else { continue }
                        nextText = suffix
                    } else {
                        if !suffix.isEmpty {
                            previous.text += " " + suffix
                        }
                        previous.end = max(previous.end, segment.endCallNanoseconds)
                        previous.detectorMiss = previous.detectorMiss || segment.detectorMiss
                        previous.chunkIDs = Array(
                            Set(previous.chunkIDs + [segment.chunkID])
                        ).sorted()
                        drafts[drafts.count - 1] = previous
                        continue
                    }
                }
            }
            drafts.append(Draft(
                start: segment.startCallNanoseconds,
                end: segment.endCallNanoseconds,
                text: nextText,
                detectorMiss: segment.detectorMiss,
                chunkIDs: [segment.chunkID]
            ))
        }

        return try drafts.map { draft in
            struct Identity: Encodable {
                let track: String
                let start: UInt64
                let end: UInt64
                let text: String
                let chunks: [String]
            }
            let identity = Identity(
                track: track.rawValue,
                start: draft.start,
                end: draft.end,
                text: draft.text,
                chunks: draft.chunkIDs
            )
            return ReconciledTranscriptTurn(
                id: "reconciled-turn-v1_\(try ReconciliationStableDigest.hex(identity))",
                track: track,
                startCallNanoseconds: draft.start,
                endCallNanoseconds: draft.end,
                text: draft.text,
                detectorMiss: draft.detectorMiss,
                sourceChunkIDs: draft.chunkIDs
            )
        }
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(whereSeparator: \.isWhitespace)
        let right = rhs.split(whereSeparator: \.isWhitespace)
        let limit = min(left.count, right.count)
        guard limit > 0 else { return 0 }
        for count in stride(from: limit, through: 1, by: -1) {
            let leftSuffix = left.suffix(count).map {
                $0.lowercased()
            }
            let rightPrefix = right.prefix(count).map {
                $0.lowercased()
            }
            if leftSuffix == rightPrefix {
                return count
            }
        }
        return 0
    }

    private static func adding(
        _ lhs: UInt64,
        _ rhs: UInt64,
        chunkID: String
    ) throws -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw ReconciliationCoordinatorError.timestampOverflow(chunkID: chunkID)
        }
        return sum
    }

    private static func classify(error: Error) -> (code: String, retryable: Bool) {
        if let failure = error as? any FileTranscriptionFailure {
            return (
                failure.reconciliationFailureCode,
                failure.isRetryableForReconciliation
            )
        }
        if error is ReconciliationCoordinatorError {
            return ("invalid_provider_result", false)
        }
        return ("provider_failure", true)
    }

    private func requiredCurrentJob() async throws -> ReconciliationStoredJob {
        guard let job = await store.currentJob() else {
            throw ReconciliationJobStoreError.noJob
        }
        return job
    }

    private static func isTerminal(_ status: ReconciliationStatus) -> Bool {
        status == .complete || status == .incomplete || status == .failed
    }

    private static func segmentOrder(
        _ lhs: ReconciledTranscriptSegment,
        _ rhs: ReconciledTranscriptSegment
    ) -> Bool {
        if lhs.startCallNanoseconds != rhs.startCallNanoseconds {
            return lhs.startCallNanoseconds < rhs.startCallNanoseconds
        }
        if lhs.endCallNanoseconds != rhs.endCallNanoseconds {
            return lhs.endCallNanoseconds < rhs.endCallNanoseconds
        }
        if lhs.chunkID != rhs.chunkID { return lhs.chunkID < rhs.chunkID }
        return lhs.text < rhs.text
    }

    private static func turnOrder(
        _ lhs: ReconciledTranscriptTurn,
        _ rhs: ReconciledTranscriptTurn
    ) -> Bool {
        if lhs.startCallNanoseconds != rhs.startCallNanoseconds {
            return lhs.startCallNanoseconds < rhs.startCallNanoseconds
        }
        if lhs.track != rhs.track {
            return trackIndex(lhs.track) < trackIndex(rhs.track)
        }
        return lhs.id < rhs.id
    }

    private static func trackIndex(_ track: AudioTrack) -> Int {
        switch track {
        case .incoming: return 0
        case .outgoing: return 1
        }
    }
}
