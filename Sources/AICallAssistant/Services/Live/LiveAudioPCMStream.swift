@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

enum LiveAudioConversionError: LocalizedError, Equatable {
    case missingFormat
    case unsupportedFormat
    case sampleCopyFailed(OSStatus)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFormat:
            return "В аудиобуфере отсутствует описание формата."
        case .unsupportedFormat:
            return "Формат аудиобуфера не поддерживается."
        case let .sampleCopyFailed(status):
            return "Не удалось скопировать PCM-аудио (код \(status))."
        case let .conversionFailed(message):
            return "Не удалось преобразовать аудио: \(message)"
        }
    }
}

protocol LiveAudioFrameConverting: AnyObject {
    func convert(_ frame: CapturedAudioFrame) throws -> [LivePCMChunk]
    func finish() -> [LivePCMChunk]
    func forceDiscontinuityBeforeNextInput() -> [LivePCMChunk]
}

enum LiveAudioPCMStreamPolicy {
    /// Roughly 2.5 seconds of headroom for the ~10 ms buffers produced by the
    /// built-in Mac microphone. This absorbs ordinary converter scheduling
    /// stalls while keeping retained capture memory strictly bounded.
    static let productionMaxBufferedSourceFramesPerTrack = 250
}

/// A dual-track, bounded, nonblocking capture sink. It deliberately has a
/// bounded queue *before* AVAudioConverter so a stalled converter cannot retain
/// an unbounded number of CMSampleBuffers or interfere with the file writers.
final class DualTrackLiveAudioPCMStream: LiveAudioSampleSink, @unchecked Sendable {
    typealias ChunkHandler = @Sendable (LivePCMChunk) -> Void
    typealias GapHandler = @Sendable (LiveAudioGap) -> Void
    typealias ConverterFactory = (AudioTrack, Int) -> any LiveAudioFrameConverting

    private let incoming: LiveAudioTrackWorker
    private let outgoing: LiveAudioTrackWorker

    init(
        maxBufferedSourceFramesPerTrack: Int = LiveAudioPCMStreamPolicy
            .productionMaxBufferedSourceFramesPerTrack,
        chunkDurationMilliseconds: Int = 100,
        converterFactory: ConverterFactory = { track, duration in
            LiveAudioPCMConverter(
                track: track,
                chunkDurationMilliseconds: duration
            )
        },
        onGap: @escaping GapHandler = { _ in },
        onChunk: @escaping ChunkHandler
    ) {
        precondition(maxBufferedSourceFramesPerTrack > 0)
        precondition(chunkDurationMilliseconds > 0)
        incoming = LiveAudioTrackWorker(
            track: .incoming,
            maxBufferedSourceFrames: maxBufferedSourceFramesPerTrack,
            converter: converterFactory(.incoming, chunkDurationMilliseconds),
            onGap: onGap,
            onChunk: onChunk
        )
        outgoing = LiveAudioTrackWorker(
            track: .outgoing,
            maxBufferedSourceFrames: maxBufferedSourceFramesPerTrack,
            converter: converterFactory(.outgoing, chunkDurationMilliseconds),
            onGap: onGap,
            onChunk: onChunk
        )
    }

    func offer(_ frame: CapturedAudioFrame) {
        worker(for: frame.track).offer(frame)
    }

    func recordDroppedFrame(track: AudioTrack, durationNanoseconds: UInt64) {
        worker(for: track).recordDroppedFrame(durationNanoseconds: durationNanoseconds)
    }

    func stopAccepting() {
        incoming.stopAccepting()
        outgoing.stopAccepting()
    }

    func finish() async -> LiveAudioSinkReport {
        stopAccepting()
        async let incomingMetrics = incoming.finish()
        async let outgoingMetrics = outgoing.finish()
        return await LiveAudioSinkReport(
            incoming: incomingMetrics,
            outgoing: outgoingMetrics
        )
    }

    private func worker(for track: AudioTrack) -> LiveAudioTrackWorker {
        switch track {
        case .incoming:
            return incoming
        case .outgoing:
            return outgoing
        }
    }
}

private final class LiveAudioTrackWorker: @unchecked Sendable {
    private struct PendingFrame {
        let frame: CapturedAudioFrame
        let discontinuityBefore: Bool
    }

    private let track: AudioTrack
    private let maxBufferedSourceFrames: Int
    private let onGap: DualTrackLiveAudioPCMStream.GapHandler
    private let onChunk: DualTrackLiveAudioPCMStream.ChunkHandler
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let converter: any LiveAudioFrameConverting

