@preconcurrency import AVFoundation
import Foundation

enum OpenAIFileTranscriptionProviderError: Error, Equatable, LocalizedError, Sendable {
    case invalidRequest
    case credentialMissing
    case sourceUnavailable
    case temporaryStorageUnavailable
    case exportFailed
    case uploadTooLarge
    case transportFailure
    case invalidHTTPResponse
    case responseTooLarge
    case authenticationFailed
    case rateLimited
    case serviceUnavailable
    case requestRejected
    case malformedResponse
    case invalidSegmentTimestamp

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "The file transcription request is invalid."
        case .credentialMissing:
            return "An OpenAI API credential is required."
        case .sourceUnavailable:
            return "The source audio is unavailable."
        case .temporaryStorageUnavailable:
            return "Temporary storage is unavailable."
        case .exportFailed:
            return "The requested audio range could not be exported."
        case .uploadTooLarge:
            return "The exported audio exceeds the upload limit."
        case .transportFailure:
            return "The transcription service could not be reached."
        case .invalidHTTPResponse:
            return "The transcription service returned an invalid HTTP response."
        case .responseTooLarge:
            return "The transcription response exceeded the allowed size."
        case .authenticationFailed:
            return "The transcription service rejected the credential."
        case .rateLimited:
            return "The transcription service rate limit was reached."
        case .serviceUnavailable:
            return "The transcription service is temporarily unavailable."
        case .requestRejected:
            return "The transcription service rejected the request."
        case .malformedResponse:
            return "The transcription service returned an invalid response."
        case .invalidSegmentTimestamp:
            return "The transcription service returned an invalid segment timestamp."
        }
    }
}

extension OpenAIFileTranscriptionProviderError: FileTranscriptionFailure {
    var reconciliationFailureCode: String {
        switch self {
        case .invalidRequest:
            return "file_transcription_invalid_request"
        case .credentialMissing:
            return "credential_missing"
        case .sourceUnavailable:
            return "file_transcription_source_unavailable"
        case .temporaryStorageUnavailable:
            return "file_transcription_temporary_storage_unavailable"
        case .exportFailed:
            return "file_transcription_export_failed"
        case .uploadTooLarge:
            return "file_transcription_upload_too_large"
        case .transportFailure:
            return "file_transcription_transport_failure"
        case .invalidHTTPResponse:
            return "file_transcription_invalid_http_response"
        case .responseTooLarge:
            return "file_transcription_response_too_large"
        case .authenticationFailed:
            return "file_transcription_authentication_failed"
        case .rateLimited:
            return "file_transcription_rate_limited"
        case .serviceUnavailable:
            return "file_transcription_service_unavailable"
        case .requestRejected:
            return "file_transcription_request_rejected"
        case .malformedResponse:
            return "file_transcription_malformed_response"
        case .invalidSegmentTimestamp:
            return "file_transcription_invalid_segment_timestamp"
        }
    }

    var isRetryableForReconciliation: Bool {
        switch self {
        case .temporaryStorageUnavailable,
             .transportFailure,
             .invalidHTTPResponse,
             .responseTooLarge,
             .rateLimited,
             .serviceUnavailable,
             .malformedResponse:
            return true
        case .invalidRequest,
             .credentialMissing,
             .sourceUnavailable,
             .exportFailed,
             .uploadTooLarge,
             .authenticationFailed,
             .requestRejected,
             .invalidSegmentTimestamp:
            return false
        }
    }

    var reconciliationBlockingReason: FileTranscriptionBlockingReason? {
        switch self {
        case .credentialMissing, .authenticationFailed:
            return .credential
        default:
            return nil
        }
    }
}

protocol ReconciliationAudioRangeExporter: Sendable {
    func exportM4A(
        sourceURL: URL,
        range: AudioSourceRange,
        destinationURL: URL
    ) async throws
}

