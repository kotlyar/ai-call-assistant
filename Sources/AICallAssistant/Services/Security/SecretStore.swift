import Foundation

enum SecretIdentifier: String, Hashable, Sendable {
    case openAIAPIKey = "openai-api-key"
}

/// A synchronous boundary around the platform secret store.
///
/// Implementations must never include a secret value in an error or log message.
/// The asynchronous helpers keep synchronous secret-storage I/O off the caller's
/// executor while preserving a small protocol that is easy to fake.
protocol SecretStore: Sendable {
    func readSecret(for identifier: SecretIdentifier) throws -> String?
    func writeSecret(_ secret: String, for identifier: SecretIdentifier) throws
    func deleteSecret(for identifier: SecretIdentifier) throws
}

extension SecretStore {
    func readSecretAsync(for identifier: SecretIdentifier) async throws -> String? {
        try await Task.detached { [self] in
            try readSecret(for: identifier)
        }.value
    }

    func writeSecretAsync(_ secret: String, for identifier: SecretIdentifier) async throws {
        try await Task.detached { [self] in
            try writeSecret(secret, for: identifier)
        }.value
    }

    func deleteSecretAsync(for identifier: SecretIdentifier) async throws {
        try await Task.detached { [self] in
            try deleteSecret(for: identifier)
        }.value
    }
}
