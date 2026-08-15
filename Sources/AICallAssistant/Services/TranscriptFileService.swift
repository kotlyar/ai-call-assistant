import AppKit
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

    func createTranscriptFile(for recording: Recording) throws -> URL {
        let folderURL = documentsURL.appendingPathComponent(recording.folderName, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let transcriptURL = folderURL.appendingPathComponent("transcript.txt")
        let body = recording.turns.map { turn in
            "[\(turn.timestamp.callTimecode)] \(turn.speaker.rawValue)\n\(turn.text)"
        }
        .joined(separator: "\n\n")

        try body.write(to: transcriptURL, atomically: true, encoding: String.Encoding.utf8)
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
}