    private var pendingFrames: [PendingFrame] = []
    private var forceDiscontinuityOnNextAcceptedFrame = false
    private var drainScheduled = false
    private var accepting = true
    private var didFinish = false
    private var metrics = LiveAudioTrackMetrics()
    private var activeConversionGap: LiveAudioGap?
    private var lastPublishedConversionGapEnd: UInt64?

    init(
        track: AudioTrack,
        maxBufferedSourceFrames: Int,
        converter: any LiveAudioFrameConverting,
        onGap: @escaping DualTrackLiveAudioPCMStream.GapHandler,
        onChunk: @escaping DualTrackLiveAudioPCMStream.ChunkHandler
    ) {
        self.track = track
        self.maxBufferedSourceFrames = maxBufferedSourceFrames
        self.converter = converter
        self.onGap = onGap
        self.onChunk = onChunk
        queue = DispatchQueue(label: "com.aicallassistant.live-pcm.\(track.rawValue)")
    }

    func offer(_ frame: CapturedAudioFrame) {
        var shouldSchedule = false
        lock.lock()
        if accepting, !didFinish {
            if pendingFrames.count < maxBufferedSourceFrames {
                pendingFrames.append(
                    PendingFrame(
                        frame: frame,
                        discontinuityBefore: forceDiscontinuityOnNextAcceptedFrame
                    )
                )
                forceDiscontinuityOnNextAcceptedFrame = false
                metrics.acceptedSourceBuffers += 1
                if !drainScheduled {
                    drainScheduled = true
                    shouldSchedule = true
                }
            } else {
                metrics.droppedSourceBuffers += 1
                metrics.droppedAudioNanoseconds += Self.estimatedDurationNanoseconds(frame.sampleBuffer)
                forceDiscontinuityOnNextAcceptedFrame = true
            }
        } else {
            metrics.droppedSourceBuffers += 1
            metrics.droppedAudioNanoseconds += Self.estimatedDurationNanoseconds(frame.sampleBuffer)
        }
        lock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in
                self?.drain()
            }
        }
    }

    func stopAccepting() {
        lock.withLock {
            accepting = false
        }
    }

    func recordDroppedFrame(durationNanoseconds: UInt64) {
        lock.withLock {
            guard !didFinish else { return }
            metrics.droppedSourceBuffers += 1
            metrics.droppedAudioNanoseconds += durationNanoseconds
            forceDiscontinuityOnNextAcceptedFrame = true
        }
    }

    func finish() async -> LiveAudioTrackMetrics {
        stopAccepting()
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: LiveAudioTrackMetrics())
                    return
                }
                self.drain()
                self.publishActiveConversionGapIfChanged()
                self.activeConversionGap = nil
                self.lastPublishedConversionGapEnd = nil
                for chunk in self.converter.finish() {
                    self.publish(chunk)
                }
                let finalMetrics = self.lock.withLock { () -> LiveAudioTrackMetrics in
                    self.didFinish = true
                    return self.metrics
                }
                continuation.resume(returning: finalMetrics)
            }
        }
    }

    private func drain() {
        while let pending = takeNextFrame() {
            if pending.discontinuityBefore {
                for chunk in converter.forceDiscontinuityBeforeNextInput() {
                    publish(chunk)
                }
            }
            do {
                let chunks = try converter.convert(pending.frame)
                // The gap must cross the ordered callback boundary before any
                // audio that follows the failed source interval.
                publishActiveConversionGapIfChanged()
                activeConversionGap = nil
                lastPublishedConversionGapEnd = nil
                for chunk in chunks {
                    publish(chunk)
                }
            } catch {
                for chunk in converter.forceDiscontinuityBeforeNextInput() {
                    publish(chunk)
                }
                recordConversionFailure(for: pending.frame)
            }
        }
        // Do not wait for a future successful frame: an all-failing live track
        // must still advance its watermark and visibly degrade.
        publishActiveConversionGapIfChanged()
    }

    private func takeNextFrame() -> PendingFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard !pendingFrames.isEmpty else {
            drainScheduled = false
            return nil
        }
        return pendingFrames.removeFirst()
    }

    private func publish(_ chunk: LivePCMChunk) {
        lock.withLock {
            metrics.emittedChunks += 1
            if chunk.discontinuityBefore {
                metrics.discontinuities += 1
            }
        }
        onChunk(chunk)
    }

    private func recordConversionFailure(for frame: CapturedAudioFrame) {
        let duration = max(
            UInt64(1),
            Self.estimatedDurationNanoseconds(frame.sampleBuffer)
        )
        let (end, overflow) = frame.startCallNanoseconds.addingReportingOverflow(duration)
        let frameEnd = overflow ? UInt64.max : end
        if let active = activeConversionGap {
            activeConversionGap = LiveAudioGap(
                id: active.id,
                track: track,
                startCallNanoseconds: min(
                    active.startCallNanoseconds,
                    frame.startCallNanoseconds
                ),
                endCallNanoseconds: max(active.endCallNanoseconds, frameEnd),
                reason: .conversionFailure
            )
        } else {
            activeConversionGap = LiveAudioGap(
                track: track,
                startCallNanoseconds: frame.startCallNanoseconds,
                endCallNanoseconds: frameEnd,
                reason: .conversionFailure
            )
        }
        lock.withLock {
            metrics.conversionFailures += 1
        }
    }

    private func publishActiveConversionGapIfChanged() {
        guard let gap = activeConversionGap,
              lastPublishedConversionGapEnd != gap.endCallNanoseconds else {
            return
        }
        lastPublishedConversionGapEnd = gap.endCallNanoseconds
        onGap(gap)
    }

    private static func estimatedDurationNanoseconds(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds.isFinite, duration.seconds > 0 {
            return UInt64(duration.seconds * 1_000_000_000)
        }
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            stream.pointee.mSampleRate > 0
        else {
            return 0
        }
        let seconds = Double(CMSampleBufferGetNumSamples(sampleBuffer)) / stream.pointee.mSampleRate
        return UInt64(max(0, seconds) * 1_000_000_000)
    }
}

