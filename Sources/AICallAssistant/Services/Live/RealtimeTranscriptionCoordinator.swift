import Foundation

enum RealtimeTranscriptionCoordinatorEvent: Equatable, Sendable {
    case trackStatus(AudioTrack, RealtimeTrackStatus)
    case trackFailure(AudioTrack, RealtimeFailureDiagnostic?)
    case transcriptUpdated(LiveTranscriptTurn)
    case trackGap(AudioTrack, startCallNanoseconds: UInt64)
}

struct RealtimeTranscriptionFinalSnapshot: Equatable, Sendable {
    let turns: [LiveTranscriptTurn]
    let conversationRevision: Int64
    let incomingStatus: RealtimeTrackStatus
    let outgoingStatus: RealtimeTrackStatus
    let incomingFailure: RealtimeFailureDiagnostic?
    let outgoingFailure: RealtimeFailureDiagnostic?
}

/// A point-in-time view that is safe to use for live guidance. The coordinator
/// only publishes it after both track actors have ingested audio through the
/// requested cutoff and every locally known turn that started at or before that
/// cutoff has reached a terminal transcript or gap state.
struct RealtimeGuidanceBarrierSnapshot: Equatable, Sendable {
    let cutoffCallNanoseconds: UInt64
    let turns: [LiveTranscriptTurn]
    let conversationRevision: Int64
}

struct RealtimeReconnectPolicy: Equatable, Sendable {
    var backoffNanoseconds: [UInt64]
    var jitterFraction: Double
    var maximumRetryAfterSeconds: Double
    var activeTurnReplayNanoseconds: UInt64
    var fallbackRotationNanoseconds: UInt64
    var rotationLeadSeconds: Int64

    init(
        backoffNanoseconds: [UInt64] = [
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            5_000_000_000,
            10_000_000_000
        ],
        jitterFraction: Double = 0.2,
        maximumRetryAfterSeconds: Double = 60,
        activeTurnReplayNanoseconds: UInt64 = 35_000_000_000,
        fallbackRotationNanoseconds: UInt64 = 50 * 60 * 1_000_000_000,
        rotationLeadSeconds: Int64 = 60
    ) {
        precondition(!backoffNanoseconds.isEmpty)
        precondition((0...1).contains(jitterFraction))
        precondition(maximumRetryAfterSeconds > 0)
        precondition(activeTurnReplayNanoseconds > 0)
        self.backoffNanoseconds = backoffNanoseconds
        self.jitterFraction = jitterFraction
        self.maximumRetryAfterSeconds = maximumRetryAfterSeconds
        self.activeTurnReplayNanoseconds = activeTurnReplayNanoseconds
        self.fallbackRotationNanoseconds = fallbackRotationNanoseconds
        self.rotationLeadSeconds = rotationLeadSeconds
    }

    func retryDelayNanoseconds(attempt: Int, randomUnit: Double) -> UInt64 {
        let index = min(max(0, attempt), backoffNanoseconds.count - 1)
        let base = Double(backoffNanoseconds[index])
        let unit = min(max(randomUnit, 0), 1)
        let jitter = (unit * 2 - 1) * jitterFraction
        return UInt64(max(0, base * (1 + jitter)))
    }

    func retryAfterNanoseconds(_ seconds: Double) -> UInt64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return UInt64(min(seconds, maximumRetryAfterSeconds) * 1_000_000_000)
    }
}

typealias RealtimeSleep = @Sendable (UInt64) async throws -> Void

/// Owns exactly two independent transcription sessions. Capture threads enter
/// only through `offer`, whose bounded queues never await an actor or network.
final class RealtimeTranscriptionCoordinator: @unchecked Sendable {
    private let eventContinuation: AsyncStream<RealtimeTranscriptionCoordinatorEvent>.Continuation
    let events: AsyncStream<RealtimeTranscriptionCoordinatorEvent>

    private let transcriptStore: RealtimeTranscriptStore
    private let incoming: RealtimeTrackIngress
    private let outgoing: RealtimeTrackIngress

