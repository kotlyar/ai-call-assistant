@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import AICallAssistant

final class OpenAIFileTranscriptionProviderTests: XCTestCase {
    func testDefaultProductionInitializerIsAvailable() {
        _ = OpenAIFileTranscriptionProvider()
    }

    func testExporterClampsRoundedNanosecondTailToExactAssetDuration() throws {
        // This is the exact duration/timescale from the previously failing
        // outgoing recording. Its rounded persisted nanoseconds are 0.333 ns
        // beyond the exact media duration.
        let sourceDuration = CMTime(value: 1_160_372, timescale: 48_000)
        let requestedRange = AudioSourceRange(
            startNanoseconds: 0,
            endNanoseconds: 24_174_416_667
        )

        let effective = try AVFoundationReconciliationAudioRangeExporter
            .effectiveTimeRange(
                requestedRange: requestedRange,
                sourceDuration: sourceDuration
            )

        XCTAssertEqual(CMTimeCompare(effective.start, .zero), 0)
        XCTAssertEqual(CMTimeCompare(effective.end, sourceDuration), 0)
    }

    func testExporterRejectsTailBeyondOneSourceTick() {
        let sourceDuration = CMTime(value: 1_160_372, timescale: 48_000)
        let requestedRange = AudioSourceRange(
            startNanoseconds: 0,
            endNanoseconds: 24_174_500_000
        )

        XCTAssertThrowsError(
            try AVFoundationReconciliationAudioRangeExporter.effectiveTimeRange(
                requestedRange: requestedRange,
                sourceDuration: sourceDuration
            )
        )
    }

    func testExporterCopiesCompleteShortM4AWithoutReencoding() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AVFoundationReconciliationAudioRangeExporterTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = rootURL.appendingPathComponent("source.m4a")
        let destinationURL = rootURL.appendingPathComponent("destination.m4a")
        try XCTUnwrap(Data(base64Encoded: Self.shortM4AFixtureBase64))
            .write(to: sourceURL)

        let sourceDuration = try await AVURLAsset(url: sourceURL).load(.duration)
        let roundedNanoseconds = UInt64(
            (sourceDuration.seconds * 1_000_000_000).rounded()
        )
        try await AVFoundationReconciliationAudioRangeExporter().exportM4A(
            sourceURL: sourceURL,
            range: AudioSourceRange(
                startNanoseconds: 0,
                endNanoseconds: roundedNanoseconds
            ),
            destinationURL: destinationURL
        )

