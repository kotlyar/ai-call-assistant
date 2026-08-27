import Foundation
import XCTest
@testable import AICallAssistant

final class ReconciliationCoordinatorTests: XCTestCase {
    func testRunningChunkRecoversPendingAndJobCreationIsExactlyOnce() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = makeRequest(callID: Self.restartCallID)
        let chunker = AudioTrackChunker()
        let seed = try makeSeed(request: request, chunker: chunker)

        let firstStore = try ReconciliationJobStore(
            callFolderURL: folder,
            callID: request.callID
        )
        let created = try await firstStore.createIfNeeded(seed: seed)
        let claimed = try await firstStore.claimNextChunk(maximumAttempts: 3)
        let claim = try XCTUnwrap(claimed)
        let attempt = try await firstStore.beginAttempt(
            jobID: claim.jobID,
            chunkID: claim.descriptor.id
        )
        XCTAssertEqual(attempt, 1)

        let reopened = try ReconciliationJobStore(
            callFolderURL: folder,
            callID: request.callID
        )
        let loadedRecovered = await reopened.currentJob()
        let recovered = try XCTUnwrap(loadedRecovered)
        let recoveredChunk = try XCTUnwrap(
            recovered.tracks.flatMap(\.chunks).first(where: {
                $0.id == claim.descriptor.id
            })
        )
        XCTAssertEqual(recovered.status, .pending)
        XCTAssertEqual(recoveredChunk.state, .pending)
        XCTAssertEqual(recoveredChunk.attempts, 1)

