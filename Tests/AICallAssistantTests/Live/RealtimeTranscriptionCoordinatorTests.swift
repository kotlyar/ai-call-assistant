import Foundation
import XCTest
@testable import AICallAssistant

final class RealtimeTranscriptionCoordinatorTests: XCTestCase {
    func testReconnectPolicyCapsBackoffJitterAndRetryAfter() {
        let policy = RealtimeReconnectPolicy(
            backoffNanoseconds: [500, 1_000],
            jitterFraction: 0.2,
            maximumRetryAfterSeconds: 60
        )

        XCTAssertEqual(policy.retryDelayNanoseconds(attempt: 99, randomUnit: 1), 1_200)
        XCTAssertEqual(policy.retryDelayNanoseconds(attempt: 99, randomUnit: 0), 800)
        XCTAssertEqual(policy.retryAfterNanoseconds(300), 60_000_000_000)
    }

    func testCreatesIndependentSessionsAndPreservesTrackSpeakerIdentity() async throws {
        let incoming = FakeTranscriptionClient(transcript: "What is the timeline?")
        let outgoing = FakeTranscriptionClient(transcript: "It is two weeks.")
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        feedUtterance(track: .incoming, startIndex: 0, coordinator: coordinator)
        feedUtterance(track: .outgoing, startIndex: 0, coordinator: coordinator)
        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 1_000_000_000,
            finalWaitNanoseconds: 1_000_000_000
        )

