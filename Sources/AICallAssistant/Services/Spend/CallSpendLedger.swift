import Foundation

enum SpendReservationKind: String, Codable, Equatable, Sendable {
    case realtimeTranscription
    case fileTranscription
    case responses
}

struct SpendReservation: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: SpendReservationKind
    let modelID: String
    let reservedNanoUSD: Int64
    let createdAt: Date
}

struct SpendLedgerSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var callID: UUID
    var priceCatalogVersion: String
    var authorizationRevisions: [SpendAuthorizationRevision]
    var reservations: [SpendReservation]

    var reservedNanoUSD: Int64 {
        reservations.reduce(0) { $0 + $1.reservedNanoUSD }
    }

    var authorizedNanoUSD: Int64 {
        guard let latest = authorizationRevisions.max(by: { $0.revision < $1.revision }) else {
            return 0
        }
        return Self.nanoUSD(from: latest.authorizedLimitUSD)
    }

    private static func nanoUSD(from decimal: Decimal) -> Int64 {
        NSDecimalNumber(decimal: decimal)
            .multiplying(by: NSDecimalNumber(value: 1_000_000_000))
            .int64Value
    }
}

enum SpendLedgerError: Error, Equatable, Sendable {
    case callIDMismatch
    case priceCatalogMismatch
    case unknownModel(String)
    case invalidUnits
    case limitExceeded(requiredNanoUSD: Int64, remainingNanoUSD: Int64)
    case authorizationMustIncrease
}

struct OpenAIPriceCatalog: Equatable, Sendable {
    let version: String

    static let current = OpenAIPriceCatalog(version: "2026-08-16.4")

    private static let longContextThresholdTokens = 272_000

    func realtimeNanoUSD(modelID: String, frameCount: Int) throws -> Int64 {
        guard modelID == "gpt-live-transcribe" else {
            throw SpendLedgerError.unknownModel(modelID)
        }
        guard frameCount >= 0 else { throw SpendLedgerError.invalidUnits }
        // Official price: $0.017 / minute. Conservatively round the
        // per-second rate upward before reserving each 24 kHz frame batch.
        return Self.ceilDivide(Int64(frameCount) * 284_000, 24_000)
    }

    func fileTranscriptionNanoUSD(modelID: String, durationNanoseconds: UInt64) throws -> Int64 {
        guard modelID == "gpt-transcribe" else {
            throw SpendLedgerError.unknownModel(modelID)
        }
        // Official price: $0.0045 / minute. Reserve $0.0048 / minute so
        // per-second integer accounting always stays on the conservative side.
        let bounded = Int64(clamping: durationNanoseconds)
        return Self.ceilDivide(bounded * 80_000, 1_000_000_000)
    }

    func responsesNanoUSD(
        modelID: String,
        inputTokens: Int,
        maximumOutputTokens: Int
    ) throws -> Int64 {
        guard inputTokens >= 0, maximumOutputTokens >= 0 else {
            throw SpendLedgerError.invalidUnits
        }
        let isLongContext = inputTokens > Self.longContextThresholdTokens
        // GPT-5.6 enables implicit prompt caching by default. An eligible
        // prefix may be written at 1.25x the ordinary input price, so a hard
        // cap must reserve every estimated input token at the cache-write
        // rate. Cache hits and non-cacheable prompts will simply cost less
        // than this conservative reservation.
        let rates: (input: Int64, output: Int64)
        switch (modelID, isLongContext) {
        case ("gpt-5.6-sol", false):
            rates = (6_250, 30_000)
        case ("gpt-5.6-sol", true):
            rates = (12_500, 45_000)
        case ("gpt-5.6-terra", false):
            rates = (2_500, 12_000)
        case ("gpt-5.6-terra", true):
            rates = (5_000, 18_000)
        case ("gpt-5.6-luna", false):
            rates = (250, 1_200)
        case ("gpt-5.6-luna", true):
            rates = (500, 1_800)
        default:
            throw SpendLedgerError.unknownModel(modelID)
        }
        let inputCost = Self.saturatingMultiply(
            Int64(clamping: inputTokens),
            rates.input
        )
        let outputCost = Self.saturatingMultiply(
            Int64(clamping: maximumOutputTokens),
            rates.output
        )
        return Self.saturatingAdd(inputCost, outputCost)
    }

