import Foundation
import XCTest
@testable import AICallAssistant

final class ContextLibraryStoreTests: XCTestCase {
    func testLoadReturnsEmptyArrayWhenContextsFileDoesNotExist() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = ContextLibraryStore(rootURL: rootURL)

        XCTAssertEqual(try store.load(), [])
    }

    func testSaveAndLoadRoundTripsCompleteContextLibraryInOrder() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = ContextLibraryStore(rootURL: rootURL)
        let contexts = [
            CallContext(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                title: "Резюме 👩🏽‍💻",
                body: "Первая строка\nВторая строка — опыт в B2B SaaS.",
                isSelected: false,
                attachments: [
                    ContextFileAttachment(
                        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                        fileName: "CV Андрея 📄.pdf",
                        mediaType: "application/pdf",
                        byteCount: 12_345,
                        contentSHA256: String(repeating: "a", count: 64),
                        extractedText: "Точный текст файла\nс Unicode: 你好, مرحبا, 🙂"
                    )
                ]
            ),
            CallContext(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                title: "Вакансия",
                body: "Head of Product",
                isSelected: true,
                attachments: []
            )
        ]

        try store.save(contexts)

        let contextsURL = rootURL.appendingPathComponent("contexts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: contextsURL.path))
        XCTAssertEqual(try permissions(of: rootURL), 0o700)
        XCTAssertEqual(try permissions(of: contextsURL), 0o600)
        XCTAssertEqual(try store.load(), contexts)
    }

    func testSavingEmptyLibraryOverwritesPreviouslySavedContexts() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = ContextLibraryStore(rootURL: rootURL)
        let context = CallContext(
            title: "Контекст, который удалили",
            body: "Не должен появиться после перезапуска",
            isSelected: true
        )

        try store.save([context])
        try store.save([])

        XCTAssertEqual(try store.load(), [])
    }

    func testLoadThrowsForUnsupportedSchemaVersion() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let contextsURL = rootURL.appendingPathComponent("contexts.json")
        try Data(
            """
            {
              "schemaVersion": 999,
              "contexts": []
            }
            """.utf8
        ).write(to: contextsURL, options: .atomic)
        let store = ContextLibraryStore(rootURL: rootURL)

        XCTAssertThrowsError(try store.load())
    }

    func testRecoverySavePreservesUnreadableLibraryBeforeReplacement() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let contextsURL = rootURL.appendingPathComponent(ContextLibraryStore.filename)
        let unreadableData = Data("future-or-corrupt-library".utf8)
        try unreadableData.write(to: contextsURL, options: .atomic)
        let store = ContextLibraryStore(rootURL: rootURL)
        let replacement = [
            CallContext(title: "Recovered edit", body: "New library", isSelected: true)
        ]

        try store.save(replacement, preservingExistingAsRecovery: true)

        let recoveryURLs = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(ContextLibraryStore.recoveryFilenamePrefix)
        }
        XCTAssertEqual(recoveryURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(recoveryURLs.first)), unreadableData)
        XCTAssertEqual(try permissions(of: try XCTUnwrap(recoveryURLs.first)), 0o600)
        XCTAssertEqual(try store.load(), replacement)
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("AI Call Assistant", isDirectory: true)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