        let repeated = try await reopened.createIfNeeded(seed: seed)
        XCTAssertEqual(repeated.id, created.id)
        XCTAssertEqual(repeated.createdAt, created.createdAt)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: reopened.reconciliationFolderURL,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent == "reconciliation-job.json" }.count,
            1
        )
    }

    func testMissingCredentialResumesWithCurrentKeyAndTerminalJobIsIdempotent() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = makeRequest(callID: Self.credentialCallID)
        let credentials = MutableCredentialProvider(key: nil)
        let provider = ScriptedFileTranscriptionProvider(mode: .simple)
        let store = try ReconciliationJobStore(
            callFolderURL: folder,
            callID: request.callID
        )
        let coordinator = ReconciliationCoordinator(
            store: store,
            provider: provider,
            credentialProvider: credentials
        )

        let blocked = try await coordinator.start(request: request)
        let callsWhileBlocked = await provider.totalCalls
        XCTAssertEqual(blocked.status, .blockedByCredential)
        XCTAssertEqual(blocked.attempts, 0)
        XCTAssertEqual(callsWhileBlocked, 0)

        await credentials.setKey("super-secret-current-key")
        let completed = try await coordinator.resume()
        let callsAfterResume = await provider.totalCalls
        let languageHintsAfterResume = await provider.languageHints
        let lookupsAfterResume = await credentials.lookupCount
        XCTAssertEqual(completed.status, .complete)
        XCTAssertEqual(callsAfterResume, 2)
        XCTAssertEqual(languageHintsAfterResume, [["ru", "en"], ["ru", "en"]])
        XCTAssertEqual(lookupsAfterResume, 3)

        let reopenedStore = try ReconciliationJobStore(
            callFolderURL: folder,
            callID: request.callID
        )
        let reopenedCoordinator = ReconciliationCoordinator(
            store: reopenedStore,
            provider: provider,
            credentialProvider: credentials
        )
        let repeated = try await reopenedCoordinator.start(request: request)
        let callsAfterRestart = await provider.totalCalls
        XCTAssertEqual(repeated.id, completed.id)
        XCTAssertEqual(repeated.status, .complete)
        XCTAssertEqual(callsAfterRestart, callsAfterResume)

        let persisted = try String(
            contentsOf: reopenedStore.manifestURL,
            encoding: .utf8
        )
        XCTAssertFalse(persisted.contains("super-secret-current-key"))
    }

    func testMissingTrackProducesIncompleteWithAvailableTrackResult() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let incoming = makeAsset(track: .incoming, callOffset: 50)
        let request = ReconciliationRequest(
            callID: Self.missingTrackCallID,
            modelID: "file-model",
            tracks: [
                ReconciliationTrackInput(track: .incoming, asset: incoming),
                ReconciliationTrackInput(
                    track: .outgoing,
                    asset: nil,
                    missingReason: "missing_source_file"
                )
            ]
        )
        let provider = ScriptedFileTranscriptionProvider(mode: .simple)
        let coordinator = ReconciliationCoordinator(
            store: try ReconciliationJobStore(
                callFolderURL: folder,
                callID: request.callID
            ),
            provider: provider,
            credentialProvider: MutableCredentialProvider(key: "key")
        )

        let job = try await coordinator.start(request: request)
        let result = try XCTUnwrap(job.result)
        let incomingCoverage = try XCTUnwrap(
            result.trackCoverage.first(where: { $0.track == .incoming })
        )
        let outgoingCoverage = try XCTUnwrap(
            result.trackCoverage.first(where: { $0.track == .outgoing })
        )

        XCTAssertEqual(job.status, .incomplete)
        XCTAssertTrue(incomingCoverage.fullyProcessed)
        XCTAssertFalse(outgoingCoverage.fullyProcessed)
        XCTAssertEqual(outgoingCoverage.missingReason, "missing_source_file")
        XCTAssertEqual(result.turns.map(\.track), [.incoming])
    }

    func testCanonicalLastCallFixtureRemovesWholeEchoesAndTrimsMixedOutgoingTurn() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let second: UInt64 = 1_000_000_000
        let request = ReconciliationRequest(
            callID: Self.crossTrackEchoCallID,
            modelID: "gpt-transcribe",
            tracks: AudioTrack.allCases.map { track in
                ReconciliationTrackInput(
                    track: track,
                    asset: makeAsset(
                        track: track,
                        duration: 270 * second,
                        bytes: 1_000
                    )
                )
            }
        )
        let coordinator = ReconciliationCoordinator(
            store: try ReconciliationJobStore(
                callFolderURL: folder,
                callID: request.callID
            ),
            provider: ScriptedFileTranscriptionProvider(mode: .crossTrackEcho),
            credentialProvider: MutableCredentialProvider(key: "key")
        )

        let job = try await coordinator.start(request: request)
        let turns = try XCTUnwrap(job.result).turns
        let incomingTurns = turns.filter { $0.track == .incoming }
        let outgoingTurns = turns.filter { $0.track == .outgoing }

        XCTAssertEqual(job.status, .complete)
        XCTAssertEqual(incomingTurns.map(\.startCallNanoseconds), [
            0,
            210 * second,
            240 * second
        ])
        XCTAssertEqual(incomingTurns.map(\.text), [
            "В чем разница продуктового подхода? Или объясни, что ты понимаешь под этим.",
            "Сколько будет два плюс два?",
            "Почему дублируется фраза от собеседника?"
        ])
        XCTAssertEqual(outgoingTurns.map(\.startCallNanoseconds), [240 * second])
        XCTAssertEqual(outgoingTurns.map(\.text), ["Два плюс два."])
        XCTAssertEqual(
            turns.filter { $0.text.contains("Почему дублируется") }.count,
            1
        )
    }

    func testCanonicalEchoGuardsKeepShortSharedSpeechGenuineOverlapAndLaterRepeat() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = makeRequest(callID: Self.crossTrackEchoGuardsCallID)
        let coordinator = ReconciliationCoordinator(
            store: try ReconciliationJobStore(
                callFolderURL: folder,
                callID: request.callID
            ),
            provider: ScriptedFileTranscriptionProvider(mode: .crossTrackEchoGuards),
            credentialProvider: MutableCredentialProvider(key: "key")
        )

        let job = try await coordinator.start(request: request)
        let turns = try XCTUnwrap(job.result).turns

        XCTAssertEqual(job.status, .complete)
        XCTAssertEqual(turns.filter { $0.text == "Да" }.count, 2)
        XCTAssertEqual(turns.filter { $0.text == "Нет" }.count, 2)
        XCTAssertTrue(turns.contains {
            $0.track == .incoming
                && $0.text == "Обсудим архитектуру сервиса и сроки запуска"
        })
        XCTAssertTrue(turns.contains {
            $0.track == .outgoing
                && $0.text == "Архитектуру сервиса и сроки запуска определит команда"
        })
        XCTAssertEqual(
            turns.filter { $0.text == "Этот вопрос повторится намного позднее" }.count,
            2
        )
    }

    func testPartialRetrySkipsCompletedChunkRestoresClockAndDeduplicatesOverlap() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let incoming = makeAsset(
            track: .incoming,
            duration: 100,
            bytes: 1_000,
            callOffset: 100
        )
        let outgoing = makeAsset(
            track: .outgoing,
            duration: 100,
            bytes: 100,
            callOffset: 1_000
        )
        let request = ReconciliationRequest(
            callID: Self.retryCallID,
            modelID: "file-model",
            tracks: [
                ReconciliationTrackInput(
                    track: .incoming,
                    asset: incoming,
                    preferredSpeechRanges: [
                        AudioSourceRange(startNanoseconds: 0, endNanoseconds: 100)
                    ]
                ),
                ReconciliationTrackInput(
                    track: .outgoing,
                    asset: outgoing,
                    preferredSpeechRanges: [
                        AudioSourceRange(startNanoseconds: 0, endNanoseconds: 100)
                    ]
                )
            ]
        )
        let chunker = AudioTrackChunker(
            maximumUploadBytes: 801,
            overlapNanoseconds: 10,
            preferredBoundaryLookbackNanoseconds: 5,
            minimumCoverageChunkNanoseconds: 1
        )
        let provider = ScriptedFileTranscriptionProvider(mode: .overlapWithRetry)
        let credentials = MutableCredentialProvider(key: "key-v1")
        let store = try ReconciliationJobStore(
            callFolderURL: folder,
            callID: request.callID
        )
        let coordinator = ReconciliationCoordinator(
            store: store,
            provider: provider,
            credentialProvider: credentials,
            chunker: chunker,
            maximumAttemptsPerChunk: 2
        )

        let job = try await coordinator.start(request: request)
        let result = try XCTUnwrap(job.result)
        let incomingChunks = job.tracks
            .first(where: { $0.track == .incoming })?.chunks ?? []
        let incomingTurns = result.turns.filter { $0.track == .incoming }
        let calls = await provider.callsByChunkID
        let credentialLookups = await credentials.lookupCount

        XCTAssertEqual(job.status, .complete)
        XCTAssertEqual(incomingChunks.count, 2)
        XCTAssertEqual(incomingChunks.map(\.attempts), [1, 2])
        XCTAssertEqual(job.attempts, 4)
        XCTAssertEqual(calls[incomingChunks[0].id], 1)
        XCTAssertEqual(calls[incomingChunks[1].id], 2)
        XCTAssertEqual(credentialLookups, 4, "The key must be read for every attempt")
        XCTAssertEqual(incomingTurns.count, 1)
        XCTAssertEqual(incomingTurns[0].text, "hello world again")
        XCTAssertEqual(incomingTurns[0].startCallNanoseconds, 150)
        XCTAssertEqual(incomingTurns[0].endCallNanoseconds, 175)
        XCTAssertEqual(incomingTurns[0].sourceChunkIDs.count, 2)
    }

    func testExplicitRetryUsesFreshPersistedSpendGeneration() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let request = makeRequest(
            callID: Self.explicitSpendRetryCallID,
            modelID: "gpt-transcribe"
        )
        let provider = ScriptedFileTranscriptionProvider(mode: .failsUntilEnabled)
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: request.callID,
            initialLimitUSD: 1
        )
        let firstCoordinator = ReconciliationCoordinator(
            store: try ReconciliationJobStore(
                callFolderURL: folder,
                callID: request.callID
            ),
            provider: provider,
            credentialProvider: MutableCredentialProvider(key: "key"),
            spendAuthorizer: CallSpendReconciliationAuthorizer(ledger: ledger),
            maximumAttemptsPerChunk: 1
        )

        let failed = try await firstCoordinator.start(request: request)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.retryGeneration ?? 0, 0)
        let failedChunkIDs = failed.tracks.flatMap(\.chunks).map(\.id)
        let firstReservationIDs = Set(
            await ledger.currentSnapshot().reservations.map(\.id)
        )
        XCTAssertEqual(
            firstReservationIDs,
            Set(failedChunkIDs.map { "file:\($0):attempt:1" })
        )

        await provider.enableSuccess()
        let reopenedStore = try ReconciliationJobStore(
            callFolderURL: folder,
            callID: request.callID
        )
        let retryCoordinator = ReconciliationCoordinator(
            store: reopenedStore,
            provider: provider,
            credentialProvider: MutableCredentialProvider(key: "key"),
            spendAuthorizer: CallSpendReconciliationAuthorizer(ledger: ledger),
            maximumAttemptsPerChunk: 1
        )
        let completed = try await retryCoordinator.retryFailed()

        XCTAssertEqual(completed.status, .complete)
        XCTAssertEqual(completed.retryGeneration, 1)
        let persistedStore = try ReconciliationJobStore(
            callFolderURL: folder,
            callID: request.callID
        )
        let persistedJob = await persistedStore.currentJob()
        let persisted = try XCTUnwrap(persistedJob)
        XCTAssertEqual(persisted.retryGeneration, 1)
        let allReservationIDs = Set(
            await ledger.currentSnapshot().reservations.map(\.id)
        )
        XCTAssertEqual(
            allReservationIDs,
            firstReservationIDs.union(
                failedChunkIDs.map { "file:\($0):retry:1:attempt:1" }
            )
        )
    }

    func testGptTranscribeCoarseWindowsStayBoundedAndInterleaveAcrossTracks() async throws {
        let folder = temporaryCallFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = ReconciliationRequest(
            callID: Self.coarseTimelineCallID,
            modelID: "gpt-transcribe",
            tracks: [
                ReconciliationTrackInput(
                    track: .incoming,
                    asset: makeAsset(
                        track: .incoming,
                        duration: 130,
                        bytes: 100,
                        callOffset: 0
                    )
                ),
                ReconciliationTrackInput(
                    track: .outgoing,
                    asset: makeAsset(
                        track: .outgoing,
                        duration: 130,
                        bytes: 100,
                        callOffset: 15
                    )
                )
            ]
        )
        let provider = ScriptedFileTranscriptionProvider(mode: .coarseWindows)
        let coordinator = ReconciliationCoordinator(
            store: try ReconciliationJobStore(
                callFolderURL: folder,
                callID: request.callID
            ),
            provider: provider,
            credentialProvider: MutableCredentialProvider(key: "key"),
            chunker: AudioTrackChunker(
                maximumUploadBytes: 1_000,
                maximumCoverageChunkNanoseconds: 60,
                overlapNanoseconds: 10,
                minimumCoverageChunkNanoseconds: 1,
                version: 9
            )
        )

        let job = try await coordinator.start(request: request)
        let turns = try XCTUnwrap(job.result).turns
        let incomingTurns = turns.filter { $0.track == .incoming }
        let outgoingTurns = turns.filter { $0.track == .outgoing }
        let providerCalls = await provider.totalCalls

        XCTAssertEqual(job.status, .complete)
        XCTAssertEqual(providerCalls, 6)
        XCTAssertEqual(turns.map(\.startCallNanoseconds), [0, 15, 60, 75, 120, 135])
        XCTAssertTrue(turns.allSatisfy {
            $0.endCallNanoseconds - $0.startCallNanoseconds <= 60
        })
        XCTAssertEqual(incomingTurns.map(\.text), [
            "incoming-0 overlap",
            "incoming-60 overlap",
            "incoming-120 overlap"
        ])
        XCTAssertEqual(outgoingTurns.map(\.text), [
            "outgoing-0 overlap",
            "outgoing-60 overlap",
            "outgoing-120 overlap"
        ])
        XCTAssertTrue(turns.allSatisfy { $0.sourceChunkIDs.count == 1 })
    }

    private func makeRequest(
        callID: UUID,
        modelID: String = "file-model"
    ) -> ReconciliationRequest {
        ReconciliationRequest(
            callID: callID,
            modelID: modelID,
            languages: ["ru", "en"],
            tracks: AudioTrack.allCases.map { track in
                ReconciliationTrackInput(
                    track: track,
                    asset: makeAsset(track: track)
                )
            }
        )
    }

    private func makeSeed(
        request: ReconciliationRequest,
        chunker: AudioTrackChunker
    ) throws -> ReconciliationJobSeed {
        ReconciliationJobSeed(
            callID: request.callID,
            modelID: request.modelID,
            languages: request.languages,
            chunkerVersion: chunker.version,
            tracks: try request.tracks.map { input in
                let asset = try XCTUnwrap(input.asset)
                return ReconciliationTrackSeed(
                    track: input.track,
                    asset: asset,
                    chunks: try chunker.chunks(
                        callID: request.callID,
                        asset: asset,
                        modelID: request.modelID,
                        preferredSpeechRanges: input.preferredSpeechRanges
                    )
                )
            }
        )
    }

    private func makeAsset(
        track: AudioTrack,
        duration: UInt64 = 100,
        bytes: Int64 = 100,
        callOffset: UInt64 = 0
    ) -> ReconciliationAudioAsset {
        ReconciliationAudioAsset(
            track: track,
            fileURL: URL(fileURLWithPath: "/tmp/\(track.rawValue).m4a"),
            sourceDurationNanoseconds: duration,
            sourceByteCount: bytes,
            sourceSHA256: "\(track.rawValue)-\(duration)-\(bytes)",
            callStartOffsetNanoseconds: callOffset
        )
    }

    private func temporaryCallFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconciliationCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static let restartCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000001"
    )!
    private static let credentialCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000002"
    )!
    private static let missingTrackCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000003"
    )!
    private static let retryCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000004"
    )!
    private static let coarseTimelineCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000005"
    )!
    private static let explicitSpendRetryCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000006"
    )!
    private static let crossTrackEchoCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000007"
    )!
    private static let crossTrackEchoGuardsCallID = UUID(
        uuidString: "72000000-0000-0000-0000-000000000008"
    )!
}