    private static func ceilDivide(_ numerator: Int64, _ denominator: Int64) -> Int64 {
        guard numerator > 0 else { return 0 }
        return (numerator + denominator - 1) / denominator
    }

    private static func saturatingMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int64.max : value
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}

protocol LiveAudioSpendAuthorizer: Sendable {
    func reserve(
        chunk: LivePCMChunk,
        modelID: String,
        reservationEpoch: Int
    ) async throws
}

extension LiveAudioSpendAuthorizer {
    func reserve(chunk: LivePCMChunk, modelID: String) async throws {
        try await reserve(
            chunk: chunk,
            modelID: modelID,
            reservationEpoch: 0
        )
    }
}

actor CallSpendLedger: LiveAudioSpendAuthorizer {
    nonisolated let ledgerURL: URL

    /// Actor isolation only serializes one ledger instance. A call can briefly
    /// have multiple instances during lifecycle handoff, so disk mutations also
    /// share one process-wide critical section.
    private static let processMutationLock = NSLock()

    private let callID: UUID
    private let catalog: OpenAIPriceCatalog
    private let now: @Sendable () -> Date
    private var snapshot: SpendLedgerSnapshot

    init(
        callFolderURL: URL,
        callID: UUID,
        initialLimitUSD: Decimal,
        catalog: OpenAIPriceCatalog = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let resolvedLedgerURL = callFolderURL.appendingPathComponent("spend-ledger.json")
        let initialSnapshot = try Self.withProcessMutationLock {
            if FileManager.default.fileExists(atPath: resolvedLedgerURL.path) {
                return try Self.load(
                    from: resolvedLedgerURL,
                    expectedCallID: callID,
                    expectedCatalogVersion: catalog.version
                )
            }
            let authorization = SpendAuthorizationRevision(
                id: "spend:\(callID.uuidString):0",
                callID: callID,
                revision: 0,
                authorizedLimitUSD: initialLimitUSD,
                priceCatalogVersion: catalog.version,
                createdAt: now()
            )
            let created = SpendLedgerSnapshot(
                schemaVersion: 1,
                callID: callID,
                priceCatalogVersion: catalog.version,
                authorizationRevisions: [authorization],
                reservations: []
            )
            try Self.persist(created, to: resolvedLedgerURL)
            return created
        }

        ledgerURL = resolvedLedgerURL
        self.callID = callID
        self.catalog = catalog
        self.now = now
        snapshot = initialSnapshot
    }

    func reserve(
        chunk: LivePCMChunk,
        modelID: String,
        reservationEpoch: Int
    ) throws {
        let cost = try catalog.realtimeNanoUSD(
            modelID: modelID,
            frameCount: chunk.frameCount
        )
        try reserve(
            id: "rt:\(chunk.track.rawValue):\(chunk.sequence):epoch:\(reservationEpoch)",
            kind: .realtimeTranscription,
            modelID: modelID,
            nanoUSD: cost
        )
    }

    func reserveFileChunk(
        id: String,
        modelID: String,
        durationNanoseconds: UInt64
    ) throws {
        try reserve(
            id: id,
            kind: .fileTranscription,
            modelID: modelID,
            nanoUSD: try catalog.fileTranscriptionNanoUSD(
                modelID: modelID,
                durationNanoseconds: durationNanoseconds
            )
        )
    }

    func reserveResponses(
        id: String,
        modelID: String,
        estimatedInputTokens: Int,
        maximumOutputTokens: Int
    ) throws {
        try reserve(
            id: id,
            kind: .responses,
            modelID: modelID,
            nanoUSD: try catalog.responsesNanoUSD(
                modelID: modelID,
                inputTokens: estimatedInputTokens,
                maximumOutputTokens: maximumOutputTokens
            )
        )
    }

    func authorizeHigherLimit(_ revision: SpendAuthorizationRevision) throws {
        try mutateLatestSnapshot { latest in
            guard revision.callID == latest.callID else {
                throw SpendLedgerError.callIDMismatch
            }
            guard revision.priceCatalogVersion == catalog.version else {
                throw SpendLedgerError.priceCatalogMismatch
            }
            let current = latest.authorizationRevisions.max(by: {
                $0.revision < $1.revision
            })!
            guard revision.revision > current.revision,
                  revision.authorizedLimitUSD > current.authorizedLimitUSD else {
                throw SpendLedgerError.authorizationMustIncrease
            }
            latest.authorizationRevisions.append(revision)
            return true
        }
    }

    func currentSnapshot() -> SpendLedgerSnapshot {
        snapshot
    }

    private func reserve(
        id: String,
        kind: SpendReservationKind,
        modelID: String,
        nanoUSD: Int64
    ) throws {
        try mutateLatestSnapshot { latest in
            if latest.reservations.contains(where: { $0.id == id }) {
                return false
            }
            let remaining = latest.authorizedNanoUSD - latest.reservedNanoUSD
            guard nanoUSD <= remaining else {
                throw SpendLedgerError.limitExceeded(
                    requiredNanoUSD: nanoUSD,
                    remainingNanoUSD: max(0, remaining)
                )
            }
            latest.reservations.append(
                SpendReservation(
                    id: id,
                    kind: kind,
                    modelID: modelID,
                    reservedNanoUSD: nanoUSD,
                    createdAt: now()
                )
            )
            return true
        }
    }

    private func mutateLatestSnapshot(
        _ mutation: (inout SpendLedgerSnapshot) throws -> Bool
    ) throws {
        try Self.withProcessMutationLock {
            let latest = try Self.load(
                from: ledgerURL,
                expectedCallID: callID,
                expectedCatalogVersion: catalog.version
            )
            // Keep this actor coherent even when the mutation is idempotent or
            // rejected after another ledger consumed the remaining budget.
            snapshot = latest
            var updated = latest
            guard try mutation(&updated) else { return }
            try Self.persist(updated, to: ledgerURL)
            snapshot = updated
        }
    }

    private static func withProcessMutationLock<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        processMutationLock.lock()
        defer { processMutationLock.unlock() }
        return try body()
    }

    private static func load(
        from url: URL,
        expectedCallID: UUID,
        expectedCatalogVersion: String
    ) throws -> SpendLedgerSnapshot {
        let loaded = try JSONDecoder().decode(
            SpendLedgerSnapshot.self,
            from: Data(contentsOf: url)
        )
        guard loaded.callID == expectedCallID else {
            throw SpendLedgerError.callIDMismatch
        }
        guard loaded.priceCatalogVersion == expectedCatalogVersion else {
            throw SpendLedgerError.priceCatalogMismatch
        }
        return loaded
    }

    private static func persist(_ snapshot: SpendLedgerSnapshot, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}

struct BudgetedLiveGuidanceProvider<Base: LiveGuidanceProvider>: LiveGuidanceProvider {
    let base: Base
    let ledger: CallSpendLedger

    func analyze(snapshot: ConversationSnapshot) async throws -> LiveGuidanceProviderResult {
        let request = try GuidancePromptBuilder().makeRequest(for: snapshot)
        let estimate = try OpenAIResponsesRequestSpendEstimator().estimate(
            request: request
        )
        try await ledger.reserveResponses(
            // Each invocation is a separately billable attempt. If the process
            // crashes after OpenAI accepted a request but before publication,
            // the old reservation remains consumed and the recovered attempt
            // must acquire fresh budget rather than reusing it.
            id: "responses:\(snapshot.id):attempt:\(UUID().uuidString)",
            modelID: snapshot.configuration.responsesModelID,
            estimatedInputTokens: estimate.reservedInputTokens,
            maximumOutputTokens: snapshot.configuration.maxOutputTokens
        )
        return try await base.analyze(snapshot: snapshot)
    }
}