final class LiveAudioPCMConverter: LiveAudioFrameConverting {
    private let track: AudioTrack
    private let outputFormat: AVAudioFormat
    private let framesPerChunk: Int
    private let bytesPerChunk: Int

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pendingPCM = Data()
    private var pendingStartCallNanoseconds: UInt64?
    private var pendingDiscontinuity = false
    private var nextSequence: UInt64 = 0
    private var nextExpectedSourceStartNanoseconds: UInt64?

    init(track: AudioTrack, chunkDurationMilliseconds: Int = 100) {
        self.track = track
        framesPerChunk = max(
            1,
            LivePCMChunk.sampleRate * chunkDurationMilliseconds / 1_000
        )
        bytesPerChunk = framesPerChunk * MemoryLayout<Int16>.size
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(LivePCMChunk.sampleRate),
            channels: 1,
            interleaved: false
        )!
    }

    func convert(_ frame: CapturedAudioFrame) throws -> [LivePCMChunk] {
        let input = try Self.makePCMBuffer(from: frame.sampleBuffer)
        return try convert(input, startCallNanoseconds: frame.startCallNanoseconds)
    }

    /// Internal entry point used by deterministic converter tests.
    func convert(
        _ input: AVAudioPCMBuffer,
        startCallNanoseconds: UInt64
    ) throws -> [LivePCMChunk] {
        // `AVCaptureAudioDataOutput` can deliver perfectly valid interleaved
        // Float32 PCM (notably the mono Bluetooth microphone route used by
        // AirPods). `AVAudioFormat.isStandard` only accepts non-interleaved
        // Float32, so using it as a PCM validity check rejected every AirPods
        // buffer before the downmix below had a chance to handle it.
        guard input.frameLength > 0,
              input.format.sampleRate > 0,
              input.format.channelCount > 0 else {
            throw LiveAudioConversionError.unsupportedFormat
        }

        var chunks = try insertSourceGapIfNeeded(
            startCallNanoseconds: startCallNanoseconds,
            inputFrames: Int(input.frameLength),
            inputSampleRate: input.format.sampleRate
        )

        let monoInput = try Self.makeMonoFloatBuffer(from: input)
        let converter = try converter(for: monoInput.format)
        let ratio = outputFormat.sampleRate / monoInput.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, Int(ceil(Double(monoInput.frameLength) * ratio)) + 256)
        )
        let inputState = LiveAudioConverterInputState(input: monoInput)
        if pendingPCM.isEmpty {
            pendingStartCallNanoseconds = startCallNanoseconds
        }
        // AVAudioConverter may cap one pull at an internal block size (commonly
        // 2048 frames), even when outputCapacity is larger. Keep pulling with
        // `.noDataNow` until it releases the remainder of this input buffer.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw LiveAudioConversionError.unsupportedFormat
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requestedPackets, inputStatus in
                inputState.nextSlice(
                    requestedPackets: requestedPackets,
                    inputStatus: inputStatus
                )
            }
            if status == .error {
                throw LiveAudioConversionError.conversionFailed(
                    conversionError?.localizedDescription ?? "неизвестная ошибка AVAudioConverter"
                )
            }
            guard output.frameLength > 0, let floats = output.floatChannelData?[0] else {
                break
            }
            appendPCM16(floats, frameCount: Int(output.frameLength))
            if status == .endOfStream {
                break
            }
        }
        chunks.append(contentsOf: takeCompleteChunks())
        return chunks
    }

    func finish() -> [LivePCMChunk] {
        var chunks = takeCompleteChunks()
        let remainingFrames = pendingPCM.count / MemoryLayout<Int16>.size
        if remainingFrames > 0, let start = pendingStartCallNanoseconds {
            chunks.append(
                LivePCMChunk(
                    track: track,
                    sequence: nextSequence,
                    startCallNanoseconds: start,
                    pcm16LittleEndian: pendingPCM,
                    frameCount: remainingFrames,
                    discontinuityBefore: pendingDiscontinuity
                )
            )
            nextSequence += 1
        }
        pendingPCM.removeAll(keepingCapacity: false)
        pendingStartCallNanoseconds = nil
        pendingDiscontinuity = false
        return chunks
    }

    /// Closes any pre-gap remainder and makes the next emitted audio chunk an
    /// explicit timeline boundary. Resetting the expected source timestamp is
    /// intentional: a known dropped/failed buffer must never be represented as
    /// fabricated silence by the normal short-clock-gap repair path.
    func forceDiscontinuityBeforeNextInput() -> [LivePCMChunk] {
        var chunks = takeCompleteChunks()
        chunks.append(contentsOf: takeRemainderChunk())
        nextExpectedSourceStartNanoseconds = nil
        pendingStartCallNanoseconds = nil
        pendingDiscontinuity = true
        return chunks
    }

    private func converter(for inputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, converterInputFormat == inputFormat {
            return converter
        }
        guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw LiveAudioConversionError.unsupportedFormat
        }
        // Realtime transcription values deterministic frame accounting and low
        // latency over the leading/trailing priming used for media mastering.
        newConverter.primeMethod = .none
        converter = newConverter
        converterInputFormat = inputFormat
        return newConverter
    }

    private func insertSourceGapIfNeeded(
        startCallNanoseconds: UInt64,
        inputFrames: Int,
        inputSampleRate: Double
    ) throws -> [LivePCMChunk] {
        guard inputSampleRate > 0 else {
            throw LiveAudioConversionError.unsupportedFormat
        }

        var chunks: [LivePCMChunk] = []
        if let expected = nextExpectedSourceStartNanoseconds,
           startCallNanoseconds > expected {
            let gap = startCallNanoseconds - expected
            // Small clock rounding discrepancies do not represent missing audio.
            if gap > 2_000_000 {
                let maxFill: UInt64 = 5_000_000_000
                let fill = min(gap, maxFill)
                let silenceFrames = Int(
                    fill * UInt64(LivePCMChunk.sampleRate) / 1_000_000_000
                )
                if silenceFrames > 0 {
                    if pendingPCM.isEmpty {
                        pendingStartCallNanoseconds = expected
                    }
                    pendingPCM.append(
                        Data(count: silenceFrames * MemoryLayout<Int16>.size)
                    )
                    chunks.append(contentsOf: takeCompleteChunks())
                }
                if gap > maxFill {
                    if !pendingPCM.isEmpty {
                        chunks.append(contentsOf: takeRemainderChunk())
                    }
                    pendingStartCallNanoseconds = startCallNanoseconds
                    pendingDiscontinuity = true
                }
            }
        }

        let inputDuration = UInt64(
            Double(inputFrames) / inputSampleRate * 1_000_000_000
        )
        nextExpectedSourceStartNanoseconds = startCallNanoseconds + inputDuration
        return chunks
    }

    private func appendPCM16(_ samples: UnsafePointer<Float>, frameCount: Int) {
        var encoded = Data(capacity: frameCount * MemoryLayout<Int16>.size)
        for index in 0..<frameCount {
            let clamped = max(-1, min(1, samples[index]))
            var value = Int16((clamped * 32_767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { bytes in
                encoded.append(contentsOf: bytes)
            }
        }
        pendingPCM.append(encoded)
    }

    private func takeCompleteChunks() -> [LivePCMChunk] {
        var chunks: [LivePCMChunk] = []
        while pendingPCM.count >= bytesPerChunk, let start = pendingStartCallNanoseconds {
            let bytes = pendingPCM.prefix(bytesPerChunk)
            chunks.append(
                LivePCMChunk(
                    track: track,
                    sequence: nextSequence,
                    startCallNanoseconds: start,
                    pcm16LittleEndian: Data(bytes),
                    frameCount: framesPerChunk,
                    discontinuityBefore: pendingDiscontinuity
                )
            )
            pendingPCM.removeFirst(bytesPerChunk)
            pendingStartCallNanoseconds = start
                + UInt64(framesPerChunk) * 1_000_000_000 / UInt64(LivePCMChunk.sampleRate)
            pendingDiscontinuity = false
            nextSequence += 1
        }
        return chunks
    }

    private func takeRemainderChunk() -> [LivePCMChunk] {
        let remainingFrames = pendingPCM.count / MemoryLayout<Int16>.size
        guard remainingFrames > 0, let start = pendingStartCallNanoseconds else {
            pendingPCM.removeAll(keepingCapacity: true)
            return []
        }
        let chunk = LivePCMChunk(
            track: track,
            sequence: nextSequence,
            startCallNanoseconds: start,
            pcm16LittleEndian: pendingPCM,
            frameCount: remainingFrames,
            discontinuityBefore: pendingDiscontinuity
        )
        nextSequence += 1
        pendingPCM.removeAll(keepingCapacity: true)
        pendingStartCallNanoseconds = nil
        pendingDiscontinuity = false
        return [chunk]
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else {
            throw LiveAudioConversionError.missingFormat
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            throw LiveAudioConversionError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            throw LiveAudioConversionError.sampleCopyFailed(status)
        }
        return buffer
    }

    private static func makeMonoFloatBuffer(
        from input: AVAudioPCMBuffer
    ) throws -> AVAudioPCMBuffer {
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: input.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: input.frameLength
        ), let destination = mono.floatChannelData?[0] else {
            throw LiveAudioConversionError.unsupportedFormat
        }
        mono.frameLength = input.frameLength

        let channels = max(1, Int(input.format.channelCount))
        let frameCount = Int(input.frameLength)
        let interleaved = input.format.isInterleaved

        switch input.format.commonFormat {
        case .pcmFormatFloat32:
            guard let source = input.floatChannelData else {
                throw LiveAudioConversionError.unsupportedFormat
            }
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved
                        ? source[0][frame * channels + channel]
                        : source[channel][frame]
                }
                destination[frame] = sum / Float(channels)
            }

        case .pcmFormatInt16:
            guard let source = input.int16ChannelData else {
                throw LiveAudioConversionError.unsupportedFormat
            }
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    let value = interleaved
                        ? source[0][frame * channels + channel]
                        : source[channel][frame]
                    sum += Float(value) / 32_768
                }
                destination[frame] = sum / Float(channels)
            }

        case .pcmFormatInt32:
            guard let source = input.int32ChannelData else {
                throw LiveAudioConversionError.unsupportedFormat
            }
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channels {
                    let value = interleaved
                        ? source[0][frame * channels + channel]
                        : source[channel][frame]
                    sum += Float(value) / 2_147_483_648
                }
                destination[frame] = sum / Float(channels)
            }

        case .pcmFormatFloat64, .otherFormat:
            throw LiveAudioConversionError.unsupportedFormat

        @unknown default:
            throw LiveAudioConversionError.unsupportedFormat
        }
        return mono
    }
}

