import Foundation
import XCTest
@testable import AICallAssistant

final class TranscriptFileServiceTests: XCTestCase {
    func testCreatesSpeakerSeparatedTranscript() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let recording = Recording(
            title: "Test",
            startedAt: Date(),
            duration: 12,
            folderName: "test-call",
            turns: [
                TranscriptTurn(speaker: .participant, timestamp: 2, text: "Вопрос"),
                TranscriptTurn(speaker: .you, timestamp: 5, text: "Ответ")
            ]
        )
        let service = TranscriptFileService(documentsURL: temporaryRoot)

        let url = try service.createTranscriptFile(for: recording)
        let text = try String(contentsOf: url)

        XCTAssertTrue(text.contains("[00:02] Собеседник"))
        XCTAssertTrue(text.contains("[00:05] Вы"))
    }

    func testDoesNotOverwriteAnExistingTranscript() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let recording = Recording(
            title: "Test",
            startedAt: Date(),
            duration: 1,
            folderName: "existing-call",
            turns: [TranscriptTurn(speaker: .you, timestamp: 0, text: "Generated")]
        )
        let service = TranscriptFileService(documentsURL: temporaryRoot)
        let url = try service.createTranscriptFile(for: recording)
        try "Моя редакция".write(to: url, atomically: true, encoding: .utf8)

        _ = try service.createTranscriptFile(for: recording)

        XCTAssertEqual(try String(contentsOf: url), "Моя редакция")
    }

    func testManagedUpdatePreservesManualEditAndWritesRevisionCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = TranscriptFileService(documentsURL: root)
        var recording = Recording(
            title: "Managed",
            startedAt: Date(),
            duration: 10,
            folderName: "managed",
            turns: [TranscriptTurn(speaker: .participant, timestamp: 0, text: "First")]
        )

        let transcriptURL = try service.updateManagedTranscriptFile(for: recording)
        try "Моя ручная правка".write(to: transcriptURL, atomically: true, encoding: .utf8)
        recording.turns = [TranscriptTurn(speaker: .participant, timestamp: 0, text: "Canonical")]

        _ = try service.updateManagedTranscriptFile(for: recording)

        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            "Моя ручная правка"
        )
        let candidate = root
            .appendingPathComponent("managed", isDirectory: true)
            .appendingPathComponent("transcript.generated.0.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(try String(contentsOf: candidate, encoding: .utf8).contains("Canonical"))
    }
}
