@preconcurrency import CoreMedia
import Foundation

struct LivePCMChunk: Equatable, Sendable {
    static let sampleRate = 24_000

    let track: AudioTrack
    let sequence: UInt64
    let startCallNanoseconds: UInt64
    let pcm16LittleEndian: Data
    let frameCount: Int
    let discontinuityBefore: Bool

    var durationNanoseconds: UInt64 {
        UInt64(frameCount) * 1_000_000_000 / UInt64(Self.sampleRate)
    }
}

enum LiveAudioGapReason: String, Codable, Equatable, Sendable {
    case conversionFailure
}

/// A known interval for which captured audio could not enter the live
/// transcription timeline. Gap updates with the same id extend one contiguous
/// degraded interval instead of creating a turn per failed source buffer.
struct LiveAudioGap: Equatable, Sendable {
    let id: UUID
    let track: AudioTrack
    let startCallNanoseconds: UInt64
    let endCallNanoseconds: UInt64
    let reason: LiveAudioGapReason

    init(
        id: UUID = UUID(),
        track: AudioTrack,
        startCallNanoseconds: UInt64,
        endCallNanoseconds: UInt64,
        reason: LiveAudioGapReason
    ) {
        self.id = id
        self.track = track
        self.startCallNanoseconds = startCallNanoseconds
        self.endCallNanoseconds = max(startCallNanoseconds, endCallNanoseconds)
        self.reason = reason
    }
}

struct LiveAudioTrackMetrics: Codable, Equatable, Sendable {
    var acceptedSourceBuffers = 0
    var droppedSourceBuffers = 0
    var droppedAudioNanoseconds: UInt64 = 0
    var conversionFailures = 0
    var discontinuities = 0
    var emittedChunks = 0

    var hasKnownGaps: Bool {
        droppedSourceBuffers > 0
            || conversionFailures > 0
            || discontinuities > 0
    }
}

struct LiveAudioSinkReport: Equatable, Sendable {
    let incoming: LiveAudioTrackMetrics
    let outgoing: LiveAudioTrackMetrics

    var hasKnownGaps: Bool {
        incoming.hasKnownGaps || outgoing.hasKnownGaps
    }
}

/// Retains the Core Media buffer while it crosses from a capture callback to a
/// bounded conversion worker. The buffer is immutable after capture.
final class CapturedAudioFrame: @unchecked Sendable {
    let track: AudioTrack
    let sampleBuffer: CMSampleBuffer
    let startCallNanoseconds: UInt64

    init(
        track: AudioTrack,
        sampleBuffer: CMSampleBuffer,
        startCallNanoseconds: UInt64
    ) {
        self.track = track
        self.sampleBuffer = sampleBuffer
        self.startCallNanoseconds = startCallNanoseconds
    }
}

/// `offer` is called directly from ScreenCaptureKit/AVFoundation callbacks and
/// must return immediately. Implementations own all backpressure and dropping.
protocol LiveAudioSampleSink: AnyObject, Sendable {
    func offer(_ frame: CapturedAudioFrame)
    func recordDroppedFrame(track: AudioTrack, durationNanoseconds: UInt64)
    func stopAccepting()
    func finish() async -> LiveAudioSinkReport
}
