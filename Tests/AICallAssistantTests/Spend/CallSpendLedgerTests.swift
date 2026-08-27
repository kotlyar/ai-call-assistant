import Foundation
import XCTest
@testable import AICallAssistant

final class CallSpendLedgerTests: XCTestCase {
    func testConcurrentReservationsCannotOvershootHardLimit() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let callID = UUID()
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: callID,
            initialLimitUSD: Decimal(string: "0.00005")!
        )
        let first = Self.chunk(track: .incoming, sequence: 1)
        let second = Self.chunk(track: .outgoing, sequence: 1)

        async let firstResult = Self.reserveResult(ledger: ledger, chunk: first)
        async let secondResult = Self.reserveResult(ledger: ledger, chunk: second)
        let results = await [firstResult, secondResult]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        let snapshot = await ledger.currentSnapshot()
        XCTAssertEqual(snapshot.reservations.count, 1)
        XCTAssertLessThanOrEqual(snapshot.reservedNanoUSD, snapshot.authorizedNanoUSD)
    }

    func testIndependentLedgersSerializeConcurrentReservationsWithoutLostUpdate() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let callID = UUID()
        let firstLedger = try CallSpendLedger(
            callFolderURL: folder,
            callID: callID,
            initialLimitUSD: Decimal(string: "0.00005")!
        )
        let secondLedger = try CallSpendLedger(
            callFolderURL: folder,
            callID: callID,
            initialLimitUSD: Decimal(string: "0.00005")!
        )

        async let firstResult = Self.reserveResult(
            ledger: firstLedger,
            chunk: Self.chunk(track: .incoming, sequence: 1)
        )
        async let secondResult = Self.reserveResult(
            ledger: secondLedger,
            chunk: Self.chunk(track: .outgoing, sequence: 1)
        )
        let results = await [firstResult, secondResult]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        let persisted = try JSONDecoder().decode(
            SpendLedgerSnapshot.self,
            from: Data(contentsOf: firstLedger.ledgerURL)
        )
        XCTAssertEqual(persisted.reservations.count, 1)
        XCTAssertLessThanOrEqual(
            persisted.reservedNanoUSD,
            persisted.authorizedNanoUSD
        )
    }

    func testReservationIsIdempotentAcrossRestart() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let callID = UUID()
        let firstLedger = try CallSpendLedger(
            callFolderURL: folder,
            callID: callID,
            initialLimitUSD: 1
        )
        let audio = Self.chunk(track: .incoming, sequence: 42)
        try await firstLedger.reserve(chunk: audio, modelID: "gpt-live-transcribe")
        let before = await firstLedger.currentSnapshot()

        let restored = try CallSpendLedger(
            callFolderURL: folder,
            callID: callID,
            initialLimitUSD: 1
        )
        try await restored.reserve(chunk: audio, modelID: "gpt-live-transcribe")
        let after = await restored.currentSnapshot()

        XCTAssertEqual(after.reservations, before.reservations)
        XCTAssertEqual(after.reservedNanoUSD, before.reservedNanoUSD)
    }

    func testRealtimeReplayInNewConnectionEpochReservesAgainConservatively() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: UUID(),
            initialLimitUSD: 1
        )
        let audio = Self.chunk(track: .incoming, sequence: 42)

        try await ledger.reserve(
            chunk: audio,
            modelID: "gpt-live-transcribe",
            reservationEpoch: 1
        )
        try await ledger.reserve(
            chunk: audio,
            modelID: "gpt-live-transcribe",
            reservationEpoch: 1
        )
        try await ledger.reserve(
            chunk: audio,
            modelID: "gpt-live-transcribe",
            reservationEpoch: 2
        )

        let snapshot = await ledger.currentSnapshot()
        XCTAssertEqual(snapshot.reservations.map(\.id), [
            "rt:incoming:42:epoch:1",
            "rt:incoming:42:epoch:2"
        ])
    }

    func testUnknownCappedModelIsRejectedBeforeSpend() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: UUID(),
            initialLimitUSD: 1
        )

        do {
            try await ledger.reserveResponses(
                id: "unknown",
                modelID: "custom-unknown-model",
                estimatedInputTokens: 100,
                maximumOutputTokens: 100
            )
            XCTFail("Expected unknown model rejection")
        } catch let error as SpendLedgerError {
            XCTAssertEqual(error, .unknownModel("custom-unknown-model"))
        }
        let snapshot = await ledger.currentSnapshot()
        XCTAssertTrue(snapshot.reservations.isEmpty)
    }

    func testCurrentResponsesPricesUseNanoUSDRatesPerToken() throws {
        let catalog = OpenAIPriceCatalog.current
        XCTAssertEqual(
            try catalog.realtimeNanoUSD(
                modelID: "gpt-live-transcribe",
                frameCount: 24_000
            ),
            284_000
        )
        XCTAssertEqual(
            try catalog.fileTranscriptionNanoUSD(
                modelID: "gpt-transcribe",
                durationNanoseconds: 1_000_000_000
            ),
            80_000
        )
        XCTAssertEqual(
            try catalog.responsesNanoUSD(
                modelID: "gpt-5.6-terra",
                inputTokens: 1_000,
                maximumOutputTokens: 1_000
            ),
            14_500_000
        )
        XCTAssertEqual(
            try catalog.responsesNanoUSD(
                modelID: "gpt-5.6-luna",
                inputTokens: 1_000,
                maximumOutputTokens: 1_000
            ),
            1_450_000
        )
    }

    func testLongContextPremiumStartsStrictlyAbove272KInputTokens() throws {
        let catalog = OpenAIPriceCatalog.current
        XCTAssertEqual(
            try catalog.responsesNanoUSD(
                modelID: "gpt-5.6-terra",
                inputTokens: 272_000,
                maximumOutputTokens: 1_000
            ),
            692_000_000
        )
        XCTAssertEqual(
            try catalog.responsesNanoUSD(
                modelID: "gpt-5.6-terra",
                inputTokens: 272_001,
                maximumOutputTokens: 1_000
            ),
            1_378_005_000
        )
        XCTAssertEqual(
            try catalog.responsesNanoUSD(
                modelID: "gpt-5.6-luna",
                inputTokens: 272_001,
                maximumOutputTokens: 1_000
            ),
            137_800_500
        )
        XCTAssertEqual(
            try catalog.responsesNanoUSD(
                modelID: "gpt-5.6-sol",
                inputTokens: 272_001,
                maximumOutputTokens: 1_000
            ),
            3_445_012_500
        )
    }

    func testFileRetryReservesEachProviderAttemptButCrashReplayIsIdempotent() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let callID = UUID()
        let ledger = try CallSpendLedger(
            callFolderURL: folder,
            callID: callID,
            initialLimitUSD: 1
        )
        let authorizer = CallSpendReconciliationAuthorizer(ledger: ledger)
        let first = ReconciliationSpendRequest(
            callID: callID,
            jobID: "job",
            chunkID: "chunk",
            modelID: "gpt-transcribe",
            estimatedUploadBytes: 1_000,
            durationNanoseconds: 10_000_000_000,
            attempt: 1
        )
        let retry = ReconciliationSpendRequest(
            callID: callID,
            jobID: "job",
            chunkID: "chunk",
            modelID: "gpt-transcribe",
            estimatedUploadBytes: 1_000,
            durationNanoseconds: 10_000_000_000,
            attempt: 2
        )

        let firstAuthorization = try await authorizer.authorize(request: first)
        let replayAuthorization = try await authorizer.authorize(request: first)
        let retryAuthorization = try await authorizer.authorize(request: retry)
        XCTAssertTrue(firstAuthorization)
        XCTAssertTrue(replayAuthorization)
        XCTAssertTrue(retryAuthorization)

        let snapshot = await ledger.currentSnapshot()
        XCTAssertEqual(snapshot.reservations.count, 2)
        XCTAssertEqual(Set(snapshot.reservations.map(\.id)), [
            "file:chunk:attempt:1",
            "file:chunk:attempt:2"
        ])
    }

    private static func reserveResult(
        ledger: CallSpendLedger,
        chunk: LivePCMChunk
    ) async -> Bool {
        do {
            try await ledger.reserve(chunk: chunk, modelID: "gpt-live-transcribe")
            return true
        } catch {
            return false
        }
    }

    private static func chunk(track: AudioTrack, sequence: UInt64) -> LivePCMChunk {
        LivePCMChunk(
            track: track,
            sequence: sequence,
            startCallNanoseconds: sequence * 100_000_000,
            pcm16LittleEndian: Data(count: 4_800),
            frameCount: 2_400,
            discontinuityBefore: false
        )
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
