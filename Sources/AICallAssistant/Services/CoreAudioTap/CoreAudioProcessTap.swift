@preconcurrency import CoreAudioTapCapture
import Foundation

/// A Swift lifetime/concurrency wrapper around the macOS 14.2 Core Audio process-tap API.
///
/// The C++ engine performs no allocation, locking, Objective-C messaging or Swift callbacks on
/// Core Audio's IO thread. It writes fixed-size packets to a preallocated SPSC ring. A dedicated
/// delivery thread invokes the callback below, where copying into a Swift-owned array is safe.
final class CoreAudioProcessTap: @unchecked Sendable {
    enum Scope: Sendable, Equatable {
        /// All system audio, always excluding Callya itself and optionally more processes.
        case systemAudio(excludingProcessIdentifiers: [Int32] = [])
        /// Only audio emitted by these HAL-connected processes.
        case processes([Int32])
    }

    struct FrameBatch: Sendable {
        /// Interleaved stereo Float32 PCM. `samples.count == frameCount * channelCount`.
        let samples: [Float]
        let frameCount: Int
        /// Mach absolute host time for the first frame in the batch.
        let hostTime: UInt64
        let sampleRate: Double
        let channelCount: Int
    }

    enum ProbeResult: Sendable, Equatable {
        case available
        case denied
        case unsupported
        case failed(String)
    }