private actor MutableCredentialProvider: ReconciliationCredentialProvider {
    private var key: String?
    private(set) var lookupCount = 0

    init(key: String?) {
        self.key = key
    }

    func setKey(_ key: String?) {
        self.key = key
    }

    func currentAPIKey() async throws -> String? {
        lookupCount += 1
        return key
    }
}

private enum ScriptedProviderFailure: FileTranscriptionFailure {
    case transient

    var reconciliationFailureCode: String { "temporary_provider_failure" }
    var isRetryableForReconciliation: Bool { true }
}

private actor ScriptedFileTranscriptionProvider: FileTranscriptionProvider {
    enum Mode: Sendable {
        case simple
        case overlapWithRetry
        case coarseWindows
        case failsUntilEnabled
        case crossTrackEcho
        case crossTrackEchoGuards
    }

    private let mode: Mode
    private var successEnabled = false
    private(set) var callsByChunkID: [String: Int] = [:]
    private(set) var languageHints: [[String]] = []

    init(mode: Mode) {
        self.mode = mode
    }

    var totalCalls: Int {
        callsByChunkID.values.reduce(0, +)
    }

    func enableSuccess() {
        successEnabled = true
    }

    func transcribe(
        request: FileTranscriptionRequest
    ) async throws -> FileTranscriptionResult {
        callsByChunkID[request.chunk.id, default: 0] += 1
        languageHints.append(request.languages)

        switch mode {
        case .simple:
            return FileTranscriptionResult(
                providerResultID: "simple-\(request.chunk.id)",
                segments: [
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 0,
                        endOffsetNanoseconds: min(
                            10,
                            request.chunk.uploadRange.durationNanoseconds
                        ),
                        text: "\(request.asset.track.rawValue) transcript"
                    )
                ]
            )

        case .crossTrackEcho:
            let second: UInt64 = 1_000_000_000
            let text: String?
            switch (request.asset.track, request.chunk.coverageRange.startNanoseconds) {
            case (.incoming, 0), (.outgoing, 0):
                text = "В чем разница продуктового подхода? Или объясни, что ты понимаешь под этим."
            case (.incoming, 210 * second), (.outgoing, 210 * second):
                text = "Сколько будет два плюс два?"
            case (.incoming, 240 * second):
                text = "Почему дублируется фраза от собеседника?"
            case (.outgoing, 240 * second):
                text = "Два плюс два. Почему дублируется фраза от собеседника?"
            default:
                text = nil
            }
            return FileTranscriptionResult(
                providerResultID: "last-call-\(request.chunk.id)",
                segments: text.map {
                    [
                        FileTranscriptionSegment(
                            startOffsetNanoseconds: 0,
                            endOffsetNanoseconds: request.chunk.uploadRange.durationNanoseconds,
                            text: $0
                        )
                    ]
                } ?? []
            )

        case .crossTrackEchoGuards:
            let segments: [FileTranscriptionSegment]
            switch request.asset.track {
            case .incoming:
                segments = [
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 0,
                        endOffsetNanoseconds: 10,
                        text: "Да"
                    ),
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 20,
                        endOffsetNanoseconds: 30,
                        text: "Нет"
                    ),
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 40,
                        endOffsetNanoseconds: 50,
                        text: "Обсудим архитектуру сервиса и сроки запуска"
                    ),
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 60,
                        endOffsetNanoseconds: 70,
                        text: "Этот вопрос повторится намного позднее"
                    )
                ]
            case .outgoing:
                segments = [
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 0,
                        endOffsetNanoseconds: 10,
                        text: "Да"
                    ),
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 20,
                        endOffsetNanoseconds: 30,
                        text: "Нет"
                    ),
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 40,
                        endOffsetNanoseconds: 50,
                        text: "Архитектуру сервиса и сроки запуска определит команда"
                    ),
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 80,
                        endOffsetNanoseconds: 90,
                        text: "Этот вопрос повторится намного позднее"
                    )
                ]
            }
            return FileTranscriptionResult(
                providerResultID: "echo-guards-\(request.chunk.id)",
                segments: segments
            )

        case .overlapWithRetry:
            if request.asset.track == .outgoing {
                return FileTranscriptionResult(
                    providerResultID: "outgoing",
                    segments: [
                        FileTranscriptionSegment(
                            startOffsetNanoseconds: 0,
                            endOffsetNanoseconds: 10,
                            text: "outgoing reply"
                        )
                    ]
                )
            }

            if request.chunk.coverageRange.startNanoseconds == 0 {
                return FileTranscriptionResult(
                    providerResultID: "incoming-first",
                    segments: [
                        FileTranscriptionSegment(
                            startOffsetNanoseconds: 50,
                            endOffsetNanoseconds: 70,
                            text: "hello world"
                        )
                    ]
                )
            }
            if request.attempt == 1 {
                throw ScriptedProviderFailure.transient
            }
            return FileTranscriptionResult(
                providerResultID: "incoming-second",
                segments: [
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 5,
                        endOffsetNanoseconds: 25,
                        text: "world again"
                    )
                ]
            )

        case .coarseWindows:
            let start = request.chunk.coverageRange.startNanoseconds
            let prefix = start == 0 ? "" : "overlap "
            return FileTranscriptionResult(
                providerResultID: "coarse-\(request.chunk.id)",
                segments: [
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 0,
                        endOffsetNanoseconds: request.chunk.uploadRange.durationNanoseconds,
                        text: "\(prefix)\(request.asset.track.rawValue)-\(start) overlap"
                    )
                ]
            )

        case .failsUntilEnabled:
            guard successEnabled else {
                throw ScriptedProviderFailure.transient
            }
            return FileTranscriptionResult(
                providerResultID: "retried-\(request.chunk.id)",
                segments: [
                    FileTranscriptionSegment(
                        startOffsetNanoseconds: 0,
                        endOffsetNanoseconds: min(
                            10,
                            request.chunk.uploadRange.durationNanoseconds
                        ),
                        text: "\(request.asset.track.rawValue) retried transcript"
                    )
                ]
            )
        }
    }
}