struct AVFoundationReconciliationAudioRangeExporter: ReconciliationAudioRangeExporter {
    func exportM4A(
        sourceURL: URL,
        range: AudioSourceRange,
        destinationURL: URL
    ) async throws {
        guard
            range.durationNanoseconds > 0,
            range.endNanoseconds <= UInt64(Int64.max)
        else {
            throw AudioRangeExportError.invalidRange
        }

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceDuration: CMTime
        do {
            sourceDuration = try await sourceAsset.load(.duration)
        } catch {
            throw AudioRangeExportError.unreadableSource
        }
        guard sourceDuration.isValid, !sourceDuration.isIndefinite else {
            throw AudioRangeExportError.unreadableSource
        }

        let timeRange = try Self.effectiveTimeRange(
            requestedRange: range,
            sourceDuration: sourceDuration
        )

        // Short calls normally produce a single chunk covering the complete
        // source. Preserve that finalized M4A verbatim instead of needlessly
        // asking AVFoundation to decode and re-encode it.
        if CMTimeCompare(timeRange.start, .zero) == 0,
           CMTimeCompare(timeRange.end, sourceDuration) == 0 {
            do {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return
            } catch {
                throw AudioRangeExportError.exportFailed
            }
        }

        guard let exportSession = AVAssetExportSession(
            asset: sourceAsset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioRangeExportError.exportUnavailable
        }
        try? FileManager.default.removeItem(at: destinationURL)
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.timeRange = timeRange
        let cancellationBox = AVAssetExportSessionCancellationBox(exportSession)

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                exportSession.exportAsynchronously {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancellationBox.cancel()
        }
        try Task.checkCancellation()

        guard exportSession.status == .completed else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw AudioRangeExportError.exportFailed
        }
    }

    /// Reconciliation stores durations as integer nanoseconds. Media durations
    /// commonly use an audio timescale (for example 1/48,000 second), so a
    /// round-trip can put the requested tail just above or below the exact
    /// CMTime. Snap only that one-source-tick rounding difference; larger
    /// out-of-bounds requests remain invalid.
    static func effectiveTimeRange(
        requestedRange range: AudioSourceRange,
        sourceDuration: CMTime
    ) throws -> CMTimeRange {
        guard sourceDuration.isValid,
              !sourceDuration.isIndefinite,
              sourceDuration.seconds.isFinite,
              CMTimeCompare(sourceDuration, .zero) > 0,
              range.durationNanoseconds > 0,
              range.endNanoseconds <= UInt64(Int64.max) else {
            throw AudioRangeExportError.invalidRange
        }

        let start = CMTime(
            value: Int64(range.startNanoseconds),
            timescale: 1_000_000_000
        )
        let requestedEnd = CMTime(
            value: Int64(range.endNanoseconds),
            timescale: 1_000_000_000
        )
        guard CMTimeCompare(start, .zero) >= 0,
              CMTimeCompare(start, sourceDuration) < 0 else {
            throw AudioRangeExportError.invalidRange
        }

        let oneSourceTick = CMTime(
            value: 1,
            timescale: max(sourceDuration.timescale, 1)
        )
        let endDifference = CMTimeAbsoluteValue(
            CMTimeSubtract(requestedEnd, sourceDuration)
        )
        let effectiveEnd: CMTime
        if CMTimeCompare(endDifference, oneSourceTick) <= 0 {
            effectiveEnd = sourceDuration
        } else if CMTimeCompare(requestedEnd, sourceDuration) > 0 {
            throw AudioRangeExportError.invalidRange
        } else {
            effectiveEnd = requestedEnd
        }
        guard CMTimeCompare(effectiveEnd, start) > 0 else {
            throw AudioRangeExportError.invalidRange
        }
        return CMTimeRangeFromTimeToTime(start: start, end: effectiveEnd)
    }
}

private final class AVAssetExportSessionCancellationBox: @unchecked Sendable {
    private let exportSession: AVAssetExportSession

    init(_ exportSession: AVAssetExportSession) {
        self.exportSession = exportSession
    }

    func cancel() {
        exportSession.cancelExport()
    }
}

private enum AudioRangeExportError: Error {
    case invalidRange
    case unreadableSource
    case exportUnavailable
    case exportFailed
}

protocol OpenAIFileTranscriptionNetworking: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OpenAIFileTranscriptionNetworking {}

