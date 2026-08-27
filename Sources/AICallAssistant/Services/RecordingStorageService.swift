import Foundation

struct RecordingAudioURLs: Equatable {
    let combined: URL
    let incoming: URL
    let outgoing: URL
}

enum RecordingStorageError: Error, Equatable {
    case invalidFolderName(String)
    case metadataFolderMismatch(expected: String, actual: String)
}

struct RecordingStorageService {
    static let applicationFolderName = "AI Call Assistant"
    static let metadataFilename = "metadata.json"

    let fileManager: FileManager
    let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Self.applicationFolderName, isDirectory: true)
    }

    @discardableResult
    func save(_ recording: Recording) throws -> URL {
        let metadataURL = try metadataURL(forFolderNamed: recording.folderName)
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recording)
        try data.write(to: metadataURL, options: .atomic)
        return metadataURL
    }

    func load(folderName: String) throws -> Recording {
        let url = try metadataURL(forFolderNamed: folderName)
        return try loadMetadata(at: url, expectedFolderName: folderName)
    }

    func loadAll() throws -> [Recording] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        let folderURLs = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        let recordings = folderURLs.compactMap { folderURL -> Recording? in
            guard let values = try? folderURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else { return nil }
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }

            let metadataURL = folderURL.appendingPathComponent(Self.metadataFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
            return try? loadMetadata(at: metadataURL, expectedFolderName: folderURL.lastPathComponent)
        }

        return recordings.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startedAt > $1.startedAt
        }
    }

    func folderURL(for recording: Recording) throws -> URL {
        try folderURL(named: recording.folderName)
    }

    func metadataURL(for recording: Recording) throws -> URL {
        try metadataURL(forFolderNamed: recording.folderName)
    }

    func audioURLs(for recording: Recording) throws -> RecordingAudioURLs {
        let folderURL = try folderURL(for: recording)
        return RecordingAudioURLs(
            combined: folderURL.appendingPathComponent("combined.m4a", isDirectory: false),
            incoming: folderURL.appendingPathComponent("incoming.m4a", isDirectory: false),
            outgoing: folderURL.appendingPathComponent("outgoing.m4a", isDirectory: false)
        )
    }

    private func folderURL(named folderName: String) throws -> URL {
        try validate(folderName: folderName)
        return rootURL.appendingPathComponent(folderName, isDirectory: true)
    }

    private func metadataURL(forFolderNamed folderName: String) throws -> URL {
        try folderURL(named: folderName)
            .appendingPathComponent(Self.metadataFilename, isDirectory: false)
    }

    private func loadMetadata(at url: URL, expectedFolderName: String) throws -> Recording {
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder().decode(Recording.self, from: data)
        guard recording.folderName == expectedFolderName else {
            throw RecordingStorageError.metadataFolderMismatch(
                expected: expectedFolderName,
                actual: recording.folderName
            )
        }
        return recording
    }

    private func validate(folderName: String) throws {
        let trimmedName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              folderName != ".",
              folderName != "..",
              !folderName.contains("/"),
              !folderName.contains("\\"),
              !folderName.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RecordingStorageError.invalidFolderName(folderName)
        }
    }
}
