import Foundation
import XCTest
@testable import AICallAssistant

final class RecordingStorageServiceTests: XCTestCase {
    func testSaveCreatesMetadataAndRoundTripsRecording() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = makeRecording(folderName: "2026-08-15_test-call")
        let service = RecordingStorageService(rootURL: rootURL)

        let metadataURL = try service.save(recording)

        XCTAssertEqual(metadataURL.lastPathComponent, "metadata.json")
        XCTAssertEqual(metadataURL.deletingLastPathComponent().lastPathComponent, recording.folderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertEqual(try service.load(folderName: recording.folderName), recording)
    }

    func testAudioURLsUseStandardM4AFilenamesInRecordingFolder() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = makeRecording(folderName: "audio-call")
        let service = RecordingStorageService(rootURL: rootURL)

        let urls = try service.audioURLs(for: recording)

        XCTAssertEqual(urls.combined, rootURL.appendingPathComponent("audio-call/combined.m4a"))
        XCTAssertEqual(urls.incoming, rootURL.appendingPathComponent("audio-call/incoming.m4a"))
        XCTAssertEqual(urls.outgoing, rootURL.appendingPathComponent("audio-call/outgoing.m4a"))
    }

    func testLoadAllIgnoresFoldersWithoutMetadataAndSortsNewestFirst() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let service = RecordingStorageService(rootURL: rootURL)
        let older = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startedAt: Date(timeIntervalSince1970: 100),
            folderName: "older"
        )
        let newer = makeRecording(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            startedAt: Date(timeIntervalSince1970: 200),
            folderName: "newer"
        )

        try service.save(older)
        try service.save(newer)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("unfinished", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(try service.loadAll(), [newer, older])
    }

    func testLoadAllReturnsEmptyArrayWhenRootDoesNotExist() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = RecordingStorageService(rootURL: rootURL)

        XCTAssertEqual(try service.loadAll(), [])
    }

    func testRejectsFolderNamesThatCouldEscapeRoot() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = makeRecording(folderName: "../outside")
        let service = RecordingStorageService(rootURL: rootURL)

        XCTAssertThrowsError(try service.save(recording)) { error in
            XCTAssertEqual(error as? RecordingStorageError, .invalidFolderName("../outside"))
        }
    }

    func testRejectsMetadataWhoseFolderDoesNotMatchItsDirectory() throws {
        let rootURL = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let service = RecordingStorageService(rootURL: rootURL)
        let recording = makeRecording(folderName: "original")
        let originalMetadataURL = try service.save(recording)
        let movedFolderURL = rootURL.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: movedFolderURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: originalMetadataURL,
            to: movedFolderURL.appendingPathComponent("metadata.json")
        )

        XCTAssertThrowsError(try service.load(folderName: "moved")) { error in
            XCTAssertEqual(
                error as? RecordingStorageError,
                .metadataFolderMismatch(expected: "moved", actual: "original")
            )
        }
    }

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("AI Call Assistant", isDirectory: true)
    }

    private func makeRecording(
        id: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSinceReferenceDate: 123_456.789),
        folderName: String
    ) -> Recording {
        Recording(
            id: id,
            title: "Test call",
            startedAt: startedAt,
            duration: 42.5,
            folderName: folderName,
            turns: [
                TranscriptTurn(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                    speaker: .participant,
                    timestamp: 3.5,
                    text: "Здравствуйте"
                )
            ]
        )
    }
}