    init(
        incomingClient: any RealtimeTranscriptionClientProtocol = OpenAIRealtimeTranscriptionClient(),
        outgoingClient: any RealtimeTranscriptionClientProtocol = OpenAIRealtimeTranscriptionClient(),
        outboundBacklogChunks: Int = 30,
        spendAuthorizer: (any LiveAudioSpendAuthorizer)? = nil,
        reconnectPolicy: RealtimeReconnectPolicy = .init(),
        sleep: @escaping RealtimeSleep = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        nowUnixSeconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        },
        randomUnit: @escaping @Sendable () -> Double = {
            Double.random(in: 0...1)
        }
    ) {
        let pair = AsyncStream<RealtimeTranscriptionCoordinatorEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        events = pair.stream
        eventContinuation = pair.continuation

        let publish: @Sendable (RealtimeTranscriptionCoordinatorEvent) -> Void = {
            pair.continuation.yield($0)
        }
        let transcriptStore = RealtimeTranscriptStore(publish: publish)
        self.transcriptStore = transcriptStore
        incoming = RealtimeTrackIngress(
            track: .incoming,
            capacity: outboundBacklogChunks,
            session: RealtimeTrackSession(
                track: .incoming,
                client: incomingClient,
                transcriptStore: transcriptStore,
                publish: publish,
                spendAuthorizer: spendAuthorizer,
                reconnectPolicy: reconnectPolicy,
                sleep: sleep,
                nowUnixSeconds: nowUnixSeconds,
                randomUnit: randomUnit
            )
        )
        outgoing = RealtimeTrackIngress(
            track: .outgoing,
            capacity: outboundBacklogChunks,
            session: RealtimeTrackSession(
                track: .outgoing,
                client: outgoingClient,
                transcriptStore: transcriptStore,
                publish: publish,
                spendAuthorizer: spendAuthorizer,
                reconnectPolicy: reconnectPolicy,
                sleep: sleep,
                nowUnixSeconds: nowUnixSeconds,
                randomUnit: randomUnit
            )
        )
    }

    func start(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async {
        async let incomingStart: Void = incoming.start(
            apiKey: apiKey,
            configuration: configuration
        )
        async let outgoingStart: Void = outgoing.start(
            apiKey: apiKey,
            configuration: configuration
        )
        _ = await (incomingStart, outgoingStart)
    }

    /// Synchronous and bounded; safe to call from the PCM worker callback.
    func offer(_ chunk: LivePCMChunk) {
        switch chunk.track {
        case .incoming:
            incoming.offer(chunk)
        case .outgoing:
            outgoing.offer(chunk)
        }
    }

    /// Synchronous and ordered with PCM offers from the same track worker.
    /// The ingress actor turns the interval into a terminal transcript gap and
    /// advances the guidance watermark without sending fabricated audio.
    func offer(_ gap: LiveAudioGap) {
        switch gap.track {
        case .incoming:
            incoming.offer(gap)
        case .outgoing:
            outgoing.offer(gap)
        }
    }

    /// Returns `nil` while either track can still add or change context at or
    /// before `cutoffCallNanoseconds`. Callers intentionally retry rather than
    /// guessing a fixed cross-socket completion delay.
    func guidanceSnapshotIfSettled(
        through cutoffCallNanoseconds: UInt64
    ) async -> RealtimeGuidanceBarrierSnapshot? {
        async let incomingSettled = incoming.isSettledForGuidance(
            through: cutoffCallNanoseconds
        )
        async let outgoingSettled = outgoing.isSettledForGuidance(
            through: cutoffCallNanoseconds
        )
        guard await incomingSettled, await outgoingSettled else { return nil }

        let transcript = await transcriptStore.snapshot()
        let terminalTurns = transcript.turns.filter {
            $0.state == .liveFinal || $0.state == .reconciled || $0.state == .gap
        }
        return RealtimeGuidanceBarrierSnapshot(
            cutoffCallNanoseconds: cutoffCallNanoseconds,
            turns: terminalTurns,
            conversationRevision: transcript.revision
        )
    }

    func finish(
        cutoffCallNanoseconds: UInt64,
        finalWaitNanoseconds: UInt64 = 5_000_000_000
    ) async -> RealtimeTranscriptionFinalSnapshot {
        async let incomingStatus = incoming.finish(
            cutoffCallNanoseconds: cutoffCallNanoseconds,
            finalWaitNanoseconds: finalWaitNanoseconds
        )
        async let outgoingStatus = outgoing.finish(
            cutoffCallNanoseconds: cutoffCallNanoseconds,
            finalWaitNanoseconds: finalWaitNanoseconds
        )
        let statuses = await (incomingStatus, outgoingStatus)
        async let incomingFailure = incoming.lastFailure()
        async let outgoingFailure = outgoing.lastFailure()
        let failures = await (incomingFailure, outgoingFailure)
        let transcript = await transcriptStore.snapshot()
        eventContinuation.finish()
        return RealtimeTranscriptionFinalSnapshot(
            turns: transcript.turns,
            conversationRevision: transcript.revision,
            incomingStatus: statuses.0,
            outgoingStatus: statuses.1,
            incomingFailure: failures.0,
            outgoingFailure: failures.1
        )
    }
}

