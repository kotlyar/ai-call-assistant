import Foundation

enum ContextLibraryStoreError: Error, Equatable, Sendable {
    case applicationSupportDirectoryUnavailable
    case unsupportedSchemaVersion(Int)
}

struct ContextLibraryStore: Sendable {
    static let applicationSupportDirectoryName = "com.aicallassistant.desktop"
    static let filename = "contexts.json"
    static let recoveryFilenamePrefix = "contexts.recovery."

    private let configuredRootURL: URL?

    init(rootURL: URL? = nil) {
        configuredRootURL = rootURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(
            Self.applicationSupportDirectoryName,
            isDirectory: true
        )
    }

    @discardableResult
    func save(
        _ contexts: [CallContext],
        preservingExistingAsRecovery: Bool = false
    ) throws -> URL {
        let fileManager = FileManager.default
        let rootURL = try resolvedRootURL()
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: rootURL.path
        )

        let document = ContextLibraryDocument(
            schemaVersion: ContextLibraryDocument.currentSchemaVersion,
            contexts: contexts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let destinationURL = rootURL.appendingPathComponent(
            Self.filename,
            isDirectory: false
        )
        if preservingExistingAsRecovery {
            try preserveExistingLibrary(
                at: destinationURL,
                in: rootURL,
                using: fileManager
            )
        }
        try data.write(to: destinationURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destinationURL.path
        )
        return destinationURL
    }

    func load() throws -> [CallContext] {
        let fileManager = FileManager.default
        let fileURL = try resolvedRootURL().appendingPathComponent(
            Self.filename,
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        let data = try Data(contentsOf: fileURL)
        let document = try JSONDecoder().decode(ContextLibraryDocument.self, from: data)
        guard document.schemaVersion == ContextLibraryDocument.currentSchemaVersion else {
            throw ContextLibraryStoreError.unsupportedSchemaVersion(document.schemaVersion)
        }
        return document.contexts
    }

    private func preserveExistingLibrary(
        at sourceURL: URL,
        in rootURL: URL,
        using fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }

        let recoveryURL = rootURL.appendingPathComponent(
            "\(Self.recoveryFilenamePrefix)\(UUID().uuidString).json",
            isDirectory: false
        )
        try fileManager.copyItem(at: sourceURL, to: recoveryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: recoveryURL.path
        )
    }

    private func resolvedRootURL() throws -> URL {
        guard let configuredRootURL else {
            throw ContextLibraryStoreError.applicationSupportDirectoryUnavailable
        }
        return configuredRootURL
    }
}

actor ContextLibraryWriter {
    private let store: ContextLibraryStore
    private var latestSavedRevision: Int64 = -1
    private var hasPreservedRecovery = false

    init(store: ContextLibraryStore) {
        self.store = store
    }

    func save(
        _ contexts: [CallContext],
        revision: Int64,
        preservingExistingAsRecovery: Bool = false
    ) throws {
        guard revision > latestSavedRevision else { return }
        let shouldPreserveRecovery = preservingExistingAsRecovery
            && !hasPreservedRecovery
        try store.save(
            contexts,
            preservingExistingAsRecovery: shouldPreserveRecovery
        )
        if shouldPreserveRecovery {
            hasPreservedRecovery = true
        }
        latestSavedRevision = revision
    }
}

private struct ContextLibraryDocument: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let contexts: [CallContext]
}
