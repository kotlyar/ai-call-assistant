import Combine
import Foundation

enum OpenAICredentialState: Equatable, Sendable {
    case unknown
    case missing
    case available
}

enum OpenAISettingsStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyAPIKey

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "The OpenAI API key cannot be empty."
        }
    }
}

@MainActor
final class OpenAISettingsStore: ObservableObject {
    static let persistedSettingsKey = "com.aicallassistant.openai.settings.v1"
    static let environmentImportArgument = "--import-openai-key-from-environment"

    @Published private(set) var configuration: GuidanceConfiguration
    @Published private(set) var credentialState: OpenAICredentialState = .unknown

    private let userDefaults: UserDefaults
    private let secretStore: any SecretStore
    private let modelCatalog: OpenAIModelCatalog
    private let encoder: JSONEncoder

    init(
        userDefaults: UserDefaults = .standard,
        secretStore: any SecretStore = PrivateFileSecretStore(),
        modelCatalog: OpenAIModelCatalog = .current
    ) {
        self.userDefaults = userDefaults
        self.secretStore = secretStore
        self.modelCatalog = modelCatalog

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        configuration = Self.loadConfiguration(
            from: userDefaults,
            modelCatalog: modelCatalog
        )
    }

    func updateConfiguration(_ newConfiguration: GuidanceConfiguration) throws {
        let validatedConfiguration = try newConfiguration.validated(using: modelCatalog)
        try persist(validatedConfiguration)
        configuration = validatedConfiguration
    }

    /// Explicit local-development bootstrap. The flag is required so a normal
    /// Finder launch never imports ambient process environment unexpectedly.
    @discardableResult
    func importAPIKeyFromEnvironmentIfRequested(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        guard arguments.contains(Self.environmentImportArgument) else {
            return false
        }
        guard let rawKey = environment["OPENAI_API_KEY"] else {
            throw OpenAISettingsStoreError.emptyAPIKey
        }
        let normalizedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw OpenAISettingsStoreError.emptyAPIKey
        }

        try secretStore.writeSecret(normalizedKey, for: .openAIAPIKey)
        credentialState = .available
        return true
    }

    func resetConfiguration() throws {
        let defaultConfiguration = try GuidanceConfiguration.default.validated(using: modelCatalog)
        try persist(defaultConfiguration)
        configuration = defaultConfiguration
    }

    func loadAPIKey() async throws -> String? {
        do {
            let key = try await secretStore.readSecretAsync(for: .openAIAPIKey)
            guard let key, !key.isEmpty else {
                credentialState = .missing
                return nil
            }
            credentialState = .available
            return key
        } catch {
            credentialState = .unknown
            throw error
        }
    }

    func saveAPIKey(_ apiKey: String) async throws {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw OpenAISettingsStoreError.emptyAPIKey
        }

        do {
            try await secretStore.writeSecretAsync(normalizedKey, for: .openAIAPIKey)
            credentialState = .available
        } catch {
            credentialState = .unknown
            throw error
        }
    }

    func deleteAPIKey() async throws {
        do {
            try await secretStore.deleteSecretAsync(for: .openAIAPIKey)
            credentialState = .missing
        } catch {
            credentialState = .unknown
            throw error
        }
    }

    func refreshCredentialState() async throws {
        _ = try await loadAPIKey()
    }

    private func persist(_ configuration: GuidanceConfiguration) throws {
        let envelope = PersistedSettings(
            schemaVersion: PersistedSettings.currentSchemaVersion,
            configuration: configuration
        )
        let data = try encoder.encode(envelope)
        userDefaults.set(data, forKey: Self.persistedSettingsKey)
    }

    private static func loadConfiguration(
        from userDefaults: UserDefaults,
        modelCatalog: OpenAIModelCatalog
    ) -> GuidanceConfiguration {
        guard
            let data = userDefaults.data(forKey: persistedSettingsKey),
            let envelope = try? JSONDecoder().decode(PersistedSettings.self, from: data),
            envelope.schemaVersion == PersistedSettings.currentSchemaVersion,
            let validatedConfiguration = try? envelope.configuration.validated(using: modelCatalog)
        else {
            return GuidanceConfiguration.default
        }
        return validatedConfiguration
    }
}

private struct PersistedSettings: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let configuration: GuidanceConfiguration
}