private actor RealtimeTranscriptStore {
    private var reducer = TranscriptReducer()
    private let publish: @Sendable (RealtimeTranscriptionCoordinatorEvent) -> Void

    init(publish: @escaping @Sendable (RealtimeTranscriptionCoordinatorEvent) -> Void) {
        self.publish = publish
    }

    func enqueue(_ pending: PendingLocalTranscriptTurn) {
        reducer.enqueueCommittedLocalTurn(pending)
    }

    func bind(
        track: AudioTrack,
        epoch: Int,
        providerItemID: String
    ) throws -> LiveTranscriptTurn {
        let turn = try reducer.bindNextCommittedItem(
            track: track,
            sessionEpoch: epoch,
            providerItemID: providerItemID
        )
        publish(.transcriptUpdated(turn))
        return turn
    }

    func delta(
        track: AudioTrack,
        epoch: Int,
        providerItemID: String,
        contentIndex: Int,
        text: String
    ) throws {
        let turn = try reducer.applyDelta(
            track: track,
            sessionEpoch: epoch,
            providerItemID: providerItemID,
            contentIndex: contentIndex,
            delta: text
        )
        publish(.transcriptUpdated(turn))
    }

    func complete(
        track: AudioTrack,
        epoch: Int,
        providerItemID: String,
        contentIndex: Int,
        transcript: String
    ) throws {
        let completion = try reducer.applyCompleted(
            track: track,
            sessionEpoch: epoch,
            providerItemID: providerItemID,
            contentIndex: contentIndex,
            transcript: transcript
        )
        for turn in completion.updates {
            publish(.transcriptUpdated(turn))
        }
    }

    func gap(
        id: UUID = UUID(),
        track: AudioTrack,
        start: UInt64,
        end: UInt64? = nil
    ) {
        let turn = reducer.insertGap(
            id: id,
            track: track,
            startCallNanoseconds: start,
            endCallNanoseconds: end
        )
        publish(.trackGap(track, startCallNanoseconds: start))
        publish(.transcriptUpdated(turn))
    }

    func snapshot() -> (turns: [LiveTranscriptTurn], revision: Int64) {
        (reducer.turns, reducer.conversationRevision)
    }
}

private final class RealtimeTrackIngress: @unchecked Sendable {
    private enum Item: Sendable {
        case audio(LivePCMChunk)
        case gap(LiveAudioGap)
    }

    private let track: AudioTrack
    private let capacity: Int
    private let session: RealtimeTrackSession
    private let lock = NSLock()

    private var pending: [Item] = []
    private var drainScheduled = false
    private var accepting = true
    private var forceDiscontinuityOnNext = false
    private var pendingOverflowGapStart: UInt64?
    private var pendingOverflowGapEnd: UInt64?

    init(track: AudioTrack, capacity: Int, session: RealtimeTrackSession) {
        precondition(capacity > 0)
        self.track = track
        self.capacity = capacity
        self.session = session
    }

