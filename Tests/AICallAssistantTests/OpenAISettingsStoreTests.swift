import Foundation
import XCTest
@testable import AICallAssistant

@MainActor
final class OpenAISettingsStoreTests: XCTestCase {
    func testEnvironmentImportRequiresExplicitArgumentAndStoresCredential() throws {
        let userDefaults = isolatedUserDefaults()
        let secrets = InMemorySecretStore()
        let store = OpenAISettingsStore(userDefaults: userDefaults, secretStore: secrets)

        XCTAssertFalse(
            try store.importAPIKeyFromEnvironmentIfRequested(
                arguments: ["AICallAssistant"],
                environment: ["OPENAI_API_KEY": "unit-test-key"]
            )
        )
        XCTAssertNil(try secrets.readSecret(for: .openAIAPIKey))

        XCTAssertTrue(
            try store.importAPIKeyFromEnvironmentIfRequested(
                arguments: ["AICallAssistant", OpenAISettingsStore.environmentImportArgument],
                environment: ["OPENAI_API_KEY": " unit-test-key "]
            )
        )
        XCTAssertEqual(try secrets.readSecret(for: .openAIAPIKey), "unit-test-key")
        XCTAssertEqual(store.credentialState, .available)
    }

    func testDefaultsSelectSupportedModelsRussianAndEnglish() {
        let defaults = isolatedUserDefaults()
        defer { removePersistentDomain(for: defaults) }

        let store = OpenAISettingsStore(
            userDefaults: defaults,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(store.configuration.responsesModelID, "gpt-5.6-terra")
        XCTAssertEqual(store.configuration.realtimeTranscriptionModelID, "gpt-live-transcribe")
        XCTAssertEqual(store.configuration.fileTranscriptionModelID, "gpt-transcribe")
        XCTAssertEqual(store.configuration.transcriptionLanguages, ["ru", "en"])
        XCTAssertEqual(store.configuration.answerStyle, .brief)
        XCTAssertEqual(store.configuration.answerLanguage, .automatic)
        XCTAssertEqual(store.configuration.briefAnswerMaxWords, 60)
        XCTAssertEqual(store.configuration.detailedAnswerMaxWords, 160)
        XCTAssertEqual(store.configuration.adviceMaxWords, 30)
        XCTAssertEqual(store.configuration.maxOutputTokens, 4_096)
    }

    func testNonsecretSettingsRoundTripAndAreNormalized() throws {
        let defaults = isolatedUserDefaults()
        defer { removePersistentDomain(for: defaults) }
        let secrets = InMemorySecretStore()
        let store = OpenAISettingsStore(userDefaults: defaults, secretStore: secrets)
        var updated = store.configuration
        updated.transcriptionLanguages = [" EN ", "ru", "en"]
        updated.answerStyle = .detailed
        updated.answerLanguage = .english
        updated.detailedAnswerMaxWords = 220

        try store.updateConfiguration(updated)

        let reloaded = OpenAISettingsStore(userDefaults: defaults, secretStore: secrets)
        XCTAssertEqual(reloaded.configuration.transcriptionLanguages, ["en", "ru"])
        XCTAssertEqual(reloaded.configuration.answerStyle, .detailed)
        XCTAssertEqual(reloaded.configuration.answerLanguage, .english)
        XCTAssertEqual(reloaded.configuration.detailedAnswerMaxWords, 220)
    }

    func testUnsupportedModelIsRejectedWithoutChangingPersistedConfiguration() throws {
        let defaults = isolatedUserDefaults()
        defer { removePersistentDomain(for: defaults) }
        let store = OpenAISettingsStore(
            userDefaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let original = store.configuration
        var invalid = original
        invalid.responsesModelID = "unlisted-responses-model"

        XCTAssertThrowsError(try store.updateConfiguration(invalid)) { error in
            XCTAssertEqual(
                error as? GuidanceConfigurationValidationError,
                .unsupportedModel(role: .responses, modelID: "unlisted-responses-model")
            )
        }
        XCTAssertEqual(store.configuration, original)
        XCTAssertNil(defaults.data(forKey: OpenAISettingsStore.persistedSettingsKey))
    }

    func testCorruptOrUnsupportedPersistedDataFallsBackToDefaults() {
        let defaults = isolatedUserDefaults()
        defer { removePersistentDomain(for: defaults) }
        defaults.set(Data("not-json".utf8), forKey: OpenAISettingsStore.persistedSettingsKey)

        let store = OpenAISettingsStore(
            userDefaults: defaults,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(store.configuration, GuidanceConfiguration.default)
    }

    func testAPIKeyAsyncCRUDUsesSecretStoreAndNeverUserDefaults() async throws {
        let defaults = isolatedUserDefaults()
        defer { removePersistentDomain(for: defaults) }
        let secrets = InMemorySecretStore()
        let store = OpenAISettingsStore(userDefaults: defaults, secretStore: secrets)
        let marker = "test-credential-marker-91F6C65A"

        let initiallyStoredKey = try await store.loadAPIKey()
        XCTAssertNil(initiallyStoredKey)
        XCTAssertEqual(store.credentialState, .missing)

        try await store.saveAPIKey("  \(marker)\n")
        XCTAssertEqual(store.credentialState, .available)
        let storedKey = try await store.loadAPIKey()
        XCTAssertEqual(storedKey, marker)
        XCTAssertEqual(try secrets.readSecret(for: .openAIAPIKey), marker)
        XCTAssertFalse(userDefaults(defaults, contains: marker))

        try store.updateConfiguration(store.configuration)
        let settingsData = try XCTUnwrap(
            defaults.data(forKey: OpenAISettingsStore.persistedSettingsKey)
        )
        XCTAssertNil(settingsData.range(of: Data(marker.utf8)))
        XCTAssertFalse(userDefaults(defaults, contains: marker))

        try await store.deleteAPIKey()
        XCTAssertEqual(store.credentialState, .missing)
        let deletedKey = try await store.loadAPIKey()
        XCTAssertNil(deletedKey)
        XCTAssertNil(try secrets.readSecret(for: .openAIAPIKey))
    }

    func testEmptyAPIKeyIsRejectedWithoutLeakingInput() async {
        let defaults = isolatedUserDefaults()
        defer { removePersistentDomain(for: defaults) }
        let secrets = InMemorySecretStore()
        let store = OpenAISettingsStore(userDefaults: defaults, secretStore: secrets)

        do {
            try await store.saveAPIKey(" \n\t ")
            XCTFail("Expected an empty API key error")
        } catch {
            XCTAssertEqual(error as? OpenAISettingsStoreError, .emptyAPIKey)
            XCTAssertFalse(error.localizedDescription.contains("\n\t"))
        }
        XCTAssertNil(try? secrets.readSecret(for: .openAIAPIKey))
    }

    func testSecretStoreProvidesSynchronousAndAsynchronousCRUD() async throws {
        let secrets = InMemorySecretStore()

        try secrets.writeSecret("sync-value", for: .openAIAPIKey)
        XCTAssertEqual(try secrets.readSecret(for: .openAIAPIKey), "sync-value")
        try secrets.deleteSecret(for: .openAIAPIKey)
        XCTAssertNil(try secrets.readSecret(for: .openAIAPIKey))

        try await secrets.writeSecretAsync("async-value", for: .openAIAPIKey)
        let asynchronousValue = try await secrets.readSecretAsync(for: .openAIAPIKey)
        XCTAssertEqual(asynchronousValue, "async-value")
        try await secrets.deleteSecretAsync(for: .openAIAPIKey)
        let deletedAsynchronousValue = try await secrets.readSecretAsync(for: .openAIAPIKey)
        XCTAssertNil(deletedAsynchronousValue)
    }

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "OpenAISettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(suiteName, forKey: "test-suite-name")
        return defaults
    }

    private func removePersistentDomain(for defaults: UserDefaults) {
        if let suiteName = defaults.string(forKey: "test-suite-name") {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func userDefaults(_ defaults: UserDefaults, contains marker: String) -> Bool {
        contains(marker: marker, in: defaults.dictionaryRepresentation())
    }

    private func contains(marker: String, in value: Any) -> Bool {
        if let string = value as? String {
            return string.contains(marker)
        }
        if let data = value as? Data {
            return data.range(of: Data(marker.utf8)) != nil
        }
        if let array = value as? [Any] {
            return array.contains { contains(marker: marker, in: $0) }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, value in
                key.contains(marker) || contains(marker: marker, in: value)
            }
        }
        return false
    }
}

private final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretIdentifier: String] = [:]

    func readSecret(for identifier: SecretIdentifier) throws -> String? {
        withLock { values[identifier] }
    }

    func writeSecret(_ secret: String, for identifier: SecretIdentifier) throws {
        withLock { values[identifier] = secret }
    }

    func deleteSecret(for identifier: SecretIdentifier) throws {
        _ = withLock { values.removeValue(forKey: identifier) }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