        XCTAssertEqual(
            try Data(contentsOf: destinationURL),
            try Data(contentsOf: sourceURL),
            "A complete short recording should be uploaded verbatim"
        )
    }

    func testWhisperExportsExactRangeRequestsSegmentsAndConvertsSecondsToNanoseconds() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let audioPayload = Data("exported-audio-marker".utf8)
        let exporter = RecordingAudioRangeExporter(payload: audioPayload)
        let response = Data(
            #"{"segments":[{"start":0.125,"end":1.5,"text":" First"},{"start":1.5,"end":2.0,"text":"second"}]}"#.utf8
        )
        let network = RecordingTranscriptionNetwork(
            statusCode: 200,
            responseBody: response,
            responseHeaders: ["x-request-id": "request_123"]
        )
        let endpoint = URL(string: "https://api.openai.test/v1/audio/transcriptions")!
        let provider = OpenAIFileTranscriptionProvider(
            network: network,
            exporter: exporter,
            endpoint: endpoint,
            temporaryDirectory: fixture.temporaryDirectory
        )
        let request = makeRequest(sourceURL: fixture.sourceURL, modelID: "whisper-1")

        let result = try await provider.transcribe(request: request)

        XCTAssertEqual(result.providerResultID, "request_123")
        XCTAssertEqual(result.segments, [
            FileTranscriptionSegment(
                startOffsetNanoseconds: 125_000_000,
                endOffsetNanoseconds: 1_500_000_000,
                text: " First"
            ),
            FileTranscriptionSegment(
                startOffsetNanoseconds: 1_500_000_000,
                endOffsetNanoseconds: 2_000_000_000,
                text: "second"
            )
        ])

        let exportedRange = await exporter.exportedRange()
        XCTAssertEqual(exportedRange, request.chunk.uploadRange)

        let optionalCapturedRequest = await network.capturedRequest()
        let capturedRequest = try XCTUnwrap(optionalCapturedRequest)
        XCTAssertEqual(capturedRequest.url, endpoint)
        XCTAssertEqual(capturedRequest.httpMethod, "POST")
        XCTAssertEqual(
            capturedRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-api-credential"
        )
        XCTAssertEqual(
            capturedRequest.value(forHTTPHeaderField: "Cache-Control"),
            "no-store"
        )
        let contentType = try XCTUnwrap(
            capturedRequest.value(forHTTPHeaderField: "Content-Type")
        )
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try XCTUnwrap(capturedRequest.httpBody)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(bodyText.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        XCTAssertTrue(
            bodyText.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment")
        )
        XCTAssertFalse(bodyText.contains("name=\"languages[]\""))
        XCTAssertTrue(bodyText.contains("filename=\"audio.m4a\""))
        XCTAssertNotNil(body.range(of: audioPayload))
        XCTAssertTrue(try directoryIsEmpty(fixture.temporaryDirectory))
    }

    func testGPTTranscribeUsesDefaultJSONAndReturnsOneFullRangeSegment() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let exporter = RecordingAudioRangeExporter(payload: Data("audio".utf8))
        let response = Data(
            #"{"text":"Bonjour, pouvez-vous m'entendre ?","languages":[{"code":"fr"}]}"#.utf8
        )
        let network = RecordingTranscriptionNetwork(statusCode: 200, responseBody: response)
        let provider = OpenAIFileTranscriptionProvider(
            network: network,
            exporter: exporter,
            temporaryDirectory: fixture.temporaryDirectory
        )
        let request = makeRequest(sourceURL: fixture.sourceURL, modelID: "gpt-transcribe")

        let result = try await provider.transcribe(request: request)

        XCTAssertEqual(result.segments, [FileTranscriptionSegment(
            startOffsetNanoseconds: 0,
            endOffsetNanoseconds: request.chunk.uploadRange.durationNanoseconds,
            text: "Bonjour, pouvez-vous m'entendre ?"
        )])
        let optionalCapturedRequest = await network.capturedRequest()
        let capturedRequest = try XCTUnwrap(optionalCapturedRequest)
        let body = try XCTUnwrap(capturedRequest.httpBody)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        XCTAssertFalse(bodyText.contains("name=\"response_format\""))
        XCTAssertFalse(bodyText.contains("name=\"timestamp_granularities[]\""))
        XCTAssertTrue(bodyText.contains("name=\"languages[]\"\r\n\r\nru"))
        XCTAssertTrue(bodyText.contains("name=\"languages[]\"\r\n\r\nen"))
        XCTAssertTrue(try directoryIsEmpty(fixture.temporaryDirectory))
    }

    func testRejectsAudioAtUploadLimitBeforeNetworkAndCleansTemporaryFiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let exporter = RecordingAudioRangeExporter(payload: Data(repeating: 0x41, count: 32))
        let network = RecordingTranscriptionNetwork(statusCode: 200, responseBody: Data())
        let provider = OpenAIFileTranscriptionProvider(
            network: network,
            exporter: exporter,
            temporaryDirectory: fixture.temporaryDirectory,
            maximumUploadBytes: 32
        )

        do {
            _ = try await provider.transcribe(
                request: makeRequest(sourceURL: fixture.sourceURL)
            )
            XCTFail("Expected the strict upload limit to reject the file")
        } catch let error as OpenAIFileTranscriptionProviderError {
            XCTAssertEqual(error, .uploadTooLarge)
            XCTAssertFalse(error.isRetryableForReconciliation)
            XCTAssertEqual(
                error.reconciliationFailureCode,
                "file_transcription_upload_too_large"
            )
        }

        let requestCount = await network.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(try directoryIsEmpty(fixture.temporaryDirectory))
    }

    func testHTTPFailuresHaveStableSanitizedRetryClassification() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let cases: [(Int, OpenAIFileTranscriptionProviderError, Bool)] = [
            (401, .authenticationFailed, false),
            (422, .requestRejected, false),
            (429, .rateLimited, true),
            (503, .serviceUnavailable, true)
        ]

        for (statusCode, expectedError, retryable) in cases {
            let network = RecordingTranscriptionNetwork(
                statusCode: statusCode,
                responseBody: Data(#"{"error":{"message":"sensitive provider detail"}}"#.utf8)
            )
            let provider = OpenAIFileTranscriptionProvider(
                network: network,
                exporter: RecordingAudioRangeExporter(payload: Data("audio".utf8)),
                temporaryDirectory: fixture.temporaryDirectory
            )

            do {
                _ = try await provider.transcribe(
                    request: makeRequest(sourceURL: fixture.sourceURL)
                )
                XCTFail("Expected HTTP status \(statusCode) to fail")
            } catch let error as OpenAIFileTranscriptionProviderError {
                XCTAssertEqual(error, expectedError)
                XCTAssertEqual(error.isRetryableForReconciliation, retryable)
                XCTAssertEqual(
                    error.reconciliationBlockingReason,
                    statusCode == 401 ? .credential : nil
                )
                XCTAssertFalse(error.localizedDescription.contains("sensitive provider detail"))
                XCTAssertFalse(error.localizedDescription.contains("test-api-credential"))
            }
            XCTAssertTrue(try directoryIsEmpty(fixture.temporaryDirectory))
        }
    }

    func testTransportErrorIsSanitizedAndRetryable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sensitiveMarker = "transport-secret-marker"
        let network = RecordingTranscriptionNetwork(
            failure: SensitiveTestFailure(value: sensitiveMarker)
        )
        let provider = OpenAIFileTranscriptionProvider(
            network: network,
            exporter: RecordingAudioRangeExporter(payload: Data("audio".utf8)),
            temporaryDirectory: fixture.temporaryDirectory
        )

        do {
            _ = try await provider.transcribe(
                request: makeRequest(sourceURL: fixture.sourceURL)
            )
            XCTFail("Expected a transport failure")
        } catch let error as OpenAIFileTranscriptionProviderError {
            XCTAssertEqual(error, .transportFailure)
            XCTAssertTrue(error.isRetryableForReconciliation)
            XCTAssertFalse(error.localizedDescription.contains(sensitiveMarker))
            XCTAssertFalse(String(describing: error).contains(sensitiveMarker))
        }
        XCTAssertTrue(try directoryIsEmpty(fixture.temporaryDirectory))
    }

    func testRejectsOutOfRangeProviderTimestamp() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let response = Data(
            #"{"segments":[{"start":0.0,"end":2.0000001,"text":"outside"}]}"#.utf8
        )
        let provider = OpenAIFileTranscriptionProvider(
            network: RecordingTranscriptionNetwork(statusCode: 200, responseBody: response),
            exporter: RecordingAudioRangeExporter(payload: Data("audio".utf8)),
            temporaryDirectory: fixture.temporaryDirectory
        )

        do {
            _ = try await provider.transcribe(
                request: makeRequest(sourceURL: fixture.sourceURL, modelID: "whisper-1")
            )
            XCTFail("Expected invalid timestamps to fail")
        } catch let error as OpenAIFileTranscriptionProviderError {
            XCTAssertEqual(error, .invalidSegmentTimestamp)
            XCTAssertFalse(error.isRetryableForReconciliation)
        }
        XCTAssertTrue(try directoryIsEmpty(fixture.temporaryDirectory))
    }

    func testCancellationRemovesTemporaryExport() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let exporter = CancellableAudioRangeExporter()
        let provider = OpenAIFileTranscriptionProvider(
            network: RecordingTranscriptionNetwork(statusCode: 200, responseBody: Data()),
            exporter: exporter,
            temporaryDirectory: fixture.temporaryDirectory
        )
        let request = makeRequest(sourceURL: fixture.sourceURL)
        let task = Task {
            try await provider.transcribe(request: request)
        }

        while !(await exporter.hasStarted()) {
            await Task.yield()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(type(of: error))")
        }
        XCTAssertTrue(try directoryIsEmpty(fixture.temporaryDirectory))
    }

    private func makeRequest(
        sourceURL: URL,
        modelID: String = "gpt-transcribe"
    ) -> FileTranscriptionRequest {
        let uploadRange = AudioSourceRange(
            startNanoseconds: 3_000_000_000,
            endNanoseconds: 5_000_000_000
        )
        return FileTranscriptionRequest(
            callID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            jobID: "job-1",
            idempotencyKey: "chunk-1",
            modelID: modelID,
            languages: ["ru", "en"],
            asset: ReconciliationAudioAsset(
                track: .incoming,
                fileURL: sourceURL,
                sourceDurationNanoseconds: 10_000_000_000,
                sourceByteCount: 1_000,
                sourceSHA256: "sha256-test",
                callStartOffsetNanoseconds: 0
            ),
            chunk: AudioTrackChunkDescriptor(
                id: "chunk-1",
                track: .incoming,
                coverageRange: uploadRange,
                uploadRange: uploadRange,
                estimatedUploadBytes: 200,
                vadClassifiedSpeech: true,
                usedVADPreferredBoundary: false,
                chunkerVersion: 1
            ),
            attempt: 1,
            apiKey: "test-api-credential"
        )
    }

    private func makeFixture() throws -> (
        rootURL: URL,
        sourceURL: URL,
        temporaryDirectory: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenAIFileTranscriptionProviderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporaryDirectory = rootURL.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = rootURL.appendingPathComponent("source.m4a")
        try Data("source-placeholder".utf8).write(to: sourceURL)
        return (rootURL, sourceURL, temporaryDirectory)
    }

    private func directoryIsEmpty(_ url: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).isEmpty
    }

    /// 110 ms of mono AAC silence, generated specifically for this test.
    private static let shortM4AFixtureBase64 =
        "AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAANW1kYXTeAgBMYXZjNjIuMTEuMTAwAAIwQA4BGCAHARggBwEYIAcBGCAHARggBwEYIAcAAAMWbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAG4AAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAkF0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAG4AAAAAAAAAAAAAAAEBAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAABuAAAEAAABAAAAAAG5bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAC7gAAAGKBVxAAAAAAALWhkbHIAAAAAAAAAAHNvdW4AAAAAAAAAAAAAAABTb3VuZEhhbmRsZXIAAAABZG1pbmYAAAAQc21oZAAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABKHN0YmwAAABqc3RzZAAAAAAAAAABAAAAWm1wNGEAAAAAAAAAAQAAAAAAAAAAAAEAEAAAAAC7gAAAAAAANmVzZHMAAAAAA4CAgCUAAQAEgICAF0AVAAAAAAB9AAAACrUFgICABRGIVuUABoCAgAECAAAAIHN0dHMAAAAAAAAAAgAAAAYAAAQAAAAAAQAAAKAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAcAAAABAAAAMHN0c3oAAAAAAAAAAAAAAAcAAAAVAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAAFHN0Y28AAAAAAAAAAQAAACwAAAAac2dwZAEAAAByb2xsAAAAAgAAAAH//wAAABxzYmdwAAAAAHJvbGwAAAABAAAABwAAAAEAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYyLjMuMTAw"
}