struct OpenAIFileTranscriptionProvider: FileTranscriptionProvider {
    /// The provider rejects a file whose byte count is equal to this boundary,
    /// keeping every uploaded audio part strictly below the documented 25 MB limit.
    static let defaultMaximumUploadBytes = 25_000_000

    private let network: any OpenAIFileTranscriptionNetworking
    private let exporter: any ReconciliationAudioRangeExporter
    private let endpoint: URL
    private let temporaryDirectory: URL
    private let maximumUploadBytes: Int
    private let maximumResponseBytes: Int

    init(
        session: URLSession = .shared,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        network = session
        exporter = AVFoundationReconciliationAudioRangeExporter()
        endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        self.temporaryDirectory = temporaryDirectory
        maximumUploadBytes = Self.defaultMaximumUploadBytes
        maximumResponseBytes = 2_000_000
    }

    init(
        network: any OpenAIFileTranscriptionNetworking,
        exporter: any ReconciliationAudioRangeExporter,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
        temporaryDirectory: URL,
        maximumUploadBytes: Int = OpenAIFileTranscriptionProvider.defaultMaximumUploadBytes,
        maximumResponseBytes: Int = 2_000_000
    ) {
        self.network = network
        self.exporter = exporter
        self.endpoint = endpoint
        self.temporaryDirectory = temporaryDirectory
        self.maximumUploadBytes = maximumUploadBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    func transcribe(
        request: FileTranscriptionRequest
    ) async throws -> FileTranscriptionResult {
        try validate(request)

        let workDirectory = temporaryDirectory.appendingPathComponent(
            "OpenAIFileTranscription-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw OpenAIFileTranscriptionProviderError.temporaryStorageUnavailable
        }
        defer {
            try? FileManager.default.removeItem(at: workDirectory)
        }

        let exportedAudioURL = workDirectory.appendingPathComponent("audio.m4a")
        do {
            try await exporter.exportM4A(
                sourceURL: request.asset.fileURL,
                range: request.chunk.uploadRange,
                destinationURL: exportedAudioURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenAIFileTranscriptionProviderError.exportFailed
        }

        let audioData: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: exportedAudioURL.path
            )
            guard
                let byteCount = attributes[.size] as? NSNumber,
                byteCount.int64Value >= 0,
                byteCount.int64Value < Int64(maximumUploadBytes)
            else {
                throw OpenAIFileTranscriptionProviderError.uploadTooLarge
            }
            audioData = try Data(contentsOf: exportedAudioURL, options: .mappedIfSafe)
        } catch let error as OpenAIFileTranscriptionProviderError {
            throw error
        } catch {
            throw OpenAIFileTranscriptionProviderError.exportFailed
        }
        guard audioData.count < maximumUploadBytes else {
            throw OpenAIFileTranscriptionProviderError.uploadTooLarge
        }

        let boundary = "OpenAIFileTranscriptionBoundary-\(UUID().uuidString)"
        let body = MultipartTranscriptionBody.make(
            boundary: boundary,
            modelID: request.modelID,
            languages: request.modelID == "gpt-transcribe" ? request.languages : [],
            audioData: audioData,
            requestsSegmentTimestamps: request.modelID == "whisper-1"
        )
        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.setValue(
            "Bearer \(request.apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let responseBody: Data
        let response: URLResponse
        do {
            (responseBody, response) = try await network.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenAIFileTranscriptionProviderError.transportFailure
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIFileTranscriptionProviderError.invalidHTTPResponse
        }
        guard responseBody.count <= maximumResponseBytes else {
            throw OpenAIFileTranscriptionProviderError.responseTooLarge
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.classifyHTTPStatus(httpResponse.statusCode)
        }

        let envelope: TranscriptionEnvelope
        do {
            envelope = try JSONDecoder().decode(TranscriptionEnvelope.self, from: responseBody)
        } catch {
            throw OpenAIFileTranscriptionProviderError.malformedResponse
        }
        let maximumOffset = request.chunk.uploadRange.durationNanoseconds
        let segments: [FileTranscriptionSegment]
        if request.modelID == "whisper-1" {
            guard let providerSegments = envelope.segments else {
                throw OpenAIFileTranscriptionProviderError.malformedResponse
            }
            segments = try providerSegments.map { segment in
                let start = try Self.nanoseconds(
                    fromSeconds: segment.start,
                    maximum: maximumOffset
                )
                let end = try Self.nanoseconds(
                    fromSeconds: segment.end,
                    maximum: maximumOffset
                )
                guard end >= start else {
                    throw OpenAIFileTranscriptionProviderError.invalidSegmentTimestamp
                }
                return FileTranscriptionSegment(
                    startOffsetNanoseconds: start,
                    endOffsetNanoseconds: end,
                    text: segment.text
                )
            }
        } else {
            guard let text = envelope.text else {
                throw OpenAIFileTranscriptionProviderError.malformedResponse
            }
            segments = [FileTranscriptionSegment(
                startOffsetNanoseconds: 0,
                endOffsetNanoseconds: maximumOffset,
                text: text
            )]
        }

        return FileTranscriptionResult(
            providerResultID: envelope.id
                ?? httpResponse.value(forHTTPHeaderField: "x-request-id"),
            segments: segments
        )
    }

    private func validate(_ request: FileTranscriptionRequest) throws {
        guard
            !request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OpenAIFileTranscriptionProviderError.credentialMissing
        }
        guard
            !request.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            request.asset.track == request.chunk.track,
            request.chunk.uploadRange.durationNanoseconds > 0,
            request.chunk.uploadRange.endNanoseconds <= request.asset.sourceDurationNanoseconds,
            maximumUploadBytes > 0,
            maximumResponseBytes > 0
        else {
            throw OpenAIFileTranscriptionProviderError.invalidRequest
        }
        guard FileManager.default.fileExists(atPath: request.asset.fileURL.path) else {
            throw OpenAIFileTranscriptionProviderError.sourceUnavailable
        }
    }

