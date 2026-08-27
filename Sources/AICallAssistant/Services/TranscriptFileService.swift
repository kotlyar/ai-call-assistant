import AppKit
import CryptoKit
import Foundation

struct TranscriptFileService {
    let fileManager: FileManager
    let documentsURL: URL

    init(fileManager: FileManager = .default, documentsURL: URL? = nil) {
        self.fileManager = fileManager
        self.documentsURL = documentsURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AI Call Assistant", isDirectory: true)
    }

    func createTranscriptFile(for recording: Recording, overwrite: Bool = false) throws -> URL {
        let folderURL = documentsURL.appendingPathComponent(recording.folderName, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let transcriptURL = folderURL.appendingPathComponent("transcript.txt")
        if !overwrite, fileManager.fileExists(atPath: transcriptURL.path) {
            return transcriptURL
        }
        let body = transcriptBody(for: recording)

        try body.write(to: transcriptURL, atomically: true, encoding: String.Encoding.utf8)
        return transcriptURL
    }

    /// Updates the generated transcript only when the on-disk file still
    /// matches the last generated hash. A manual edit is preserved and the new
    /// generated revision is written beside it for explicit comparison.
    func updateManagedTranscriptFile(for recording: Recording) throws -> URL {
        let folderURL = documentsURL.appendingPathComponent(recording.folderName, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let transcriptURL = folderURL.appendingPathComponent("transcript.txt")
        let stateURL = folderURL.appendingPathComponent("transcript.generated-state.json")
        let body = transcriptBody(for: recording)
        let bodyHash = Self.sha256(body)
        let revision = recording.transcription?.canonicalRevision
            ?? recording.transcription?.liveRevision
            ?? 0

        if fileManager.fileExists(atPath: transcriptURL.path) {
            let current = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
            let state = try? JSONDecoder().decode(
                ManagedTranscriptState.self,
                from: Data(contentsOf: stateURL)
            )
            if state == nil || state?.contentSHA256 != Self.sha256(current) {
                let candidate = folderURL.appendingPathComponent(
                    "transcript.generated.\(revision).txt"
                )
                try body.write(to: candidate, atomically: true, encoding: .utf8)
                return transcriptURL
            }
        }

        try body.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let state = ManagedTranscriptState(
            revision: revision,
            contentSHA256: bodyHash,
            updatedAt: Date()
        )
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        return transcriptURL
    }

    func folderURL(for recording: Recording) -> URL {
        documentsURL.appendingPathComponent(recording.folderName, isDirectory: true)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func transcriptBody(for recording: Recording) -> String {
        recording.turns.map { turn in
            "[\(turn.timestamp.callTimecode)] \(turn.speaker.rawValue)\n\(turn.text)"
        }
        .joined(separator: "\n\n")
    }

    private static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct ManagedTranscriptState: Codable {
    let revision: Int64
    let contentSHA256: String
    let updatedAt: Date
}