        let finals = snapshot.turns.filter { $0.state == .liveFinal }
        XCTAssertEqual(finals.count, 2)
        XCTAssertEqual(finals.first(where: { $0.track == .incoming })?.text, "What is the timeline?")
        XCTAssertEqual(finals.first(where: { $0.track == .outgoing })?.text, "It is two weeks.")
        let incomingConnects = await incoming.connectCount
        let outgoingConnects = await outgoing.connectCount
        XCTAssertEqual(incomingConnects, 1)
        XCTAssertEqual(outgoingConnects, 1)
    }

    func testSameServerItemIDAcrossSocketsDoesNotCollide() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming", fixedItemID: "same")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing", fixedItemID: "same")
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )
        feedUtterance(track: .incoming, startIndex: 0, coordinator: coordinator)
        feedUtterance(track: .outgoing, startIndex: 0, coordinator: coordinator)

        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 1_000_000_000,
            finalWaitNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(snapshot.turns.filter { $0.state == .liveFinal }.count, 2)
        XCTAssertEqual(Set(snapshot.turns.map(\.track)), Set(AudioTrack.allCases))
    }

    func testOutgoingAcousticEchoIsSupersededWhenFinalsArriveOutOfOrder() async {
        let incoming = FakeTranscriptionClient(
            transcript: "Почему дублируется фраза от",
            automaticallyCompleteTranscripts: false
        )
        let outgoing = FakeTranscriptionClient(transcript: "Фраза от")
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        feedUtterance(track: .outgoing, startIndex: 0, coordinator: coordinator)
        feedUtterance(track: .incoming, startIndex: 0, coordinator: coordinator)
        let incomingCommitPending = await eventually {
            await incoming.pendingTranscriptionCount == 1
        }
        XCTAssertTrue(incomingCommitPending)
        await incoming.completePendingTranscripts()

        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 1_000_000_000,
            finalWaitNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(
            snapshot.turns.first(where: { $0.track == .incoming })?.state,
            .liveFinal
        )
        XCTAssertEqual(
            snapshot.turns.first(where: { $0.track == .outgoing })?.state,
            .superseded
        )
    }

    func testGuidanceBarrierWaitsForActiveAndCommittedTurnThenIncludesCompletion() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming")
        let outgoing = FakeTranscriptionClient(
            transcript: "Answer that must be in context",
            automaticallyCompleteTranscripts: false
        )
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        for index in 0..<2 {
            coordinator.offer(chunk(track: .incoming, index: index, amplitude: 0))
            coordinator.offer(chunk(track: .outgoing, index: index, amplitude: 10_000))
        }
        try? await Task.sleep(for: .milliseconds(20))
        let activeBarrier = await coordinator.guidanceSnapshotIfSettled(
            through: 200_000_000
        )
        XCTAssertNil(activeBarrier, "An outgoing active turn must hold the barrier")

        for index in 2..<8 {
            coordinator.offer(chunk(track: .outgoing, index: index, amplitude: 0))
        }
        let commitPending = await eventually {
            await outgoing.pendingTranscriptionCount == 1
        }
        XCTAssertTrue(commitPending)
        let committedBarrier = await coordinator.guidanceSnapshotIfSettled(
            through: 200_000_000
        )
        XCTAssertNil(committedBarrier, "A committed but unresolved turn must hold the barrier")

        await outgoing.completePendingTranscripts()
        let didSettle = await eventually {
            await coordinator.guidanceSnapshotIfSettled(through: 200_000_000) != nil
        }
        XCTAssertTrue(didSettle)
        let barrier = await coordinator.guidanceSnapshotIfSettled(through: 200_000_000)
        XCTAssertEqual(
            barrier?.turns.first(where: { $0.track == .outgoing })?.text,
            "Answer that must be in context"
        )

        _ = await coordinator.finish(
            cutoffCallNanoseconds: 800_000_000,
            finalWaitNanoseconds: 100_000_000
        )
    }

    func testGuidanceBarrierUsesTerminalGapAfterUnresolvedOutgoingFailure() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming")
        let outgoing = FakeTranscriptionClient(
            transcript: "Never completed",
            automaticallyCompleteTranscripts: false
        )
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )
        for index in 0..<2 {
            coordinator.offer(chunk(track: .incoming, index: index, amplitude: 0))
            coordinator.offer(chunk(track: .outgoing, index: index, amplitude: 10_000))
        }
        for index in 2..<8 {
            coordinator.offer(chunk(track: .outgoing, index: index, amplitude: 0))
        }
        let commitPending = await eventually {
            await outgoing.pendingTranscriptionCount == 1
        }
        XCTAssertTrue(commitPending)
        let unresolvedBarrier = await coordinator.guidanceSnapshotIfSettled(
            through: 200_000_000
        )
        XCTAssertNil(unresolvedBarrier)

        await outgoing.dropCurrent(
            RealtimeConnectionFailure(reason: .authentication)
        )
        let didSettleWithGap = await eventually {
            guard let snapshot = await coordinator.guidanceSnapshotIfSettled(
                through: 200_000_000
            ) else { return false }
            return snapshot.turns.contains {
                $0.track == .outgoing && $0.state == .gap
            }
        }
        XCTAssertTrue(didSettleWithGap)

        _ = await coordinator.finish(
            cutoffCallNanoseconds: 800_000_000,
            finalWaitNanoseconds: 100_000_000
        )
    }

    func testLocalConversionGapAdvancesGuidanceBarrierAndDegradesTrack() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        coordinator.offer(chunk(track: .incoming, index: 0, amplitude: 0))
        coordinator.offer(chunk(track: .incoming, index: 1, amplitude: 0))
        coordinator.offer(
            LiveAudioGap(
                track: .outgoing,
                startCallNanoseconds: 0,
                endCallNanoseconds: 200_000_000,
                reason: .conversionFailure
            )
        )

        let didSettle = await eventually {
            await coordinator.guidanceSnapshotIfSettled(
                through: 200_000_000
            ) != nil
        }
        XCTAssertTrue(didSettle)
        let barrier = await coordinator.guidanceSnapshotIfSettled(
            through: 200_000_000
        )
        XCTAssertTrue(barrier?.turns.contains {
            $0.track == .outgoing
                && $0.state == .gap
                && $0.endCallNanoseconds == 200_000_000
        } == true)

        let final = await coordinator.finish(
            cutoffCallNanoseconds: 200_000_000,
            finalWaitNanoseconds: 100_000_000
        )
        XCTAssertEqual(final.outgoingStatus, .degraded)
    }

    func testLocalConversionGapClosesActiveSpeechBeforeSettlingBarrier() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming")
        let outgoing = FakeTranscriptionClient(transcript: "Partial answer")
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        for index in 0..<3 {
            coordinator.offer(chunk(track: .incoming, index: index, amplitude: 0))
        }
        coordinator.offer(chunk(track: .outgoing, index: 0, amplitude: 10_000))
        coordinator.offer(chunk(track: .outgoing, index: 1, amplitude: 10_000))
        coordinator.offer(
            LiveAudioGap(
                track: .outgoing,
                startCallNanoseconds: 200_000_000,
                endCallNanoseconds: 300_000_000,
                reason: .conversionFailure
            )
        )

        let didSettle = await eventually {
            await coordinator.guidanceSnapshotIfSettled(
                through: 300_000_000
            ) != nil
        }
        XCTAssertTrue(didSettle)
        let barrier = await coordinator.guidanceSnapshotIfSettled(
            through: 300_000_000
        )
        XCTAssertTrue(barrier?.turns.contains {
            $0.track == .outgoing && $0.state == .gap
        } == true)

        _ = await coordinator.finish(
            cutoffCallNanoseconds: 300_000_000,
            finalWaitNanoseconds: 100_000_000
        )
    }

    func testGuidanceBarrierRequiresBothTrackAudioWatermarks() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )
        coordinator.offer(chunk(track: .incoming, index: 0, amplitude: 0))
        coordinator.offer(chunk(track: .incoming, index: 1, amplitude: 0))
        coordinator.offer(chunk(track: .outgoing, index: 0, amplitude: 0))
        try? await Task.sleep(for: .milliseconds(20))

        let oneTrackBehindBarrier = await coordinator.guidanceSnapshotIfSettled(
            through: 200_000_000
        )
        XCTAssertNil(oneTrackBehindBarrier)

        coordinator.offer(chunk(track: .outgoing, index: 1, amplitude: 0))
        let didSettle = await eventually {
            await coordinator.guidanceSnapshotIfSettled(through: 200_000_000) != nil
        }
        XCTAssertTrue(didSettle)
        _ = await coordinator.finish(
            cutoffCallNanoseconds: 200_000_000,
            finalWaitNanoseconds: 100_000_000
        )
    }

    func testFinishGateClosesConnectThatCompletesAfterFinish() async {
        let incoming = GatedConnectTranscriptionClient()
        let outgoing = GatedConnectTranscriptionClient()
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing
        )
        let startTask = Task {
            await coordinator.start(
                apiKey: "unit-test-key",
                configuration: RealtimeTranscriptionConfiguration()
            )
        }
        let bothConnecting = await eventually {
            let incomingCount = await incoming.connectCount
            let outgoingCount = await outgoing.connectCount
            return incomingCount == 1 && outgoingCount == 1
        }
        XCTAssertTrue(bothConnecting)

        _ = await coordinator.finish(
            cutoffCallNanoseconds: 0,
            finalWaitNanoseconds: 0
        )
        await incoming.releaseConnections()
        await outgoing.releaseConnections()
        await startTask.value
        try? await Task.sleep(for: .milliseconds(20))

        let incomingConnects = await incoming.connectCount
        let outgoingConnects = await outgoing.connectCount
        let incomingDisconnects = await incoming.disconnectCount
        let outgoingDisconnects = await outgoing.disconnectCount
        XCTAssertEqual(incomingConnects, 1)
        XCTAssertEqual(outgoingConnects, 1)
        XCTAssertGreaterThanOrEqual(incomingDisconnects, 2)
        XCTAssertGreaterThanOrEqual(outgoingDisconnects, 2)
    }

    func testTerminalOutboundOverflowPublishesExactGapAndDegradesTrack() async {
        let incoming = FakeTranscriptionClient(transcript: "Recovered around overflow")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let spendGate = GatedLiveAudioSpendAuthorizer()
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing,
            outboundBacklogChunks: 1,
            spendAuthorizer: spendGate
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        coordinator.offer(chunk(track: .incoming, index: 0, amplitude: 10_000))
        coordinator.offer(chunk(track: .outgoing, index: 0, amplitude: 0))
        let firstChunksDrained = await eventually {
            await coordinator.guidanceSnapshotIfSettled(through: 100_000_000) != nil
        }
        XCTAssertTrue(firstChunksDrained)

        coordinator.offer(chunk(track: .incoming, index: 1, amplitude: 10_000))
        let sendBlocked = await eventually {
            await spendGate.reservationCount > 0
        }
        XCTAssertTrue(sendBlocked)

        coordinator.offer(chunk(track: .incoming, index: 2, amplitude: 10_000))
        coordinator.offer(chunk(track: .incoming, index: 3, amplitude: 10_000))
        let finishTask = Task {
            await coordinator.finish(
                cutoffCallNanoseconds: 400_000_000,
                finalWaitNanoseconds: 1_000_000_000
            )
        }
        await Task.yield()
        await spendGate.release()
        let snapshot = await finishTask.value

        let terminalGap = snapshot.turns.first {
            $0.track == .incoming
                && $0.state == .gap
                && $0.startCallNanoseconds == 300_000_000
        }
        XCTAssertEqual(terminalGap?.endCallNanoseconds, 400_000_000)
        XCTAssertEqual(snapshot.incomingStatus, .degraded)
    }

    func testNetworkDropReconnectsOnlyAffectedTrackAndReplaysActiveTurn() async {
        let incoming = FakeTranscriptionClient(transcript: "Recovered question")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let coordinator = makeReconnectCoordinator(incoming: incoming, outgoing: outgoing)
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        coordinator.offer(chunk(track: .incoming, index: 0, amplitude: 10_000))
        coordinator.offer(chunk(track: .incoming, index: 1, amplitude: 10_000))
        let appendedBeforeDrop = await eventually {
            await incoming.appendCount(connectionID: 1) >= 2
        }
        XCTAssertTrue(appendedBeforeDrop)

        await incoming.dropCurrent(
            RealtimeConnectionFailure(reason: .network)
        )
        let reconnected = await eventually { await incoming.connectCount >= 2 }
        XCTAssertTrue(reconnected)
        let outgoingConnectsAfterDrop = await outgoing.connectCount
        let replayedChunks = await incoming.appendCount(connectionID: 2)
        XCTAssertEqual(outgoingConnectsAfterDrop, 1)
        XCTAssertGreaterThanOrEqual(replayedChunks, 2)

        for index in 2..<8 {
            coordinator.offer(chunk(track: .incoming, index: index, amplitude: 0))
        }
        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 1_000_000_000,
            finalWaitNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(
            snapshot.turns.first(where: { $0.track == .incoming && $0.state == .liveFinal })?.text,
            "Recovered question"
        )
        let finalIncomingConnects = await incoming.connectCount
        let finalOutgoingConnects = await outgoing.connectCount
        XCTAssertEqual(finalIncomingConnects, 2)
        XCTAssertEqual(finalOutgoingConnects, 1)
    }

    func testLateEventsFromOldConnectionAreIgnored() async {
        let incoming = FakeTranscriptionClient(transcript: "Current epoch")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let coordinator = makeReconnectCoordinator(incoming: incoming, outgoing: outgoing)
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        await incoming.dropCurrent(RealtimeConnectionFailure(reason: .network))
        let reconnected = await eventually { await incoming.connectCount >= 2 }
        XCTAssertTrue(reconnected)
        await incoming.emit(
            .audioCommitted(itemID: "late-old-item"),
            connectionID: 1
        )

        feedUtterance(track: .incoming, startIndex: 0, coordinator: coordinator)
        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 1_000_000_000,
            finalWaitNanoseconds: 1_000_000_000
        )

        XCTAssertFalse(snapshot.turns.contains(where: { $0.state == .gap }))
        XCTAssertEqual(
            snapshot.turns.first(where: { $0.state == .liveFinal })?.text,
            "Current epoch"
        )
    }

    func testReconnectBeyondActiveReplayCapacityCreatesExplicitGap() async {
        let incoming = FakeTranscriptionClient(transcript: "Must not be finalized")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing,
            reconnectPolicy: RealtimeReconnectPolicy(
                backoffNanoseconds: [0],
                jitterFraction: 0,
                activeTurnReplayNanoseconds: 100_000_000,
                fallbackRotationNanoseconds: 3_600_000_000_000,
                rotationLeadSeconds: 60
            ),
            randomUnit: { 0.5 }
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        coordinator.offer(chunk(track: .incoming, index: 0, amplitude: 10_000))
        coordinator.offer(chunk(track: .incoming, index: 1, amplitude: 10_000))
        let activeTurnWasSent = await eventually {
            await incoming.appendCount(connectionID: 1) >= 2
        }
        XCTAssertTrue(activeTurnWasSent)

        await incoming.dropCurrent(RealtimeConnectionFailure(reason: .network))
        let reconnected = await eventually { await incoming.connectCount >= 2 }
        XCTAssertTrue(reconnected)
        for index in 2..<8 {
            coordinator.offer(chunk(track: .incoming, index: index, amplitude: 0))
        }

        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 1_000_000_000,
            finalWaitNanoseconds: 1_000_000_000
        )
        XCTAssertTrue(snapshot.turns.contains(where: {
            $0.track == .incoming && $0.state == .gap
        }))
        XCTAssertFalse(snapshot.turns.contains(where: {
            $0.track == .incoming && $0.state == .liveFinal
        }))
        XCTAssertEqual(snapshot.incomingStatus, .degraded)
    }

    func testAuthenticationFailureIsTerminalWithoutRetryStorm() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let coordinator = makeReconnectCoordinator(incoming: incoming, outgoing: outgoing)
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )

        await incoming.dropCurrent(
            RealtimeConnectionFailure(reason: .authentication)
        )
        try? await Task.sleep(for: .milliseconds(30))
        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 0,
            finalWaitNanoseconds: 10_000_000
        )

        XCTAssertEqual(snapshot.incomingStatus, .failed)
        let incomingConnects = await incoming.connectCount
        let outgoingConnects = await outgoing.connectCount
        XCTAssertEqual(incomingConnects, 1)
        XCTAssertEqual(outgoingConnects, 1)
    }

    func testSanitizedFailureIsPublishedAndIncludedInFinalSnapshot() async {
        let incoming = FakeTranscriptionClient(transcript: "Incoming")
        let outgoing = FakeTranscriptionClient(transcript: "Outgoing")
        let coordinator = makeReconnectCoordinator(incoming: incoming, outgoing: outgoing)
        let failureEvents = Task<[RealtimeFailureDiagnostic], Never> {
            var diagnostics: [RealtimeFailureDiagnostic] = []
            for await event in coordinator.events {
                if case let .trackFailure(.incoming, diagnostic?) = event {
                    diagnostics.append(diagnostic)
                }
            }
            return diagnostics
        }

        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )
        await incoming.dropCurrent(
            RealtimeConnectionFailure(
                reason: .authentication,
                code: "http_401",
                httpStatus: 401
            )
        )
        try? await Task.sleep(for: .milliseconds(30))

        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 0,
            finalWaitNanoseconds: 10_000_000
        )
        let events = await failureEvents.value
        let expected = RealtimeFailureDiagnostic(
            code: "http_401",
            reason: .authentication,
            httpStatus: 401
        )

        XCTAssertEqual(snapshot.incomingStatus, .failed)
        XCTAssertEqual(snapshot.incomingFailure, expected)
        XCTAssertNil(snapshot.outgoingFailure)
        XCTAssertEqual(events.last, expected)
    }

    func testFallbackRotationWaitsForActiveTurnBoundary() async {
        let incoming = FakeTranscriptionClient(
            transcript: "Question before rotation",
            expirations: [nil, 100_000]
        )
        let outgoing = FakeTranscriptionClient(
            transcript: "Outgoing",
            expirations: [nil, 100_000]
        )
        let policy = RealtimeReconnectPolicy(
            backoffNanoseconds: [0],
            jitterFraction: 0,
            activeTurnReplayNanoseconds: 35_000_000_000,
            fallbackRotationNanoseconds: 50_000_000,
            rotationLeadSeconds: 0
        )
        let coordinator = RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing,
            reconnectPolicy: policy,
            nowUnixSeconds: { 1_000 },
            randomUnit: { 0.5 }
        )
        await coordinator.start(
            apiKey: "unit-test-key",
            configuration: RealtimeTranscriptionConfiguration()
        )
        coordinator.offer(chunk(track: .incoming, index: 0, amplitude: 10_000))
        coordinator.offer(chunk(track: .incoming, index: 1, amplitude: 10_000))

        try? await Task.sleep(for: .milliseconds(100))
        let incomingConnectsBeforeBoundary = await incoming.connectCount
        let outgoingConnectsAfterDeadline = await outgoing.connectCount
        XCTAssertEqual(incomingConnectsBeforeBoundary, 1)
        XCTAssertGreaterThanOrEqual(outgoingConnectsAfterDeadline, 2)

        for index in 2..<8 {
            coordinator.offer(chunk(track: .incoming, index: index, amplitude: 0))
        }
        let rotated = await eventually { await incoming.connectCount >= 2 }
        XCTAssertTrue(rotated)

        let snapshot = await coordinator.finish(
            cutoffCallNanoseconds: 1_000_000_000,
            finalWaitNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(snapshot.incomingStatus, .live)
        XCTAssertTrue(snapshot.turns.contains(where: { $0.text == "Question before rotation" }))
    }

    private func makeReconnectCoordinator(
        incoming: FakeTranscriptionClient,
        outgoing: FakeTranscriptionClient
    ) -> RealtimeTranscriptionCoordinator {
        RealtimeTranscriptionCoordinator(
            incomingClient: incoming,
            outgoingClient: outgoing,
            reconnectPolicy: RealtimeReconnectPolicy(
                backoffNanoseconds: [0],
                jitterFraction: 0,
                activeTurnReplayNanoseconds: 35_000_000_000,
                fallbackRotationNanoseconds: 3_600_000_000_000,
                rotationLeadSeconds: 60
            ),
            randomUnit: { 0.5 }
        )
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .nanoseconds(Int64(clamping: timeoutNanoseconds))
        )
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func feedUtterance(
        track: AudioTrack,
        startIndex: Int,
        coordinator: RealtimeTranscriptionCoordinator
    ) {
        for offset in 0..<2 {
            coordinator.offer(chunk(track: track, index: startIndex + offset, amplitude: 10_000))
        }
        for offset in 2..<8 {
            coordinator.offer(chunk(track: track, index: startIndex + offset, amplitude: 0))
        }
    }

    private func chunk(
        track: AudioTrack,
        index: Int,
        amplitude: Int16
    ) -> LivePCMChunk {
        var littleEndian = amplitude.littleEndian
        let word = withUnsafeBytes(of: &littleEndian) { Data($0) }
        var data = Data(capacity: 4_800)
        for _ in 0..<2_400 { data.append(word) }
        return LivePCMChunk(
            track: track,
            sequence: UInt64(index),
            startCallNanoseconds: UInt64(index) * 100_000_000,
            pcm16LittleEndian: data,
            frameCount: 2_400,
            discontinuityBefore: false
        )
    }
}

