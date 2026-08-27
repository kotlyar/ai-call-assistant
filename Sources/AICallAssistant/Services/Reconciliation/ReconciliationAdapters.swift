import Foundation

struct ClosureReconciliationCredentialProvider: ReconciliationCredentialProvider {
    let load: @Sendable () async throws -> String?

    func currentAPIKey() async throws -> String? {
        try await load()
    }
}

struct SecretStoreReconciliationCredentialProvider:
    ReconciliationCredentialProvider,
    FinalAnalysisCredentialProvider {
    let secretStore: any SecretStore

    init(secretStore: any SecretStore = PrivateFileSecretStore()) {
        self.secretStore = secretStore
    }

    func currentAPIKey() async throws -> String? {
        if let stored = try await secretStore.readSecretAsync(for: .openAIAPIKey),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        let environment = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return environment?.isEmpty == false ? environment : nil
    }
}

struct CallSpendReconciliationAuthorizer: ReconciliationSpendAuthorizer {
    let ledger: CallSpendLedger

    func authorize(request: ReconciliationSpendRequest) async throws -> Bool {
        do {
            // Generation zero keeps the legacy reservation ID, so an in-flight
            // pre-upgrade attempt remains idempotent after relaunch. Explicit
            // retry windows use a persisted generation and therefore reserve
            // fresh budget even though their per-window attempt count restarts.
            let reservationID = request.retryGeneration == 0
                ? "file:\(request.chunkID):attempt:\(request.attempt)"
                : "file:\(request.chunkID):retry:\(request.retryGeneration):attempt:\(request.attempt)"
            try await ledger.reserveFileChunk(
                id: reservationID,
                modelID: request.modelID,
                durationNanoseconds: request.durationNanoseconds
            )
            return true
        } catch SpendLedgerError.limitExceeded {
            return false
        }
    }
}