    struct CaptureFailure: LocalizedError, Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case invalidArgument
            case alreadyRunning
            case processNotFound
            case permissionDenied
            case unsupported
            case coreAudio
        }

        let kind: Kind
        let message: String

        var errorDescription: String? { message }
    }

    typealias FramesHandler = @Sendable (FrameBatch) -> Void
    typealias FailureHandler = @Sendable (CaptureFailure) -> Void

    private final class CallbackBox: @unchecked Sendable {
        let framesHandler: FramesHandler
        let failureHandler: FailureHandler?

        init(
            framesHandler: @escaping FramesHandler,
            failureHandler: FailureHandler?
        ) {
            self.framesHandler = framesHandler
            self.failureHandler = failureHandler
        }
    }

    private let scope: Scope
    private let ringPacketCapacity: UInt32
    private let callbackBox: CallbackBox
    private let controlQueue = DispatchQueue(
        label: "com.callya.core-audio-tap.control",
        qos: .userInitiated
    )
    private let controlQueueKey = DispatchSpecificKey<Void>()
    private var handle: CallyaAudioTapRef?

    init(
        scope: Scope,
        ringPacketCapacity: UInt32 = 128,
        onFrames: @escaping FramesHandler,
        onFailure: FailureHandler? = nil
    ) {
        self.scope = scope
        self.ringPacketCapacity = ringPacketCapacity
        callbackBox = CallbackBox(
            framesHandler: onFrames,
            failureHandler: onFailure
        )
        controlQueue.setSpecific(key: controlQueueKey, value: ())
    }

    deinit {
        let cleanup = { [self] in
            guard let handle else { return }
            var message: UnsafeMutablePointer<CChar>?
            _ = CallyaAudioTapStop(handle, &message)
            CallyaAudioTapFreeString(message)
            CallyaAudioTapDestroy(handle)
            self.handle = nil
        }
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            cleanup()
        } else {
            controlQueue.sync(execute: cleanup)
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async { [self] in
                do {
                    try startSynchronously()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops and releases all HAL resources. Repeated calls are safe.
    /// - Returns: packets dropped because the consumer could not keep up.
    func stop() async throws -> UInt64 {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async { [self] in
                do {
                    let droppedPackets = try stopSynchronously()
                    continuation.resume(returning: droppedPackets)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Starting aggregate IO backed by a process tap is Apple's permission request/probe on
    /// macOS 14.2+. There is no separate Core Audio preflight API. Do not cache `.failed` as a
    /// permanent denial.
    static func probePermission() async -> ProbeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var message: UnsafeMutablePointer<CChar>?
                let result = CallyaAudioTapProbePermission(&message)
                let detail = consumeErrorString(message)
                switch result {
                case CallyaAudioTapResultOK:
                    continuation.resume(returning: .available)
                case CallyaAudioTapResultPermissionDenied:
                    continuation.resume(returning: .denied)
                case CallyaAudioTapResultUnsupported:
                    continuation.resume(returning: .unsupported)
                default:
                    continuation.resume(returning: .failed(
                        detail ?? "Не удалось проверить доступ к системному аудио."
                    ))
                }
            }
        }
    }

    private func startSynchronously() throws {
        guard handle == nil else {
            throw CaptureFailure(
                kind: .alreadyRunning,
                message: "Захват системного аудио уже запущен."
            )
        }

        let configurationScope: CallyaAudioTapScope
        let processIdentifiers: [Int32]
        switch scope {
        case let .systemAudio(excludingProcessIdentifiers):
            configurationScope = CallyaAudioTapScopeGlobalExcludingProcesses
            processIdentifiers = excludingProcessIdentifiers
        case let .processes(identifiers):
            configurationScope = CallyaAudioTapScopeIncludedProcesses
            processIdentifiers = identifiers
        }

        var createdHandle: CallyaAudioTapRef?
        let callbackContext = Unmanaged.passUnretained(callbackBox).toOpaque()
        var createMessage: UnsafeMutablePointer<CChar>?
        let createResult = processIdentifiers.withUnsafeBufferPointer { identifiers in
            var configuration = CallyaAudioTapConfiguration(
                scope: configurationScope,
                processIdentifiers: identifiers.baseAddress,
                processIdentifierCount: identifiers.count,
                ringPacketCapacity: ringPacketCapacity
            )
            return CallyaAudioTapCreate(
                &configuration,
                Self.receiveFrames,
                Self.receiveFailure,
                callbackContext,
                &createdHandle,
                &createMessage
            )
        }
        let createDetail = Self.consumeErrorString(createMessage)
        guard createResult == CallyaAudioTapResultOK, let createdHandle else {
            throw Self.failure(for: createResult, message: createDetail)
        }

        var startMessage: UnsafeMutablePointer<CChar>?
        let startResult = CallyaAudioTapStart(createdHandle, &startMessage)
        let startDetail = Self.consumeErrorString(startMessage)
        guard startResult == CallyaAudioTapResultOK else {
            CallyaAudioTapDestroy(createdHandle)
            throw Self.failure(for: startResult, message: startDetail)
        }
        handle = createdHandle
    }

    private func stopSynchronously() throws -> UInt64 {
        guard let handle else { return 0 }
        var message: UnsafeMutablePointer<CChar>?
        let result = CallyaAudioTapStop(handle, &message)
        let detail = Self.consumeErrorString(message)
        let droppedPackets = CallyaAudioTapDroppedPacketCount(handle)
        CallyaAudioTapDestroy(handle)
        self.handle = nil
        guard result == CallyaAudioTapResultOK else {
            throw Self.failure(for: result, message: detail)
        }
        return droppedPackets
    }

    private static let receiveFrames: CallyaAudioTapFramesCallback = {
        frames,
        frameCount,
        hostTime,
        sampleRate,
        channelCount,
        context in
        guard let frames, let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        let sampleCount = Int(frameCount) * Int(channelCount)
        box.framesHandler(FrameBatch(
            samples: Array(UnsafeBufferPointer(start: frames, count: sampleCount)),
            frameCount: Int(frameCount),
            hostTime: hostTime,
            sampleRate: sampleRate,
            channelCount: Int(channelCount)
        ))
    }

    private static let receiveFailure: CallyaAudioTapErrorCallback = {
        result,
        message,
        context in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        guard let handler = box.failureHandler else { return }
        let detail = message.map { String(cString: $0) }
        handler(failure(for: result, message: detail))
    }

    private static func failure(
        for result: CallyaAudioTapResult,
        message: String?
    ) -> CaptureFailure {
        let kind: CaptureFailure.Kind
        let fallback: String
        switch result {
        case CallyaAudioTapResultInvalidArgument:
            kind = .invalidArgument
            fallback = "Некорректная конфигурация системного аудио."
        case CallyaAudioTapResultAlreadyRunning:
            kind = .alreadyRunning
            fallback = "Захват системного аудио уже запущен."
        case CallyaAudioTapResultProcessNotFound:
            kind = .processNotFound
            fallback = "Выбранное приложение больше не воспроизводит звук."
        case CallyaAudioTapResultPermissionDenied:
            kind = .permissionDenied
            fallback = "Нет доступа к записи системного аудио."
        case CallyaAudioTapResultUnsupported:
            kind = .unsupported
            fallback = "Эта версия macOS не поддерживает запись системного аудио."
        default:
            kind = .coreAudio
            fallback = "Core Audio не смог запустить запись системного аудио."
        }
        return CaptureFailure(kind: kind, message: message ?? fallback)
    }

    private static func consumeErrorString(
        _ pointer: UnsafeMutablePointer<CChar>?
    ) -> String? {
        guard let pointer else { return nil }
        defer { CallyaAudioTapFreeString(pointer) }
        return String(cString: pointer)
    }
}
