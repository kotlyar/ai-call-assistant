import AVFoundation
import CryptoKit
import Foundation

enum ReconciliationAudioAssetInspectionError: Error, Equatable, Sendable {
    case fileMissing
    case invalidAudioDuration
    case invalidFileSize
}
struct ReconciliationAudioAssetInspector: Sendable {
    func inspect(
        track: AudioTrack,
        url: URL,
        callStartOffsetNanoseconds: UInt64 = 0
    ) async throws -> ReconciliationAudioAsset {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReconciliationAudioAssetInspectionError.fileMissing
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
            throw ReconciliationAudioAssetInspectionError.invalidFileSize
        }

        let duration = try await AVURLAsset(url: url).load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw ReconciliationAudioAssetInspectionError.invalidAudioDuration
        }
        let nanosecondsDouble = seconds * 1_000_000_000
        guard nanosecondsDouble.isFinite,
              nanosecondsDouble > 0,
              nanosecondsDouble <= Double(UInt64.max) else {
            throw ReconciliationAudioAssetInspectionError.invalidAudioDuration
        }

        return ReconciliationAudioAsset(
            track: track,
            fileURL: url,
            sourceDurationNanoseconds: UInt64(nanosecondsDouble.rounded()),
            sourceByteCount: Int64(fileSize),
            sourceSHA256: try Self.fileSHA256(url: url),
            callStartOffsetNanoseconds: callStartOffsetNanoseconds
        )
    }

    private static func fileSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