/// `AVAudioConverter` pulls input synchronously, but its block is imported as
/// sendable. Keep the pull cursor and the last supplied buffer in one locked
/// reference so the block does not capture mutable local variables and the
/// slice remains alive for the duration of the conversion pull.
private final class LiveAudioConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private let input: AVAudioPCMBuffer
    private var inputOffset = 0
    private var suppliedSlice: AVAudioPCMBuffer?

    init(input: AVAudioPCMBuffer) {
        self.input = input
    }

    func nextSlice(
        requestedPackets: AVAudioPacketCount,
        inputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        let remaining = Int(input.frameLength) - inputOffset
        guard remaining > 0 else {
            inputStatus.pointee = .noDataNow
            return nil
        }
        let requested = max(1, Int(requestedPackets))
        let count = min(requested, remaining)
        guard let slice = AVAudioPCMBuffer(
            pcmFormat: input.format,
            frameCapacity: AVAudioFrameCount(count)
        ), let source = input.floatChannelData?[0],
           let destination = slice.floatChannelData?[0] else {
            inputStatus.pointee = .noDataNow
            return nil
        }
        slice.frameLength = AVAudioFrameCount(count)
        destination.update(from: source.advanced(by: inputOffset), count: count)
        inputOffset += count
        suppliedSlice = slice
        inputStatus.pointee = .haveData
        return suppliedSlice
    }
}