private actor GatedLiveAudioSpendAuthorizer: LiveAudioSpendAuthorizer {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private(set) var reservationCount = 0

    func reserve(
        chunk: LivePCMChunk,
        modelID: String,
        reservationEpoch: Int
    ) async throws {
        reservationCount += 1
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor FakeTranscriptionClient: RealtimeTranscriptionClientProtocol {
    nonisolated let signals: AsyncStream<RealtimeClientSignal>
    private nonisolated let continuation: AsyncStream<RealtimeClientSignal>.Continuation
    private let transcript: String
    private let fixedItemID: String?
    private let automaticallyCompleteTranscripts: Bool
    private var expirations: [Int64?]
    private(set) var connectCount = 0
    private var commitCount = 0
    private var activeConnectionID: UInt64?
    private var appendCounts: [UInt64: Int] = [:]
    private var pendingTranscriptions: [(connectionID: UInt64, itemID: String)] = []

    init(
        transcript: String,
        fixedItemID: String? = nil,
        expirations: [Int64?] = [],
        automaticallyCompleteTranscripts: Bool = true
    ) {
        self.transcript = transcript
        self.fixedItemID = fixedItemID
        self.automaticallyCompleteTranscripts = automaticallyCompleteTranscripts
        self.expirations = expirations
        let pair = AsyncStream<RealtimeClientSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        signals = pair.stream
        continuation = pair.continuation
    }

    func connect(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async throws -> RealtimeClientConnection {
        connectCount += 1
        let connectionID = UInt64(connectCount)
        activeConnectionID = connectionID
        let expiresAt = expirations.isEmpty ? nil : expirations.removeFirst()
        continuation.yield(
            .server(connectionID: connectionID, .sessionUpdated(expiresAt: expiresAt))
        )
        return RealtimeClientConnection(id: connectionID, expiresAt: expiresAt)
    }

    func appendPCM16(_ data: Data) async throws {
        guard let activeConnectionID else { throw RealtimeTransportError.disconnected }
        appendCounts[activeConnectionID, default: 0] += 1
    }

    func commit(eventID: String) async throws {
        guard let activeConnectionID else { throw RealtimeTransportError.disconnected }
        commitCount += 1
        let itemID = fixedItemID ?? "item-\(commitCount)"
        continuation.yield(
            .server(connectionID: activeConnectionID, .audioCommitted(itemID: itemID))
        )
        continuation.yield(
            .server(
                connectionID: activeConnectionID,
                .transcriptDelta(
                    itemID: itemID,
                    contentIndex: 0,
                    delta: String(transcript.prefix(3))
                )
            )
        )
        if automaticallyCompleteTranscripts {
            publishCompletion(connectionID: activeConnectionID, itemID: itemID)
        } else {
            pendingTranscriptions.append((activeConnectionID, itemID))
        }
    }

    func disconnect() async {
        activeConnectionID = nil
    }

    func dropCurrent(_ failure: RealtimeConnectionFailure) {
        guard let activeConnectionID else { return }
        continuation.yield(
            .connectionFailed(connectionID: activeConnectionID, failure)
        )
    }

    func emit(_ event: RealtimeServerEvent, connectionID: UInt64) {
        continuation.yield(.server(connectionID: connectionID, event))
    }

    var pendingTranscriptionCount: Int {
        pendingTranscriptions.count
    }

    func completePendingTranscripts() {
        let pending = pendingTranscriptions
        pendingTranscriptions.removeAll()
        for item in pending {
            publishCompletion(connectionID: item.connectionID, itemID: item.itemID)
        }
    }

    func appendCount(connectionID: UInt64) -> Int {
        appendCounts[connectionID, default: 0]
    }

    private func publishCompletion(connectionID: UInt64, itemID: String) {
        continuation.yield(
            .server(
                connectionID: connectionID,
                .transcriptCompleted(
                    itemID: itemID,
                    contentIndex: 0,
                    transcript: transcript
                )
            )
        )
    }
}

private actor GatedConnectTranscriptionClient: RealtimeTranscriptionClientProtocol {
    nonisolated let signals: AsyncStream<RealtimeClientSignal>
    private nonisolated let continuation: AsyncStream<RealtimeClientSignal>.Continuation
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init() {
        let pair = AsyncStream<RealtimeClientSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        signals = pair.stream
        continuation = pair.continuation
    }

    func connect(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async throws -> RealtimeClientConnection {
        connectCount += 1
        let connectionID = UInt64(connectCount)
        await withCheckedContinuation { continuation in
            connectionWaiters.append(continuation)
        }
        continuation.yield(
            .server(connectionID: connectionID, .sessionUpdated(expiresAt: nil))
        )
        return RealtimeClientConnection(id: connectionID, expiresAt: nil)
    }

    func appendPCM16(_ data: Data) async throws {}
    func commit(eventID: String) async throws {}

    func disconnect() async {
        disconnectCount += 1
    }

    func releaseConnections() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