    private static func classifyHTTPStatus(
        _ statusCode: Int
    ) -> OpenAIFileTranscriptionProviderError {
        switch statusCode {
        case 401, 403:
            return .authenticationFailed
        case 408, 425, 429:
            return .rateLimited
        case 500...599:
            return .serviceUnavailable
        default:
            return .requestRejected
        }
    }

    private static func nanoseconds(
        fromSeconds seconds: Double,
        maximum: UInt64
    ) throws -> UInt64 {
        guard seconds.isFinite, seconds >= 0 else {
            throw OpenAIFileTranscriptionProviderError.invalidSegmentTimestamp
        }
        let scaled = (seconds * 1_000_000_000).rounded()
        guard
            scaled.isFinite,
            scaled >= 0,
            scaled <= Double(maximum)
        else {
            throw OpenAIFileTranscriptionProviderError.invalidSegmentTimestamp
        }
        return UInt64(scaled)
    }
}

private struct TranscriptionEnvelope: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    let id: String?
    let text: String?
    let segments: [Segment]?
}

private enum MultipartTranscriptionBody {
    static func make(
        boundary: String,
        modelID: String,
        languages: [String],
        audioData: Data,
        requestsSegmentTimestamps: Bool
    ) -> Data {
        var body = Data()
        appendField(name: "model", value: modelID, boundary: boundary, to: &body)
        for language in languages {
            appendField(
                name: "languages[]",
                value: language,
                boundary: boundary,
                to: &body
            )
        }
        if requestsSegmentTimestamps {
            appendField(
                name: "response_format",
                value: "verbose_json",
                boundary: boundary,
                to: &body
            )
            appendField(
                name: "timestamp_granularities[]",
                value: "segment",
                boundary: boundary,
                to: &body
            )
        }
        append("--\(boundary)\r\n", to: &body)
        append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n",
            to: &body
        )
        append("Content-Type: audio/mp4\r\n\r\n", to: &body)
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private static func appendField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        append("--\(boundary)\r\n", to: &body)
        append(
            "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n",
            to: &body
        )
        append("\(value)\r\n", to: &body)
    }

    private static func append(_ string: String, to body: inout Data) {
        body.append(contentsOf: string.utf8)
    }
}