private actor RecordingAudioRangeExporter: ReconciliationAudioRangeExporter {
    private let payload: Data
    private var range: AudioSourceRange?

    init(payload: Data) {
        self.payload = payload
    }

    func exportM4A(
        sourceURL: URL,
        range: AudioSourceRange,
        destinationURL: URL
    ) async throws {
        self.range = range
        try payload.write(to: destinationURL)
    }

    func exportedRange() -> AudioSourceRange? {
        range
    }
}

private actor CancellableAudioRangeExporter: ReconciliationAudioRangeExporter {
    private var started = false

    func exportM4A(
        sourceURL: URL,
        range: AudioSourceRange,
        destinationURL: URL
    ) async throws {
        try Data("partial-export".utf8).write(to: destinationURL)
        started = true
        while !Task.isCancelled {
            await Task.yield()
        }
        throw CancellationError()
    }

    func hasStarted() -> Bool {
        started
    }
}

private actor RecordingTranscriptionNetwork: OpenAIFileTranscriptionNetworking {
    private let statusCode: Int
    private let responseBody: Data
    private let responseHeaders: [String: String]
    private let failure: (any Error & Sendable)?
    private var requests: [URLRequest] = []

    init(
        statusCode: Int,
        responseBody: Data,
        responseHeaders: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.responseBody = responseBody
        self.responseHeaders = responseHeaders
        failure = nil
    }

    init(failure: any Error & Sendable) {
        statusCode = 0
        responseBody = Data()
        responseHeaders = [:]
        self.failure = failure
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let failure {
            throw failure
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        )!
        return (responseBody, response)
    }

    func capturedRequest() -> URLRequest? {
        requests.last
    }

    func requestCount() -> Int {
        requests.count
    }
}

private struct SensitiveTestFailure: Error, LocalizedError, Sendable {
    let value: String

    var errorDescription: String? { value }
}
