import Foundation
import XCTest
@testable import AICallAssistant

final class PrivateFileSecretStoreTests: XCTestCase {
    func testCRUDUsesOwnerOnlyPermissionsAndAtomicReplacement() throws {
        try withTemporaryDirectory { rootURL in
            let directoryURL = rootURL.appendingPathComponent("Secrets", isDirectory: true)
            let credentialURL = directoryURL.appendingPathComponent(
                SecretIdentifier.openAIAPIKey.rawValue,
                isDirectory: false
            )
            let store = PrivateFileSecretStore(directoryURL: directoryURL)

            XCTAssertNil(try store.readSecret(for: .openAIAPIKey))
            XCTAssertEqual(try permissions(of: directoryURL), 0o700)

            try store.writeSecret("first-test-value", for: .openAIAPIKey)
            XCTAssertEqual(try store.readSecret(for: .openAIAPIKey), "first-test-value")
            XCTAssertEqual(try permissions(of: credentialURL), 0o600)
            XCTAssertEqual(
                try directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup,
                true
            )
            XCTAssertEqual(
                try credentialURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup,
                true
            )

            // Existing overly broad permissions are repaired on access.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o777)],
                ofItemAtPath: directoryURL.path
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o666)],
                ofItemAtPath: credentialURL.path
            )
            XCTAssertEqual(try store.readSecret(for: .openAIAPIKey), "first-test-value")
            XCTAssertEqual(try permissions(of: directoryURL), 0o700)
            XCTAssertEqual(try permissions(of: credentialURL), 0o600)

            try store.writeSecret("second-test-value", for: .openAIAPIKey)
            XCTAssertEqual(try store.readSecret(for: .openAIAPIKey), "second-test-value")
            XCTAssertEqual(try permissions(of: credentialURL), 0o600)
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
                    .contains { $0.hasSuffix(".tmp") }
            )

            try store.deleteSecret(for: .openAIAPIKey)
            try store.deleteSecret(for: .openAIAPIKey)
            XCTAssertNil(try store.readSecret(for: .openAIAPIKey))
        }
    }

    func testInvalidUTF8IsRejected() throws {
        try withTemporaryDirectory { rootURL in
            let directoryURL = rootURL.appendingPathComponent("Secrets", isDirectory: true)
            let credentialURL = directoryURL.appendingPathComponent(
                SecretIdentifier.openAIAPIKey.rawValue,
                isDirectory: false
            )
            let store = PrivateFileSecretStore(directoryURL: directoryURL)

            try store.writeSecret("placeholder", for: .openAIAPIKey)
            try Data([0xFF]).write(to: credentialURL, options: .atomic)

            XCTAssertThrowsError(try store.readSecret(for: .openAIAPIKey)) { error in
                XCTAssertEqual(error as? PrivateFileSecretStoreError, .invalidStoredData)
            }
        }
    }

    func testReadRejectsSymbolicLinkWithoutFollowingIt() throws {
        try withTemporaryDirectory { rootURL in
            let directoryURL = rootURL.appendingPathComponent("Secrets", isDirectory: true)
            let credentialURL = directoryURL.appendingPathComponent(
                SecretIdentifier.openAIAPIKey.rawValue,
                isDirectory: false
            )
            let outsideURL = rootURL.appendingPathComponent("outside-value", isDirectory: false)
            let store = PrivateFileSecretStore(directoryURL: directoryURL)

            XCTAssertNil(try store.readSecret(for: .openAIAPIKey))
            try Data("must-not-be-read".utf8).write(to: outsideURL)
            try FileManager.default.createSymbolicLink(
                at: credentialURL,
                withDestinationURL: outsideURL
            )

            XCTAssertThrowsError(try store.readSecret(for: .openAIAPIKey)) { error in
                XCTAssertEqual(
                    error as? PrivateFileSecretStoreError,
                    .unsafeStorageLocation
                )
            }
        }
    }

    func testDirectorySymbolicLinkIsRejected() throws {
        try withTemporaryDirectory { rootURL in
            let outsideDirectoryURL = rootURL.appendingPathComponent(
                "outside-directory",
                isDirectory: true
            )
            let directoryURL = rootURL.appendingPathComponent("Secrets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outsideDirectoryURL,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: directoryURL,
                withDestinationURL: outsideDirectoryURL
            )
            let store = PrivateFileSecretStore(directoryURL: directoryURL)

            XCTAssertThrowsError(try store.readSecret(for: .openAIAPIKey)) { error in
                XCTAssertEqual(
                    error as? PrivateFileSecretStoreError,
                    .unsafeStorageLocation
                )
            }
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(atPath: outsideDirectoryURL.path)
                    .isEmpty
            )
        }
    }

    func testWriteReplacesCredentialSymbolicLinkWithoutChangingItsTarget() throws {
        try withTemporaryDirectory { rootURL in
            let directoryURL = rootURL.appendingPathComponent("Secrets", isDirectory: true)
            let credentialURL = directoryURL.appendingPathComponent(
                SecretIdentifier.openAIAPIKey.rawValue,
                isDirectory: false
            )
            let outsideURL = rootURL.appendingPathComponent("outside-value", isDirectory: false)
            let store = PrivateFileSecretStore(directoryURL: directoryURL)

            XCTAssertNil(try store.readSecret(for: .openAIAPIKey))
            try Data("outside-must-not-change".utf8).write(to: outsideURL)
            try FileManager.default.createSymbolicLink(
                at: credentialURL,
                withDestinationURL: outsideURL
            )

            try store.writeSecret("new-local-value", for: .openAIAPIKey)

            XCTAssertEqual(try String(contentsOf: outsideURL), "outside-must-not-change")
            XCTAssertEqual(try store.readSecret(for: .openAIAPIKey), "new-local-value")
        }
    }

    func testOversizedSecretIsRejected() throws {
        try withTemporaryDirectory { rootURL in
            let directoryURL = rootURL.appendingPathComponent("Secrets", isDirectory: true)
            let store = PrivateFileSecretStore(directoryURL: directoryURL)
            let oversized = String(repeating: "x", count: 64 * 1_024 + 1)

            XCTAssertThrowsError(
                try store.writeSecret(oversized, for: .openAIAPIKey)
            ) { error in
                XCTAssertEqual(error as? PrivateFileSecretStoreError, .secretTooLarge)
                XCTAssertFalse(error.localizedDescription.contains(oversized))
            }
        }
    }

    func testFailureMessagesNeverContainSecret() throws {
        try withTemporaryDirectory { rootURL in
            let invalidDirectoryURL = rootURL.appendingPathComponent("not-a-directory")
            try Data("ordinary-file".utf8).write(to: invalidDirectoryURL)
            let store = PrivateFileSecretStore(directoryURL: invalidDirectoryURL)
            let marker = "credential-marker-that-must-not-leak"

            XCTAssertThrowsError(
                try store.writeSecret(marker, for: .openAIAPIKey)
            ) { error in
                XCTAssertFalse(error.localizedDescription.contains(marker))
                XCTAssertFalse(String(describing: error).contains(marker))
            }
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PrivateFileSecretStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try operation(rootURL)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
