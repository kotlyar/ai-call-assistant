import Foundation

struct AudioSourceRange: Codable, Equatable, Hashable, Sendable {
    let startNanoseconds: UInt64
    let endNanoseconds: UInt64

    init(startNanoseconds: UInt64, endNanoseconds: UInt64) {
        precondition(endNanoseconds >= startNanoseconds, "Invalid audio range")
        self.startNanoseconds = startNanoseconds
        self.endNanoseconds = endNanoseconds
    }

    var durationNanoseconds: UInt64 {
        endNanoseconds - startNanoseconds
    }

    func intersects(_ other: AudioSourceRange) -> Bool {
        startNanoseconds < other.endNanoseconds
            && other.startNanoseconds < endNanoseconds
    }
}

struct AudioTrackChunkDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let track: AudioTrack

    /// These non-overlapping ranges form an exact partition of the source.
    let coverageRange: AudioSourceRange

    /// This is the actual exported/uploaded range and includes boundary overlap.
    let uploadRange: AudioSourceRange
    let estimatedUploadBytes: Int64
    let vadClassifiedSpeech: Bool
    let usedVADPreferredBoundary: Bool
    let chunkerVersion: Int
}

enum AudioTrackChunkerError: Error, Equatable, Sendable {
    case invalidMaximumUploadBytes
    case invalidMaximumCoverageChunkNanoseconds
    case inconsistentAsset
    case assetCannotFitBelowLimit
    case discontinuousPlan
}

/// Produces a deterministic upload plan without treating VAD as an exclusion
/// filter. VAD speech edges can move a boundary, but the coverage ranges always
/// partition the entire source timeline, including silence.
struct AudioTrackChunker: Sendable {
    static let defaultMaximumUploadBytes: Int64 = 24_000_000
    /// `gpt-transcribe` returns one coarse segment for an upload. Keeping each
    /// coverage window bounded prevents an otherwise small compressed M4A from
    /// becoming one call-long transcript turn per track.
    static let defaultMaximumCoverageChunkNanoseconds: UInt64 = 30_000_000_000

    let maximumUploadBytes: Int64
    let maximumCoverageChunkNanoseconds: UInt64
    let overlapNanoseconds: UInt64
    let preferredBoundaryLookbackNanoseconds: UInt64
    let minimumCoverageChunkNanoseconds: UInt64
    let version: Int

    init(
        maximumUploadBytes: Int64 = AudioTrackChunker.defaultMaximumUploadBytes,
        maximumCoverageChunkNanoseconds: UInt64 = AudioTrackChunker.defaultMaximumCoverageChunkNanoseconds,
        overlapNanoseconds: UInt64 = 1_000_000_000,
        preferredBoundaryLookbackNanoseconds: UInt64 = 5_000_000_000,
        minimumCoverageChunkNanoseconds: UInt64 = 250_000_000,
        version: Int = 2
    ) {
        self.maximumUploadBytes = maximumUploadBytes
        self.maximumCoverageChunkNanoseconds = maximumCoverageChunkNanoseconds
        self.overlapNanoseconds = overlapNanoseconds
        self.preferredBoundaryLookbackNanoseconds = preferredBoundaryLookbackNanoseconds
        self.minimumCoverageChunkNanoseconds = minimumCoverageChunkNanoseconds
        self.version = version
    }

