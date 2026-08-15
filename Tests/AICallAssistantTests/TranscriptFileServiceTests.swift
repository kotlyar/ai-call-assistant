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
}