    func start(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async {
        await session.start(apiKey: apiKey, configuration: configuration)
    }

    func offer(_ original: LivePCMChunk) {
        precondition(original.track == track)
        var shouldSchedule = false
        lock.lock()
        if accepting, pending.count < capacity {
            let chunk: LivePCMChunk
            if forceDiscontinuityOnNext {
                if original.discontinuityBefore {
                    chunk = original
                } else {
                    chunk = LivePCMChunk(
                        track: original.track,
                        sequence: original.sequence,
                        startCallNanoseconds: original.startCallNanoseconds,
                        pcm16LittleEndian: original.pcm16LittleEndian,
                        frameCount: original.frameCount,
                        discontinuityBefore: true
                    )
                }
                forceDiscontinuityOnNext = false
                pendingOverflowGapStart = nil
                pendingOverflowGapEnd = nil
            } else {
                chunk = original
            }
            pending.append(.audio(chunk))
            if !drainScheduled {
                drainScheduled = true
                shouldSchedule = true
            }
        } else if accepting {
            forceDiscontinuityOnNext = true
            pendingOverflowGapStart = pendingOverflowGapStart
                ?? original.startCallNanoseconds
            pendingOverflowGapEnd = max(
                pendingOverflowGapEnd ?? 0,
                original.startCallNanoseconds + original.durationNanoseconds
            )
        }
        lock.unlock()

        if shouldSchedule {
            Task { [weak self] in
                await self?.drainLoop()
            }
        }
    }

    func offer(_ gap: LiveAudioGap) {
        precondition(gap.track == track)
        var shouldSchedule = false
        lock.lock()
        if accepting {
            // Keep at most one coalesced control item beyond the bounded audio
            // backlog so repeated same-outage extensions cannot grow memory
            // without bound if the session actor stalls.
            if case let .gap(existing)? = pending.last {
                pending[pending.count - 1] = .gap(
                    LiveAudioGap(
                        id: existing.id,
                        track: track,
                        startCallNanoseconds: min(
                            existing.startCallNanoseconds,
                            gap.startCallNanoseconds
                        ),
                        endCallNanoseconds: max(
                            existing.endCallNanoseconds,
                            gap.endCallNanoseconds
                        ),
                        reason: existing.reason
                    )
                )
            } else {
                pending.append(.gap(gap))
            }
            if !drainScheduled {
                drainScheduled = true
                shouldSchedule = true
            }
        }
        lock.unlock()

        if shouldSchedule {
            Task { [weak self] in
                await self?.drainLoop()
            }
        }
    }

    func finish(
        cutoffCallNanoseconds: UInt64,
        finalWaitNanoseconds: UInt64
    ) async -> RealtimeTrackStatus {
        lock.withLock {
            accepting = false
        }
        while lock.withLock({ drainScheduled || !pending.isEmpty }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let terminalOverflowGap = lock.withLock {
            let gap = pendingOverflowGapStart.map {
                (
                    start: $0,
                    end: pendingOverflowGapEnd
                        ?? max($0, cutoffCallNanoseconds)
                )
            }
            pendingOverflowGapStart = nil
            pendingOverflowGapEnd = nil
            forceDiscontinuityOnNext = false
            return gap
        }
        if let terminalOverflowGap {
            await session.recordIngressGap(
                start: terminalOverflowGap.start,
                end: terminalOverflowGap.end
            )
        }
        return await session.finish(
            cutoffCallNanoseconds: cutoffCallNanoseconds,
            finalWaitNanoseconds: finalWaitNanoseconds
        )
    }

    func isSettledForGuidance(through cutoffCallNanoseconds: UInt64) async -> Bool {
        await session.isSettledForGuidance(through: cutoffCallNanoseconds)
    }

    func lastFailure() async -> RealtimeFailureDiagnostic? {
        await session.lastFailure()
    }

    private func drainLoop() async {
        while let item = takeNext() {
            switch item {
            case let .audio(chunk):
                await session.ingest(chunk)
            case let .gap(gap):
                await session.recordIngressGap(gap)
            }
        }
    }

    private func takeNext() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else {
            drainScheduled = false
            return nil
        }
        return pending.removeFirst()
    }
}

private actor RealtimeTrackSession {
    private struct ConnectionParameters: Sendable {
        let apiKey: String
        let configuration: RealtimeTranscriptionConfiguration
    }

    private struct ActiveTurnReplay: Sendable {
        let turn: LocalAudioTurn
        var chunks: [LivePCMChunk] = []
        var durationNanoseconds: UInt64 = 0
        var replayable = true
        var requiresReplay: Bool
        var discarded = false
        var gapPublished = false

        mutating func retain(
            _ chunk: LivePCMChunk,
            capacityNanoseconds: UInt64
        ) -> Bool {
            guard !discarded, replayable else { return false }
            chunks.append(chunk)
            durationNanoseconds &+= chunk.durationNanoseconds
            guard durationNanoseconds > capacityNanoseconds else { return false }
            chunks.removeAll(keepingCapacity: false)
            replayable = false
            return requiresReplay
        }
    }

    private let track: AudioTrack
    private let client: any RealtimeTranscriptionClientProtocol
    private let transcriptStore: RealtimeTranscriptStore
    private let publish: @Sendable (RealtimeTranscriptionCoordinatorEvent) -> Void
    private let spendAuthorizer: (any LiveAudioSpendAuthorizer)?
    private let reconnectPolicy: RealtimeReconnectPolicy
    private let sleep: RealtimeSleep
    private let nowUnixSeconds: @Sendable () -> Int64
    private let randomUnit: @Sendable () -> Double

    private var detector: SpeechActivityDetector
    private var parameters: ConnectionParameters?
    private var sessionEpoch = 0
    private var activeConnectionID: UInt64?
    private var connectionReady = false
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var rotationRequested = false
    private var isFinishing = false
    private var isFinished = false

    private var activeTurnReplay: ActiveTurnReplay?
    private var commitInFlight = false
    private var commitPending: PendingLocalTranscriptTurn?
    private var waitingToCommit: [PendingLocalTranscriptTurn] = []
    private var unresolvedProviderItems: [String: LiveTranscriptTurn] = [:]
    private var lastCallNanoseconds: UInt64 = 0
    private var status: RealtimeTrackStatus = .connecting
    private var lastFailureDiagnostic: RealtimeFailureDiagnostic?
    private var hasPermanentGap = false
    private var activeModelID = GuidanceConfigurationDefaults.realtimeTranscriptionModelID
    private var barrierTransitionsInFlight = 0

    init(
        track: AudioTrack,
        client: any RealtimeTranscriptionClientProtocol,
        transcriptStore: RealtimeTranscriptStore,
        publish: @escaping @Sendable (RealtimeTranscriptionCoordinatorEvent) -> Void,
        spendAuthorizer: (any LiveAudioSpendAuthorizer)?,
        reconnectPolicy: RealtimeReconnectPolicy,
        sleep: @escaping RealtimeSleep,
        nowUnixSeconds: @escaping @Sendable () -> Int64,
        randomUnit: @escaping @Sendable () -> Double
    ) {
        self.track = track
        self.client = client
        self.transcriptStore = transcriptStore
        self.publish = publish
        self.spendAuthorizer = spendAuthorizer
        self.reconnectPolicy = reconnectPolicy
        self.sleep = sleep
        self.nowUnixSeconds = nowUnixSeconds
        self.randomUnit = randomUnit
        detector = SpeechActivityDetector(track: track)
    }

    func start(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async {
        // A coordinator is single-use. In particular, a start task that was
        // cancelled before it first ran must not resurrect a session after
        // `finish` has already closed the call.
        guard !isFinishing, !isFinished else { return }
        parameters = ConnectionParameters(apiKey: apiKey, configuration: configuration)
        activeModelID = configuration.modelID
        reconnectAttempt = 0
        lastFailureDiagnostic = nil
        publish(.trackFailure(track, nil))
        startEventConsumerIfNeeded()
        setStatus(.connecting)
        await connectNewEpoch(initial: true)
    }

    func ingest(_ chunk: LivePCMChunk) async {
        barrierTransitionsInFlight += 1
        defer { barrierTransitionsInFlight -= 1 }
        lastCallNanoseconds = max(
            lastCallNanoseconds,
            chunk.startCallNanoseconds + chunk.durationNanoseconds
        )
        let events = detector.consume(chunk)
        await handleSpeechEvents(events)
    }

    func isSettledForGuidance(through cutoffCallNanoseconds: UInt64) -> Bool {
        guard barrierTransitionsInFlight == 0,
              lastCallNanoseconds >= cutoffCallNanoseconds else {
            return false
        }
        if let activeTurnReplay,
           activeTurnReplay.turn.startCallNanoseconds <= cutoffCallNanoseconds {
            return false
        }
        if let commitPending,
           commitPending.startCallNanoseconds <= cutoffCallNanoseconds {
            return false
        }
        if commitInFlight, commitPending == nil {
            // Defensive: an in-flight commit without its local correlation
            // cannot be proven to start after the cutoff.
            return false
        }
        if waitingToCommit.contains(where: {
            $0.startCallNanoseconds <= cutoffCallNanoseconds
        }) {
            return false
        }
        if unresolvedProviderItems.values.contains(where: {
            $0.startCallNanoseconds <= cutoffCallNanoseconds
        }) {
            return false
        }
        return true
    }

    func recordIngressGap(start: UInt64, end: UInt64) async {
        await recordIngressGap(
            LiveAudioGap(
                track: track,
                startCallNanoseconds: start,
                endCallNanoseconds: end,
                reason: .conversionFailure
            )
        )
    }

    func recordIngressGap(_ gap: LiveAudioGap) async {
        precondition(gap.track == track)
        barrierTransitionsInFlight += 1
        defer { barrierTransitionsInFlight -= 1 }
        await handleSpeechEvents(
            detector.resetForGap(atCallNanoseconds: gap.startCallNanoseconds)
        )
        lastCallNanoseconds = max(lastCallNanoseconds, gap.endCallNanoseconds)
        await publishGap(
            id: gap.id,
            start: gap.startCallNanoseconds,
            end: gap.endCallNanoseconds
        )
    }

    func lastFailure() -> RealtimeFailureDiagnostic? {
        lastFailureDiagnostic
    }

    func finish(
        cutoffCallNanoseconds: UInt64,
        finalWaitNanoseconds: UInt64
    ) async -> RealtimeTrackStatus {
        guard !isFinishing, !isFinished else { return status }
        // Close the lifecycle gate before the first suspension. A start task or
        // connect attempt that resumes later can only observe a terminalizing
        // session and must close its transport instead of reviving the socket.
        isFinishing = true
        parameters = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        rotationTask?.cancel()
        rotationTask = nil

        await handleSpeechEvents(
            detector.flush(atCallNanoseconds: max(lastCallNanoseconds, cutoffCallNanoseconds))
        )

        let clock = ContinuousClock()
        let waitDuration = Duration.nanoseconds(Int64(clamping: finalWaitNanoseconds))
        let deadline = clock.now.advanced(by: waitDuration)
        while clock.now < deadline, hasOutstandingFinals {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if hasOutstandingFinals {
            await invalidateOutstandingWork(preserveReplayableActiveTurn: false)
        }
        if status == .connecting || status == .reconnecting {
            hasPermanentGap = true
            setStatus(.degraded)
        }

        isFinished = true
        isFinishing = false
        connectionReady = false
        activeConnectionID = nil
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        return status
    }

    private var hasOutstandingFinals: Bool {
        activeTurnReplay != nil
            || commitInFlight
            || !waitingToCommit.isEmpty
            || !unresolvedProviderItems.isEmpty
    }

    private func startEventConsumerIfNeeded() {
        guard eventTask == nil else { return }
        let signals = client.signals
        eventTask = Task { [weak self] in
            for await signal in signals {
                guard !Task.isCancelled else { return }
                await self?.receive(signal)
            }
        }
    }

    private func connectNewEpoch(initial: Bool) async {
        guard !isFinishing, !isFinished, let parameters else { return }
        sessionEpoch += 1
        setStatus(initial ? .connecting : .reconnecting)

        do {
            let connection = try await client.connect(
                apiKey: parameters.apiKey,
                configuration: parameters.configuration
            )
            guard !isFinishing, !isFinished else {
                await client.disconnect()
                return
            }
            activeConnectionID = connection.id
            connectionReady = true
            reconnectAttempt = 0
            reconnectTask = nil
            scheduleRotation(for: connection)

            if !(await replayActiveTurnIfNeeded(connectionID: connection.id)) {
                return
            }
            setConnectedStatus()
            await sendNextCommitIfPossible()
            await rotateIfAtTurnBoundary()
        } catch {
            guard !isFinishing, !isFinished else {
                await client.disconnect()
                return
            }
            await handleConnectFailure(connectionFailure(from: error))
        }
    }

    private func handleConnectFailure(_ failure: RealtimeConnectionFailure) async {
        recordFailure(failure)
        connectionReady = false
        activeConnectionID = nil
        if failure.isTerminal {
            await terminateForConnectionFailure()
            return
        }
        setStatus(.reconnecting)
        await client.disconnect()
        scheduleReconnect(after: failure)
    }

    private func scheduleReconnect(
        after failure: RealtimeConnectionFailure?,
        immediate: Bool = false
    ) {
        guard !isFinishing, !isFinished, parameters != nil, reconnectTask == nil else {
            return
        }
        let delay: UInt64
        if immediate {
            delay = 0
        } else if let retryAfter = failure?.retryAfterSeconds,
                  let retryDelay = reconnectPolicy.retryAfterNanoseconds(retryAfter) {
            delay = retryDelay
            reconnectAttempt += 1
        } else {
            delay = reconnectPolicy.retryDelayNanoseconds(
                attempt: reconnectAttempt,
                randomUnit: randomUnit()
            )
            reconnectAttempt += 1
        }
        let sleep = self.sleep
        reconnectTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.reconnectTimerFired()
        }
    }

    private func reconnectTimerFired() async {
        guard !isFinishing, !isFinished else { return }
        reconnectTask = nil
        await connectNewEpoch(initial: false)
    }

    private func scheduleRotation(for connection: RealtimeClientConnection) {
        rotationTask?.cancel()
        rotationRequested = false
        let delay: UInt64
        if let expiresAt = connection.expiresAt {
            let seconds = max(
                0,
                expiresAt - reconnectPolicy.rotationLeadSeconds - nowUnixSeconds()
            )
            let maximumSeconds = Int64(UInt64.max / 1_000_000_000)
            delay = UInt64(min(seconds, maximumSeconds)) * 1_000_000_000
        } else {
            delay = reconnectPolicy.fallbackRotationNanoseconds
        }
        let sleep = self.sleep
        let connectionID = connection.id
        rotationTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.rotationDeadlineReached(connectionID: connectionID)
        }
    }

    private func rotationDeadlineReached(connectionID: UInt64) async {
        guard !isFinishing, !isFinished, activeConnectionID == connectionID else { return }
        rotationTask = nil
        rotationRequested = true
        await rotateIfAtTurnBoundary()
    }

    private func rotateIfAtTurnBoundary() async {
        guard !isFinishing,
              rotationRequested,
              connectionReady,
              activeTurnReplay == nil,
              !commitInFlight,
              waitingToCommit.isEmpty,
              unresolvedProviderItems.isEmpty
        else { return }

        rotationRequested = false
        connectionReady = false
        activeConnectionID = nil
        rotationTask?.cancel()
        rotationTask = nil
        setStatus(.reconnecting)
        await client.disconnect()
        scheduleReconnect(after: nil, immediate: true)
    }

    private func handleSpeechEvents(_ events: [SpeechActivityEvent]) async {
        for event in events {
            switch event {
            case let .started(turn, preRoll):
                activeTurnReplay = ActiveTurnReplay(
                    turn: turn,
                    requiresReplay: !connectionReady
                )
                for chunk in preRoll {
                    await retainAndSendActiveChunk(turnID: turn.id, chunk: chunk)
                }

            case let .audio(turnID, chunk):
                await retainAndSendActiveChunk(turnID: turnID, chunk: chunk)

            case let .ended(turnID, end, _):
                guard let replay = activeTurnReplay, replay.turn.id == turnID else { continue }
                activeTurnReplay = nil
                if replay.discarded || replay.requiresReplay || !connectionReady {
                    if !replay.gapPublished {
                        await publishGap(
                            id: replay.turn.id,
                            start: replay.turn.startCallNanoseconds,
                            end: end
                        )
                    }
                } else {
                    waitingToCommit.append(
                        PendingLocalTranscriptTurn(
                            id: replay.turn.id,
                            track: track,
                            sessionEpoch: sessionEpoch,
                            startCallNanoseconds: replay.turn.startCallNanoseconds,
                            endCallNanoseconds: end
                        )
                    )
                    await sendNextCommitIfPossible()
                }
                await rotateIfAtTurnBoundary()

            case let .discontinuity(start):
                await publishGap(start: start, end: nil)
            }
        }
    }

    private func retainAndSendActiveChunk(turnID: UUID, chunk: LivePCMChunk) async {
        guard var replay = activeTurnReplay, replay.turn.id == turnID else { return }
        let overflowedDuringReplay = replay.retain(
            chunk,
            capacityNanoseconds: reconnectPolicy.activeTurnReplayNanoseconds
        )
        activeTurnReplay = replay
        if overflowedDuringReplay {
            await discardActiveTurnAsGap(end: chunk.startCallNanoseconds + chunk.durationNanoseconds)
            return
        }
        guard connectionReady, !replay.requiresReplay, !replay.discarded,
              let connectionID = activeConnectionID else { return }
        _ = await send(chunk, connectionID: connectionID)
    }

    private func replayActiveTurnIfNeeded(connectionID: UInt64) async -> Bool {
        guard var replay = activeTurnReplay, replay.requiresReplay else { return true }
        guard replay.replayable, !replay.discarded else {
            await discardActiveTurnAsGap(end: lastCallNanoseconds)
            return true
        }

        var index = 0
        while activeConnectionID == connectionID, connectionReady {
            guard let current = activeTurnReplay,
                  current.turn.id == replay.turn.id,
                  current.requiresReplay,
                  !current.discarded else {
                return activeConnectionID == connectionID && connectionReady
            }
            guard index < current.chunks.count else { break }
            guard await send(current.chunks[index], connectionID: connectionID) else {
                return false
            }
            index += 1
        }

        guard activeConnectionID == connectionID,
              connectionReady,
              var current = activeTurnReplay,
              current.turn.id == replay.turn.id,
              !current.discarded else { return false }
        current.requiresReplay = false
        activeTurnReplay = current
        replay = current
        return true
    }

    private func send(_ chunk: LivePCMChunk, connectionID: UInt64) async -> Bool {
        do {
            // A socket failure leaves provider acceptance ambiguous. Charge a
            // replay in the new epoch separately so the conservative ledger
            // can never undercount duplicated provider audio.
            try await spendAuthorizer?.reserve(
                chunk: chunk,
                modelID: activeModelID,
                reservationEpoch: sessionEpoch
            )
            guard connectionReady, activeConnectionID == connectionID else { return false }
            try await client.appendPCM16(chunk.pcm16LittleEndian)
            return connectionReady && activeConnectionID == connectionID
        } catch SpendLedgerError.limitExceeded {
            await publishGap(
                start: chunk.startCallNanoseconds,
                end: chunk.startCallNanoseconds + chunk.durationNanoseconds
            )
            await stopForBudgetLimit()
            return false
        } catch {
            await beginReconnect(
                connectionFailure(from: error),
                connectionID: connectionID
            )
            return false
        }
    }

    private func sendNextCommitIfPossible() async {
        guard !commitInFlight,
              !waitingToCommit.isEmpty,
              connectionReady,
              let connectionID = activeConnectionID
        else { return }

        let pending = waitingToCommit.removeFirst()
        commitPending = pending
        commitInFlight = true
        // Publish the local correlation only after the barrier-visible state is
        // installed. Actor reentrancy must not expose a false settled window.
        await transcriptStore.enqueue(pending)
        do {
            try await client.commit(
                eventID: "\(track.rawValue):\(sessionEpoch):\(pending.id.uuidString)"
            )
        } catch {
            await beginReconnect(
                connectionFailure(from: error),
                connectionID: connectionID
            )
        }
    }

    private func receive(_ signal: RealtimeClientSignal) async {
        barrierTransitionsInFlight += 1
        defer { barrierTransitionsInFlight -= 1 }
        guard !isFinished else { return }
        switch signal {
        case let .server(connectionID, event):
            guard connectionID == activeConnectionID else { return }
            await receive(event, connectionID: connectionID, epoch: sessionEpoch)

        case let .connectionFailed(connectionID, failure):
            guard connectionID == activeConnectionID else { return }
            await beginReconnect(failure, connectionID: connectionID)
        }
    }

    private func receive(
        _ event: RealtimeServerEvent,
        connectionID: UInt64,
        epoch: Int
    ) async {
        guard connectionID == activeConnectionID, epoch == sessionEpoch else { return }
        switch event {
        case .sessionUpdated:
            break

        case let .audioCommitted(itemID):
            guard commitInFlight,
                  let pending = commitPending,
                  pending.sessionEpoch == epoch else { return }
            do {
                let turn = try await transcriptStore.bind(
                    track: track,
                    epoch: epoch,
                    providerItemID: itemID
                )
                unresolvedProviderItems["\(itemID):0"] = turn
            } catch {
                await publishGap(
                    id: pending.id,
                    start: pending.startCallNanoseconds,
                    end: pending.endCallNanoseconds
                )
            }
            commitPending = nil
            commitInFlight = false
            await sendNextCommitIfPossible()
            await rotateIfAtTurnBoundary()

        case let .transcriptDelta(itemID, contentIndex, delta):
            try? await transcriptStore.delta(
                track: track,
                epoch: epoch,
                providerItemID: itemID,
                contentIndex: contentIndex,
                text: delta
            )

        case let .transcriptCompleted(itemID, contentIndex, transcript):
            do {
                try await transcriptStore.complete(
                    track: track,
                    epoch: epoch,
                    providerItemID: itemID,
                    contentIndex: contentIndex,
                    transcript: transcript
                )
                unresolvedProviderItems.removeValue(forKey: "\(itemID):\(contentIndex)")
            } catch {
                if let turn = unresolvedProviderItems.removeValue(
                    forKey: "\(itemID):\(contentIndex)"
                ) {
                    await publishGap(
                        id: turn.id,
                        start: turn.startCallNanoseconds,
                        end: turn.endCallNanoseconds
                    )
                }
            }
            await rotateIfAtTurnBoundary()

        case .providerError, .ignored:
            break
        }
    }

    private func beginReconnect(
        _ failure: RealtimeConnectionFailure,
        connectionID: UInt64
    ) async {
        guard connectionID == activeConnectionID, !isFinished else { return }
        recordFailure(failure)
        connectionReady = false
        activeConnectionID = nil
        rotationTask?.cancel()
        rotationTask = nil

        if failure.isTerminal {
            await terminateForConnectionFailure()
            return
        }

        setStatus(.reconnecting)
        await invalidateOutstandingWork(preserveReplayableActiveTurn: true)
        await client.disconnect()
        scheduleReconnect(after: failure)
    }

    private func invalidateOutstandingWork(
        preserveReplayableActiveTurn: Bool
    ) async {
        barrierTransitionsInFlight += 1
        defer { barrierTransitionsInFlight -= 1 }
        var pendingGaps: [PendingLocalTranscriptTurn] = []
        if let commitPending {
            pendingGaps.append(commitPending)
        }
        pendingGaps.append(contentsOf: waitingToCommit)
        commitPending = nil
        commitInFlight = false
        waitingToCommit.removeAll(keepingCapacity: true)

        for pending in pendingGaps {
            await publishGap(
                id: pending.id,
                start: pending.startCallNanoseconds,
                end: pending.endCallNanoseconds
            )
        }
        let unresolved = Array(unresolvedProviderItems.values)
        unresolvedProviderItems.removeAll(keepingCapacity: true)
        for turn in unresolved {
            await publishGap(
                id: turn.id,
                start: turn.startCallNanoseconds,
                end: turn.endCallNanoseconds
            )
        }

        guard var replay = activeTurnReplay else { return }
        if preserveReplayableActiveTurn, replay.replayable, !replay.discarded {
            replay.requiresReplay = true
            activeTurnReplay = replay
        } else {
            replay.discarded = true
            replay.chunks.removeAll(keepingCapacity: false)
            activeTurnReplay = replay
            await discardActiveTurnAsGap(end: lastCallNanoseconds)
        }
    }

    private func discardActiveTurnAsGap(end: UInt64) async {
        guard var replay = activeTurnReplay, !replay.gapPublished else { return }
        replay.discarded = true
        replay.gapPublished = true
        replay.chunks.removeAll(keepingCapacity: false)
        activeTurnReplay = replay
        await publishGap(
            id: replay.turn.id,
            start: replay.turn.startCallNanoseconds,
            end: end
        )
    }

    private func terminateForConnectionFailure() async {
        connectionReady = false
        activeConnectionID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        rotationTask?.cancel()
        rotationTask = nil
        await invalidateOutstandingWork(preserveReplayableActiveTurn: false)
        parameters = nil
        await client.disconnect()
        setStatus(.failed)
    }

    private func stopForBudgetLimit() async {
        connectionReady = false
        activeConnectionID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        rotationTask?.cancel()
        rotationTask = nil
        await invalidateOutstandingWork(preserveReplayableActiveTurn: false)
        parameters = nil
        await client.disconnect()
        setStatus(.budgetStopped)
    }

    private func publishGap(
        id: UUID = UUID(),
        start: UInt64,
        end: UInt64?
    ) async {
        hasPermanentGap = true
        await transcriptStore.gap(
            id: id,
            track: track,
            start: start,
            end: end
        )
        if connectionReady, status != .failed, status != .budgetStopped {
            setStatus(.degraded)
        }
    }

    private func setConnectedStatus() {
        setStatus(hasPermanentGap ? .degraded : .live)
    }

    private func setStatus(_ newStatus: RealtimeTrackStatus) {
        guard status != newStatus else { return }
        status = newStatus
        publish(.trackStatus(track, newStatus))
    }

    private func recordFailure(_ failure: RealtimeConnectionFailure) {
        let diagnostic = failure.diagnostic
        lastFailureDiagnostic = diagnostic
        publish(.trackFailure(track, diagnostic))
    }

    private func connectionFailure(from error: Error) -> RealtimeConnectionFailure {
        if let failure = error as? RealtimeConnectionFailure {
            return failure
        }
        if let clientError = error as? RealtimeClientError,
           case let .connectionFailed(failure) = clientError {
            return failure
        }
        if let transportError = error as? RealtimeTransportError {
            switch transportError {
            case let .httpStatus(statusCode, retryAfterSeconds):
                switch statusCode {
                case 401:
                    return RealtimeConnectionFailure(
                        reason: .authentication,
                        code: "http_401",
                        httpStatus: statusCode
                    )
                case 403:
                    return RealtimeConnectionFailure(
                        reason: .forbidden,
                        code: "http_403",
                        httpStatus: statusCode
                    )
                case 400, 404, 405, 422:
                    return RealtimeConnectionFailure(
                        reason: .invalidConfiguration,
                        code: "invalid_session_configuration",
                        httpStatus: statusCode
                    )
                case 429:
                    return RealtimeConnectionFailure(
                        reason: .rateLimited,
                        code: "http_429",
                        httpStatus: statusCode,
                        retryAfterSeconds: retryAfterSeconds
                    )
                case 500...599:
                    return RealtimeConnectionFailure(
                        reason: .server,
                        code: "server_error",
                        httpStatus: statusCode
                    )
                default:
                    return RealtimeConnectionFailure(
                        reason: .network,
                        code: "transport",
                        httpStatus: statusCode
                    )
                }
            case .invalidEndpoint:
                return RealtimeConnectionFailure(reason: .invalidConfiguration)
            case .unsupportedMessage:
                return RealtimeConnectionFailure(reason: .protocolViolation)
            case .disconnected:
                return RealtimeConnectionFailure(reason: .network)
            case .handshakeTimeout:
                return RealtimeConnectionFailure(
                    reason: .network,
                    code: "handshake_timeout"
                )
            }
        }
        return RealtimeConnectionFailure(reason: .network)
    }
}