    func chunks(
        callID: UUID,
        asset: ReconciliationAudioAsset,
        modelID: String,
        preferredSpeechRanges: [AudioSourceRange] = []
    ) throws -> [AudioTrackChunkDescriptor] {
        guard maximumUploadBytes > 1 else {
            throw AudioTrackChunkerError.invalidMaximumUploadBytes
        }
        guard maximumCoverageChunkNanoseconds > 0 else {
            throw AudioTrackChunkerError.invalidMaximumCoverageChunkNanoseconds
        }
        guard asset.sourceByteCount >= 0 else {
            throw AudioTrackChunkerError.inconsistentAsset
        }
        if asset.sourceDurationNanoseconds == 0 {
            guard asset.sourceByteCount == 0 else {
                throw AudioTrackChunkerError.inconsistentAsset
            }
            return []
        }

        let sourceRange = AudioSourceRange(
            startNanoseconds: 0,
            endNanoseconds: asset.sourceDurationNanoseconds
        )
        let validSpeechRanges = preferredSpeechRanges.filter {
            $0.durationNanoseconds > 0
                && $0.startNanoseconds < asset.sourceDurationNanoseconds
                && $0.endNanoseconds <= asset.sourceDurationNanoseconds
        }

        if asset.sourceByteCount < maximumUploadBytes,
           asset.sourceDurationNanoseconds <= maximumCoverageChunkNanoseconds {
            return [makeDescriptor(
                callID: callID,
                asset: asset,
                modelID: modelID,
                coverageRange: sourceRange,
                uploadRange: sourceRange,
                estimatedUploadBytes: asset.sourceByteCount,
                vadClassifiedSpeech: validSpeechRanges.contains {
                    $0.intersects(sourceRange)
                },
                usedVADPreferredBoundary: false
            )]
        }

        let maximumUploadDuration = try maximumDurationBelowByteLimit(for: asset)
        let effectiveOverlap: UInt64
        if overlapNanoseconds == 0 {
            effectiveOverlap = 0
        } else {
            guard maximumUploadDuration >= 3 else {
                throw AudioTrackChunkerError.assetCannotFitBelowLimit
            }
            effectiveOverlap = min(overlapNanoseconds, (maximumUploadDuration - 1) / 2)
        }
        let byteLimitedCoverageDuration = maximumUploadDuration - (2 * effectiveOverlap)
        let maximumCoverageDuration = min(
            byteLimitedCoverageDuration,
            maximumCoverageChunkNanoseconds
        )
        guard maximumCoverageDuration > 0 else {
            throw AudioTrackChunkerError.assetCannotFitBelowLimit
        }

        let preferredBoundaries = Set(validSpeechRanges.flatMap {
            [$0.startNanoseconds, $0.endNanoseconds]
        }).sorted()
        var result: [AudioTrackChunkDescriptor] = []
        var coverageStart: UInt64 = 0

        while coverageStart < asset.sourceDurationNanoseconds {
            let remaining = asset.sourceDurationNanoseconds - coverageStart
            let proposedDuration = min(maximumCoverageDuration, remaining)
            let proposedEnd = coverageStart + proposedDuration
            let isFinal = proposedEnd == asset.sourceDurationNanoseconds

            var coverageEnd = proposedEnd
            var usedPreferredBoundary = false
            if !isFinal {
                let minimumUsefulDuration = min(
                    minimumCoverageChunkNanoseconds,
                    maximumCoverageDuration
                )
                let minimumBoundary = max(
                    coverageStart + max(1, minimumUsefulDuration),
                    proposedEnd > preferredBoundaryLookbackNanoseconds
                        ? proposedEnd - preferredBoundaryLookbackNanoseconds
                        : coverageStart + 1
                )
                if let preferred = preferredBoundaries.last(where: {
                    $0 >= minimumBoundary && $0 <= proposedEnd
                }) {
                    coverageEnd = preferred
                    usedPreferredBoundary = true
                }
            }

            guard coverageEnd > coverageStart else {
                throw AudioTrackChunkerError.discontinuousPlan
            }
            let uploadStart = coverageStart > effectiveOverlap
                ? coverageStart - effectiveOverlap
                : 0
            let uploadEnd = min(
                asset.sourceDurationNanoseconds,
                coverageEnd + effectiveOverlap
            )
            let coverageRange = AudioSourceRange(
                startNanoseconds: coverageStart,
                endNanoseconds: coverageEnd
            )
            let uploadRange = AudioSourceRange(
                startNanoseconds: uploadStart,
                endNanoseconds: uploadEnd
            )
            let estimatedBytes = estimatedByteCount(
                for: uploadRange.durationNanoseconds,
                asset: asset
            )
            guard estimatedBytes < maximumUploadBytes else {
                throw AudioTrackChunkerError.assetCannotFitBelowLimit
            }

            result.append(makeDescriptor(
                callID: callID,
                asset: asset,
                modelID: modelID,
                coverageRange: coverageRange,
                uploadRange: uploadRange,
                estimatedUploadBytes: estimatedBytes,
                vadClassifiedSpeech: validSpeechRanges.contains {
                    $0.intersects(coverageRange)
                },
                usedVADPreferredBoundary: usedPreferredBoundary
            ))
            coverageStart = coverageEnd
        }

        guard Self.hasContinuousCoverage(
            result,
            sourceDurationNanoseconds: asset.sourceDurationNanoseconds
        ) else {
            throw AudioTrackChunkerError.discontinuousPlan
        }
        return result
    }

