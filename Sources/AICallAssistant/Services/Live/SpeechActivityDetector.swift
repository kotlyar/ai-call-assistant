import Foundation

struct SpeechActivityConfiguration: Equatable, Sendable {
    var preRollMilliseconds = 300
    var silenceHangoverMilliseconds = 600
    var forcedCommitMilliseconds = 30_000
    var minimumSpeechRMS: Float = 0.012
    var speechNoiseMultiplier: Float = 3.0
    var silenceNoiseMultiplier: Float = 1.8
    var startConfirmationChunks = 2
}

struct LocalAudioTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let track: AudioTrack
    let startCallNanoseconds: UInt64
}

enum SpeechActivityEvent: Equatable, Sendable {
    case started(LocalAudioTurn, preRoll: [LivePCMChunk])
    case audio(turnID: UUID, chunk: LivePCMChunk)
    case ended(turnID: UUID, endCallNanoseconds: UInt64, forced: Bool)
    case discontinuity(atCallNanoseconds: UInt64)
}

/// Conservative local energy VAD. It is intentionally deterministic and keeps
/// pre-roll/hangover so the network branch favors extra context over clipped
/// phonemes. One detector instance is owned by each audio track.
struct SpeechActivityDetector: Sendable {
    private let track: AudioTrack
    private let configuration: SpeechActivityConfiguration
    private let makeTurnID: @Sendable () -> UUID

    private var preRoll: [LivePCMChunk] = []
    private var activeTurn: LocalAudioTurn?
    private var activeStartNanoseconds: UInt64?
    private var quietChunks = 0
    private var loudChunks = 0
    private var noiseFloorRMS: Float = 0.004

    init(
        track: AudioTrack,
        configuration: SpeechActivityConfiguration = .init(),
        makeTurnID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.track = track
        self.configuration = configuration
        self.makeTurnID = makeTurnID
    }

    mutating func consume(_ chunk: LivePCMChunk) -> [SpeechActivityEvent] {
        precondition(chunk.track == track)

        if chunk.discontinuityBefore {
            var events = endActiveTurn(at: chunk.startCallNanoseconds, forced: true)
            preRoll.removeAll(keepingCapacity: true)
            events.append(.discontinuity(atCallNanoseconds: chunk.startCallNanoseconds))
            // The first post-gap audio still participates in detection below.
            return events + consumeWithoutDiscontinuity(chunk)
        }
        return consumeWithoutDiscontinuity(chunk)
    }

    mutating func flush(atCallNanoseconds: UInt64) -> [SpeechActivityEvent] {
        endActiveTurn(at: atCallNanoseconds, forced: true)
    }

    /// A known local audio gap is a hard speech boundary. End any partial turn
    /// and discard preroll so audio from opposite sides of missing capture is
    /// never joined into one provider item.
    mutating func resetForGap(atCallNanoseconds: UInt64) -> [SpeechActivityEvent] {
        let events = endActiveTurn(at: atCallNanoseconds, forced: true)
        preRoll.removeAll(keepingCapacity: true)
        quietChunks = 0
        loudChunks = 0
        return events
    }

    private mutating func consumeWithoutDiscontinuity(
        _ chunk: LivePCMChunk
    ) -> [SpeechActivityEvent] {
        let rms = Self.rootMeanSquare(of: chunk.pcm16LittleEndian)
        let speechThreshold = max(
            configuration.minimumSpeechRMS,
            noiseFloorRMS * configuration.speechNoiseMultiplier
        )
        let silenceThreshold = max(
            configuration.minimumSpeechRMS * 0.7,
            noiseFloorRMS * configuration.silenceNoiseMultiplier
        )

        if let activeTurn {
            var events: [SpeechActivityEvent] = [.audio(turnID: activeTurn.id, chunk: chunk)]
            if rms < silenceThreshold {
                quietChunks += 1
            } else {
                quietChunks = 0
            }

            let activeDuration = chunk.startCallNanoseconds
                + chunk.durationNanoseconds
                - (activeStartNanoseconds ?? chunk.startCallNanoseconds)
            if activeDuration >= millisecondsToNanoseconds(configuration.forcedCommitMilliseconds) {
                events += endActiveTurn(
                    at: chunk.startCallNanoseconds + chunk.durationNanoseconds,
                    forced: true
                )
            } else if quietDurationMilliseconds(chunkDuration: chunk.durationNanoseconds)
                >= configuration.silenceHangoverMilliseconds {
                events += endActiveTurn(
                    at: chunk.startCallNanoseconds + chunk.durationNanoseconds,
                    forced: false
                )
            }
            return events
        }

        updateNoiseFloor(with: rms)
        appendPreRoll(chunk)
        if rms >= speechThreshold {
            loudChunks += 1
        } else {
            loudChunks = 0
        }
        guard loudChunks >= configuration.startConfirmationChunks else { return [] }

        let buffered = preRoll
        let first = buffered.first ?? chunk
        let turn = LocalAudioTurn(
            id: makeTurnID(),
            track: track,
            startCallNanoseconds: first.startCallNanoseconds
        )
        activeTurn = turn
        activeStartNanoseconds = first.startCallNanoseconds
        quietChunks = 0
        loudChunks = 0
        preRoll.removeAll(keepingCapacity: true)
        return [.started(turn, preRoll: buffered)]
    }

    private mutating func endActiveTurn(
        at endCallNanoseconds: UInt64,
        forced: Bool
    ) -> [SpeechActivityEvent] {
        guard let turn = activeTurn else { return [] }
        activeTurn = nil
        activeStartNanoseconds = nil
        quietChunks = 0
        loudChunks = 0
        return [
            .ended(
                turnID: turn.id,
                endCallNanoseconds: endCallNanoseconds,
                forced: forced
            )
        ]
    }

    private mutating func appendPreRoll(_ chunk: LivePCMChunk) {
        preRoll.append(chunk)
        let target = max(1, configuration.preRollMilliseconds)
        var duration = preRoll.reduce(0) { partial, item in
            partial + Int(item.durationNanoseconds / 1_000_000)
        }
        while preRoll.count > 1, duration > target {
            let removed = preRoll.removeFirst()
            duration -= Int(removed.durationNanoseconds / 1_000_000)
        }
    }

    private mutating func updateNoiseFloor(with rms: Float) {
        // Do not let one loud candidate immediately lift the floor enough to
        // suppress speech onset.
        let capped = min(rms, max(configuration.minimumSpeechRMS, noiseFloorRMS * 2))
        noiseFloorRMS = noiseFloorRMS * 0.95 + capped * 0.05
    }

    private func quietDurationMilliseconds(chunkDuration: UInt64) -> Int {
        quietChunks * Int(chunkDuration / 1_000_000)
    }

    private func millisecondsToNanoseconds(_ milliseconds: Int) -> UInt64 {
        UInt64(max(0, milliseconds)) * 1_000_000
    }

    private static func rootMeanSquare(of data: Data) -> Float {
        guard data.count >= MemoryLayout<Int16>.size else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Double = 0
            for raw in samples {
                let value = Double(Int16(littleEndian: raw)) / Double(Int16.max)
                sum += value * value
            }
            return Float(sqrt(sum / Double(samples.count)))
        }
    }
}
