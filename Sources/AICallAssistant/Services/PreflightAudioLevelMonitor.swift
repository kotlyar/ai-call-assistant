@preconcurrency import AVFoundation
import Combine
@preconcurrency import CoreMedia
import Foundation

/// Measures the selected microphone while the setup screen is visible.
///
/// This service never creates files and never forwards samples outside the
/// process. System audio deliberately starts only with the call, so the idle
/// screen never activates macOS's system-audio privacy indicator.
@MainActor
final class PreflightAudioLevelMonitor: ObservableObject {
    @Published private(set) var microphoneLevel: Double = 0

    private let microphoneQueue = DispatchQueue(
        label: "com.aicallassistant.preflight.microphone"
    )
    private let microphoneControlQueue = DispatchQueue(
        label: "com.aicallassistant.preflight.microphone-control"
    )
    private var microphoneSession: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var microphoneDelegate: PreflightMicrophoneOutput?
    private var decayTask: Task<Void, Never>?
    private var operationID: UInt64 = 0
    private var lastMicrophoneSample = ContinuousClock.now

    func configure(
        microphone: AudioSourceOption,
        monitorMicrophone: Bool
    ) async {
        operationID &+= 1
        let requestedOperation = operationID
        await tearDownResources()

        guard operationID == requestedOperation, !Task.isCancelled else { return }
        beginDecayLoop(operation: requestedOperation)

        if monitorMicrophone {
            await startMicrophone(
                microphone,
                operation: requestedOperation
            )
        }
    }

    func stop() async {
        operationID &+= 1
        await tearDownResources()
    }

    private func startMicrophone(
        _ source: AudioSourceOption,
        operation: UInt64
    ) async {
        guard case let .microphone(uniqueID) = source.kind,
              !uniqueID.isEmpty,
              let device = AVCaptureDevice(uniqueID: uniqueID) else {
            return
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = CanonicalMicrophoneCaptureFormat.audioSettings
        let delegate = PreflightMicrophoneOutput { [weak self] level in
            Task { @MainActor [weak self] in
                self?.receiveMicrophone(level, operation: operation)
            }
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            output.setSampleBufferDelegate(delegate, queue: microphoneQueue)
            session.addOutput(output)
        } catch {
            return
        }

        guard operationID == operation else { return }
        microphoneSession = session
        microphoneOutput = output
        microphoneDelegate = delegate

        let didStart = await withCheckedContinuation { continuation in
            microphoneControlQueue.async {
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
        guard operationID == operation, didStart else {
            if operationID == operation {
                await stopMicrophoneSession(session)
                clearMicrophoneResources(ifMatching: session)
            }
            return
        }
    }

    private func tearDownResources() async {
        decayTask?.cancel()
        decayTask = nil

        let session = microphoneSession
        microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
        microphoneSession = nil
        microphoneOutput = nil
        microphoneDelegate = nil

        microphoneLevel = 0
        if let session {
            await stopMicrophoneSession(session)
        }
    }

    private func stopMicrophoneSession(_ session: AVCaptureSession) async {
        await withCheckedContinuation { continuation in
            microphoneControlQueue.async {
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    private func clearMicrophoneResources(ifMatching session: AVCaptureSession) {
        guard microphoneSession === session else { return }
        microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
        microphoneSession = nil
        microphoneOutput = nil
        microphoneDelegate = nil
        microphoneLevel = 0
    }

    private func receiveMicrophone(_ level: Double, operation: UInt64) {
        guard operationID == operation else { return }
        lastMicrophoneSample = .now
        microphoneLevel = level
    }

    private func beginDecayLoop(operation: UInt64) {
        lastMicrophoneSample = .now
        decayTask = Task { @MainActor [weak self] in
            while let self,
                  !Task.isCancelled,
                  self.operationID == operation {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, self.operationID == operation else { break }

                let now = ContinuousClock.now
                if self.lastMicrophoneSample.duration(to: now) > .milliseconds(260) {
                    self.microphoneLevel *= 0.55
                    if self.microphoneLevel < 0.015 { self.microphoneLevel = 0 }
                }
            }
        }
    }
}

private final class PreflightMicrophoneOutput:
    NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    private let levelEmitter: PreflightLevelEmitter

    init(onLevel: @escaping @Sendable (Double) -> Void) {
        levelEmitter = PreflightLevelEmitter(onLevel: onLevel)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        levelEmitter.offer(sampleBuffer)
    }
}

/// Converts source packets to a perceptual 0...1 value off the main thread,
/// smooths release, and throttles UI publication to roughly 20 Hz.
private final class PreflightLevelEmitter: @unchecked Sendable {
    private let onLevel: @Sendable (Double) -> Void
    private var lastEmission = ContinuousClock.now
    private var displayedLevel = 0.0

    init(onLevel: @escaping @Sendable (Double) -> Void) {
        self.onLevel = onLevel
    }

    func offer(_ sampleBuffer: CMSampleBuffer) {
        guard let measured = Self.normalizedRMS(of: sampleBuffer) else { return }
        displayedLevel = measured > displayedLevel
            ? measured * 0.72 + displayedLevel * 0.28
            : measured * 0.22 + displayedLevel * 0.78

        let now = ContinuousClock.now
        guard lastEmission.duration(to: now) >= .milliseconds(48) else { return }
        lastEmission = now
        onLevel(displayedLevel)
    }

    private static func normalizedRMS(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let channels = max(1, Int(format.channelCount))
        let frames = Int(buffer.frameLength)
        let sampleCount = frames * channels
        guard sampleCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let sample = format.isInterleaved
                        ? data[0][frame * channels + channel]
                        : data[channel][frame]
                    sumOfSquares += Double(sample * sample)
                }
            }

        case .pcmFormatFloat64:
            return nil

        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let raw = format.isInterleaved
                        ? data[0][frame * channels + channel]
                        : data[channel][frame]
                    let sample = Double(raw) / 32_768
                    sumOfSquares += sample * sample
                }
            }

        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let raw = format.isInterleaved
                        ? data[0][frame * channels + channel]
                        : data[channel][frame]
                    let sample = Double(raw) / 2_147_483_648
                    sumOfSquares += sample * sample
                }
            }

        case .otherFormat:
            return nil

        @unknown default:
            return nil
        }

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 58) / 58, 0), 1)
    }
}