    static func hasContinuousCoverage(
        _ chunks: [AudioTrackChunkDescriptor],
        sourceDurationNanoseconds: UInt64
    ) -> Bool {
        if sourceDurationNanoseconds == 0 {
            return chunks.isEmpty
        }
        let sorted = chunks.sorted {
            if $0.coverageRange.startNanoseconds != $1.coverageRange.startNanoseconds {
                return $0.coverageRange.startNanoseconds < $1.coverageRange.startNanoseconds
            }
            return $0.id < $1.id
        }
        var cursor: UInt64 = 0
        for chunk in sorted {
            guard
                chunk.coverageRange.startNanoseconds == cursor,
                chunk.coverageRange.endNanoseconds > cursor,
                chunk.uploadRange.startNanoseconds <= chunk.coverageRange.startNanoseconds,
                chunk.uploadRange.endNanoseconds >= chunk.coverageRange.endNanoseconds
            else {
                return false
            }
            cursor = chunk.coverageRange.endNanoseconds
        }
        return cursor == sourceDurationNanoseconds
    }

    private func maximumDurationBelowByteLimit(
        for asset: ReconciliationAudioAsset
    ) throws -> UInt64 {
        guard asset.sourceByteCount > 0 else {
            return asset.sourceDurationNanoseconds
        }
        let byteBudget = Double(maximumUploadBytes - 1)
        let rawDuration = floor(
            byteBudget
                * Double(asset.sourceDurationNanoseconds)
                / Double(asset.sourceByteCount)
        )
        guard rawDuration >= 1, rawDuration.isFinite else {
            throw AudioTrackChunkerError.assetCannotFitBelowLimit
        }
        var duration = min(UInt64(rawDuration), asset.sourceDurationNanoseconds)
        while duration > 0,
              estimatedByteCount(for: duration, asset: asset) >= maximumUploadBytes {
            duration -= 1
        }
        guard duration > 0 else {
            throw AudioTrackChunkerError.assetCannotFitBelowLimit
        }
        return duration
    }

    private func estimatedByteCount(
        for durationNanoseconds: UInt64,
        asset: ReconciliationAudioAsset
    ) -> Int64 {
        guard durationNanoseconds > 0, asset.sourceByteCount > 0 else { return 0 }
        return Int64(ceil(
            Double(asset.sourceByteCount)
                * Double(durationNanoseconds)
                / Double(asset.sourceDurationNanoseconds)
        ))
    }

    private func makeDescriptor(
        callID: UUID,
        asset: ReconciliationAudioAsset,
        modelID: String,
        coverageRange: AudioSourceRange,
        uploadRange: AudioSourceRange,
        estimatedUploadBytes: Int64,
        vadClassifiedSpeech: Bool,
        usedVADPreferredBoundary: Bool
    ) -> AudioTrackChunkDescriptor {
        let identity = AudioTrackChunkIdentity(
            callID: callID,
            track: asset.track,
            audioSHA256: asset.sourceSHA256,
            uploadRange: uploadRange,
            modelID: modelID,
            chunkerVersion: version
        )
        return AudioTrackChunkDescriptor(
            id: identity.id,
            track: asset.track,
            coverageRange: coverageRange,
            uploadRange: uploadRange,
            estimatedUploadBytes: estimatedUploadBytes,
            vadClassifiedSpeech: vadClassifiedSpeech,
            usedVADPreferredBoundary: usedVADPreferredBoundary,
            chunkerVersion: version
        )
    }
}

private struct AudioTrackChunkIdentity {
    private struct Material: Encodable {
        let callID: String
        let track: String
        let audioSHA256: String
        let uploadStartNanoseconds: UInt64
        let uploadEndNanoseconds: UInt64
        let modelID: String
        let chunkerVersion: Int
    }

    let id: String

    init(
        callID: UUID,
        track: AudioTrack,
        audioSHA256: String,
        uploadRange: AudioSourceRange,
        modelID: String,
        chunkerVersion: Int
    ) {
        let material = Material(
            callID: callID.uuidString,
            track: track.rawValue,
            audioSHA256: audioSHA256,
            uploadStartNanoseconds: uploadRange.startNanoseconds,
            uploadEndNanoseconds: uploadRange.endNanoseconds,
            modelID: modelID,
            chunkerVersion: chunkerVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = (try? encoder.encode(material)) ?? Data()
        let component = encoded.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        id = "reconciliation-chunk-v1_\(component)"
    }
}
