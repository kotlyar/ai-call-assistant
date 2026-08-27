@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class RealAudioCaptureService: AudioCaptureService {
    private enum Constants {
        static let incomingFilename = "incoming.m4a"
        static let outgoingFilename = "outgoing.m4a"
        static let combinedFilename = "combined.m4a"
    }

    private let fileManager: FileManager
    private let systemAudioQueue = DispatchQueue(label: "com.aicallassistant.capture.system-audio")
    private let microphoneQueue = DispatchQueue(label: "com.aicallassistant.capture.microphone")
    private let microphoneControlQueue = DispatchQueue(label: "com.aicallassistant.capture.microphone-control")

    private var systemStream: SCStream?
    private var systemOutput: SystemAudioOutput?
    private var microphoneSession: AVCaptureSession?
    private var microphoneOutput: AVCaptureAudioDataOutput?
    private var microphoneDelegate: MicrophoneAudioOutput?
    private var incomingWriter: SampleBufferAudioWriter?
    private var outgoingWriter: SampleBufferAudioWriter?
    private var activeLiveAudioSink: LiveAudioSampleSink?
    private var activationGate: CaptureActivationGate?
    private var activeRequest: AudioCaptureRequest?
    private var streamFailure: Error?
    private var microphoneFailure: Error?
    private var microphoneObservers: [NSObjectProtocol] = []
    private var isStopping = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discoverSources() async throws -> AudioSourceCatalog {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let visiblePIDs = Set(content.windows.compactMap { $0.owningApplication?.processID })

        let applicationSources = content.applications
            .filter { application in
                application.processID != ownPID
                    && visiblePIDs.contains(application.processID)
                    && !application.applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { application in
                let stableID = application.bundleIdentifier.isEmpty
                    ? "process:\(application.processID)"
                    : "application:\(application.bundleIdentifier)"
                return AudioSourceOption(
                    id: stableID,
                    title: application.applicationName,
                    kind: .application(
                        bundleIdentifier: application.bundleIdentifier,
                        processID: application.processID
                    )
                )
            }
            .uniqued(by: \AudioSourceOption.id)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        var microphoneSources = Self.microphoneDevices()
            .map { device in
                AudioSourceOption(
                    id: "microphone:\(device.uniqueID)",
                    title: device.localizedName,
                    kind: .microphone(uniqueID: device.uniqueID)
                )
            }
            .uniqued(by: \.id)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        if let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID,
           let index = microphoneSources.firstIndex(where: {
               if case let .microphone(uniqueID) = $0.kind {
                   return uniqueID == defaultID
               }
               return false
           }),
           index != microphoneSources.startIndex {
            let defaultSource = microphoneSources.remove(at: index)
            microphoneSources.insert(defaultSource, at: 0)
        }

        return AudioSourceCatalog(
            incoming: [.systemAudio] + applicationSources,
            microphones: microphoneSources
        )
    }

    func start(
        _ request: AudioCaptureRequest,
        liveAudioSink: LiveAudioSampleSink?
    ) async throws {
        guard activeRequest == nil else {
            throw AudioCaptureError.alreadyRecording
        }

        guard await requestMicrophoneAccess() else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        try fileManager.createDirectory(at: request.folderURL, withIntermediateDirectories: true)

        let incomingURL = request.folderURL.appendingPathComponent(Constants.incomingFilename)
        let outgoingURL = request.folderURL.appendingPathComponent(Constants.outgoingFilename)
        let timeline = CaptureTimeline()
        let activationGate = CaptureActivationGate()
        let incomingWriter = SampleBufferAudioWriter(outputURL: incomingURL, timeline: timeline)
        let outgoingWriter = SampleBufferAudioWriter(outputURL: outgoingURL, timeline: timeline)

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let filter = try Self.makeContentFilter(
                for: request.incomingSource,
                content: content
            )
            let streamConfiguration = Self.makeStreamConfiguration()
            let systemOutput = SystemAudioOutput(
                writer: incomingWriter,
                timeline: timeline,
                activationGate: activationGate,
                liveAudioSink: liveAudioSink
            ) { [weak self] error in
                Task { @MainActor in
                    self?.streamFailure = error
                }
            }
            let stream = SCStream(
                filter: filter,
                configuration: streamConfiguration,
                delegate: systemOutput
            )
            try stream.addStreamOutput(
                systemOutput,
                type: .audio,
                sampleHandlerQueue: systemAudioQueue
            )

            let microphone = try resolveMicrophone(request.microphone)
            let microphoneCapture = try makeMicrophoneCapture(
                device: microphone,
                writer: outgoingWriter,
                timeline: timeline,
                activationGate: activationGate,
                liveAudioSink: liveAudioSink
            )

            activeRequest = request
            self.incomingWriter = incomingWriter
            self.outgoingWriter = outgoingWriter
            activeLiveAudioSink = liveAudioSink
            self.activationGate = activationGate
            systemStream = stream
            self.systemOutput = systemOutput
            microphoneSession = microphoneCapture.session
            microphoneOutput = microphoneCapture.output
            microphoneDelegate = microphoneCapture.delegate
            streamFailure = nil
            microphoneFailure = nil
            isStopping = false
            installMicrophoneObservers(
                session: microphoneCapture.session,
                device: microphone
            )

            do {
                try await stream.startCapture()
                try await startMicrophoneSession(microphoneCapture.session)
                microphoneCapture.delegate.session = microphoneCapture.session
                // Flush callbacks already queued during startup while the gate is
                // still closed, so an old PTS cannot cross the activation edge.
                await drainCaptureQueues()
                // Both capture sources can emit during their asynchronous startup.
                // Keep those unstable/pre-call buffers out of both the durable and
                // live paths, then establish one shared epoch and open atomically.
                timeline.activate()
                activationGate.open()
            } catch {
                isStopping = true
                activationGate.close()
                try? await stream.stopCapture()
                await stopMicrophoneSession(microphoneCapture.session)
                await drainCaptureQueues()
                liveAudioSink?.stopAccepting()
                clearActiveCapture()
                _ = try? await incomingWriter.finish()
                _ = try? await outgoingWriter.finish()
                throw error
            }
        } catch let error as AudioCaptureError {
            clearActiveCapture()
            throw error
        } catch {
            clearActiveCapture()
            throw AudioCaptureError.captureConfigurationFailed(error.localizedDescription)
        }
    }

    func stop() async throws -> CapturedAudioFiles {
        guard let request = activeRequest,
              let incomingWriter,
              let outgoingWriter else {
            throw AudioCaptureError.notRecording
        }

        let stream = systemStream
        let microphoneSession = microphoneSession
        isStopping = true
        activationGate?.close()

        var systemStopError: Error?
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                systemStopError = error
            }
        }
        if let microphoneSession {
            await stopMicrophoneSession(microphoneSession)
        }
        await drainCaptureQueues()
        activeLiveAudioSink?.stopAccepting()
        await Task.yield()

        let finalStreamFailure = streamFailure ?? systemStopError
        let finalMicrophoneFailure = microphoneFailure
        clearActiveCapture()

        var warnings: [AudioCaptureWarning] = []
        var incomingURL: URL?
        var outgoingURL: URL?

        do {
            incomingURL = try await incomingWriter.finish()
        } catch {
            warnings.append(.incoming(error.localizedDescription))
        }
        do {
            outgoingURL = try await outgoingWriter.finish()
        } catch {
            warnings.append(.outgoing(error.localizedDescription))
        }
        let incomingWriterDroppedBuffers = await incomingWriter.droppedBufferCount()
        let outgoingWriterDroppedBuffers = await outgoingWriter.droppedBufferCount()
        if incomingWriterDroppedBuffers > 0 {
            warnings.append(.incoming("пропущено аудиобуферов: \(incomingWriterDroppedBuffers)"))
        }
        if outgoingWriterDroppedBuffers > 0 {
            warnings.append(.outgoing("пропущено аудиобуферов: \(outgoingWriterDroppedBuffers)"))
        }

        if let finalStreamFailure {
            warnings.append(.incoming(finalStreamFailure.localizedDescription))
        } else if incomingURL == nil {
            warnings.append(.incoming("аудиоданные не получены"))
        }
        if let finalMicrophoneFailure {
            warnings.append(.outgoing(finalMicrophoneFailure.localizedDescription))
        } else if outgoingURL == nil {
            warnings.append(.outgoing("аудиоданные не получены"))
        }

        var combinedURL: URL?
        if incomingURL != nil, outgoingURL != nil {
            let outputURL = request.folderURL.appendingPathComponent(Constants.combinedFilename)
            let incoming = incomingURL
            let outgoing = outgoingURL
            // The combined artifact is convenient but never authoritative.
            // Raw tracks are returned immediately so a long export cannot delay
            // recording persistence, shutdown, or mandatory reconciliation.
            Task.detached(priority: .utility) {
                _ = try? await AudioTrackMixer.makeCombinedFile(
                    incomingURL: incoming,
                    outgoingURL: outgoing,
                    outputURL: outputURL,
                    fileManager: FileManager()
                )
            }
            combinedURL = fileManager.fileExists(atPath: outputURL.path) ? outputURL : nil
        }

        let result = CapturedAudioFiles(
            incomingFilename: incomingURL?.lastPathComponent,
            outgoingFilename: outgoingURL?.lastPathComponent,
            combinedFilename: combinedURL?.lastPathComponent,
            warnings: warnings.uniqued(by: \.localizedDescription),
            quality: AudioCaptureQuality(
                incomingWriterDroppedBuffers: incomingWriterDroppedBuffers,
                outgoingWriterDroppedBuffers: outgoingWriterDroppedBuffers
            )
        )

        guard result.hasAudio else {
            if let firstWarning = result.warnings.first {
                throw AudioCaptureError.captureStopped(firstWarning.localizedDescription)
            }
            throw AudioCaptureError.noAudioCaptured
        }

        return result
    }

    private func resolveMicrophone(_ source: AudioSourceOption) throws -> AVCaptureDevice {
        guard case let .microphone(uniqueID) = source.kind else {
            throw AudioCaptureError.microphoneUnavailable(source.title)
        }
        if let matchingDevice = AVCaptureDevice(uniqueID: uniqueID) {
            return matchingDevice
        }
        throw AudioCaptureError.microphoneUnavailable(source.title)
    }

    private func makeMicrophoneCapture(
        device: AVCaptureDevice,
        writer: SampleBufferAudioWriter,
        timeline: CaptureTimeline,
        activationGate: CaptureActivationGate,
        liveAudioSink: LiveAudioSampleSink?
    ) throws -> (session: AVCaptureSession, output: AVCaptureAudioDataOutput, delegate: MicrophoneAudioOutput) {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // Some USB microphones advertise packet/sample metadata that does not
        // match their native payload size. Ask AVFoundation to deliver one
        // canonical PCM contract so both the file writer and live converter see
        // consistent sample counts and durations.
        output.audioSettings = CanonicalMicrophoneCaptureFormat.audioSettings
        let delegate = MicrophoneAudioOutput(
            writer: writer,
            timeline: timeline,
            activationGate: activationGate,
            liveAudioSink: liveAudioSink
        )

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            throw AudioCaptureError.captureConfigurationFailed("macOS отклонила выбранный микрофон")
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            throw AudioCaptureError.captureConfigurationFailed("macOS не создала аудиовыход микрофона")
        }
        output.setSampleBufferDelegate(delegate, queue: microphoneQueue)
        session.addOutput(output)

        return (session, output, delegate)
    }

    private func installMicrophoneObservers(
        session: AVCaptureSession,
        device: AVCaptureDevice
    ) {
        let center = NotificationCenter.default
        let runtimeError = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            Task { @MainActor in
                guard let self, !self.isStopping else { return }
                self.microphoneFailure = error
                    ?? AudioCaptureError.captureStopped("сессия микрофона завершилась с ошибкой")
            }
        }
        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopping else { return }
                self.microphoneFailure = AudioCaptureError.captureStopped("микрофон был отключён")
            }
        }
        microphoneObservers = [runtimeError, disconnected]
    }

    private func startMicrophoneSession(_ session: AVCaptureSession) async throws {
        let isRunning = await withCheckedContinuation { continuation in
            microphoneControlQueue.async {
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
        guard isRunning else {
            throw AudioCaptureError.captureConfigurationFailed("микрофон не начал запись")
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

    private func drainCaptureQueues() async {
        await drain(systemAudioQueue)
        await drain(microphoneQueue)
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func clearActiveCapture() {
        for observer in microphoneObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        microphoneObservers = []
        activeRequest = nil
        systemStream = nil
        systemOutput = nil
        microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
        microphoneOutput = nil
        microphoneSession = nil
        microphoneDelegate = nil
        incomingWriter = nil
        outgoingWriter = nil
        activeLiveAudioSink = nil
        activationGate?.close()
        activationGate = nil
        streamFailure = nil
        microphoneFailure = nil
        isStopping = false
    }

    private static func makeStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        return configuration
    }

    private static func makeContentFilter(
        for source: AudioSourceOption,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        guard !content.displays.isEmpty else {
            throw AudioCaptureError.systemAudioUnavailable
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        if case .systemAudio = source.kind {
            let ownApplications = content.applications.filter { $0.processID == ownPID }
            return SCContentFilter(
                display: content.displays[0],
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
        }

        guard case let .application(bundleIdentifier, processID) = source.kind else {
            throw AudioCaptureError.sourceApplicationUnavailable(source.title)
        }
        let exactProcess = content.applications.filter { $0.processID == processID }
        let bundleMatches = content.applications.filter {
            !bundleIdentifier.isEmpty && $0.bundleIdentifier == bundleIdentifier
        }
        let matchingApplications = !exactProcess.isEmpty
            ? exactProcess
            : (bundleMatches.count == 1 ? bundleMatches : [])
        guard !matchingApplications.isEmpty else {
            throw AudioCaptureError.sourceApplicationUnavailable(source.title)
        }

        let matchingPIDs = Set(matchingApplications.map(\.processID))
        let matchingWindows = content.windows.filter { window in
            guard let application = window.owningApplication else { return false }
            return matchingPIDs.contains(application.processID)
        }
        let display = bestDisplay(for: matchingWindows, displays: content.displays)

        return SCContentFilter(
            display: display,
            including: matchingApplications,
            exceptingWindows: []
        )
    }

    private static func bestDisplay(for windows: [SCWindow], displays: [SCDisplay]) -> SCDisplay {
        guard let firstDisplay = displays.first else {
            preconditionFailure("At least one display is required")
        }
        guard let firstWindow = windows.first else { return firstDisplay }

        return displays.max { left, right in
            left.frame.intersection(firstWindow.frame).area
                < right.frame.intersection(firstWindow.frame).area
        } ?? firstDisplay
    }

    private static func microphoneDevices() -> [AVCaptureDevice] {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            ).devices
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: SampleBufferAudioWriter
    private let timeline: CaptureTimeline
    private let activationGate: CaptureActivationGate
    private let liveAudioSink: LiveAudioSampleSink?
    private let onFailure: (Error) -> Void

    init(
        writer: SampleBufferAudioWriter,
        timeline: CaptureTimeline,
        activationGate: CaptureActivationGate,
        liveAudioSink: LiveAudioSampleSink?,
        onFailure: @escaping (Error) -> Void
    ) {
        self.writer = writer
        self.timeline = timeline
        self.activationGate = activationGate
        self.liveAudioSink = liveAudioSink
        self.onFailure = onFailure
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              activationGate.isOpen else { return }
        writer.append(sampleBuffer, sourceClock: stream.synchronizationClock)
        offerToLiveSink(
            sampleBuffer,
            sourceClock: stream.synchronizationClock,
            track: .incoming
        )
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure(error)
    }

    private func offerToLiveSink(
        _ sampleBuffer: CMSampleBuffer,
        sourceClock: CMClock?,
        track: AudioTrack
    ) {
        guard let liveAudioSink else { return }
        guard let start = timeline.callRelativePresentationNanoseconds(
            sampleBuffer,
            from: sourceClock
        ) else {
            // A callback may cross the gate immediately after activation while
            // its short audio packet still belongs to the pre-call preroll.
            // It is outside the call by definition, not lost in-call audio.
            guard !timeline.isStartupPreroll(sampleBuffer, from: sourceClock) else {
                return
            }
            liveAudioSink.recordDroppedFrame(
                track: track,
                durationNanoseconds: CaptureTimeline.estimatedDurationNanoseconds(sampleBuffer)
            )
            return
        }
        liveAudioSink.offer(
            CapturedAudioFrame(
                track: track,
                sampleBuffer: sampleBuffer,
                startCallNanoseconds: start
            )
        )
    }
}

private final class MicrophoneAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let writer: SampleBufferAudioWriter
    private let timeline: CaptureTimeline
    private let activationGate: CaptureActivationGate
    private let liveAudioSink: LiveAudioSampleSink?
    weak var session: AVCaptureSession?

    init(
        writer: SampleBufferAudioWriter,
        timeline: CaptureTimeline,
        activationGate: CaptureActivationGate,
        liveAudioSink: LiveAudioSampleSink?
    ) {
        self.writer = writer
        self.timeline = timeline
        self.activationGate = activationGate
        self.liveAudioSink = liveAudioSink
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid, activationGate.isOpen else { return }
        let sourceClock = session?.synchronizationClock
        writer.append(sampleBuffer, sourceClock: sourceClock)
        guard let liveAudioSink else { return }
        guard let start = timeline.callRelativePresentationNanoseconds(
            sampleBuffer,
            from: sourceClock
        ) else {
            guard !timeline.isStartupPreroll(sampleBuffer, from: sourceClock) else {
                return
            }
            liveAudioSink.recordDroppedFrame(
                track: .outgoing,
                durationNanoseconds: CaptureTimeline.estimatedDurationNanoseconds(sampleBuffer)
            )
            return
        }
        liveAudioSink.offer(
            CapturedAudioFrame(
                track: .outgoing,
                sampleBuffer: sampleBuffer,
                startCallNanoseconds: start
            )
        )
    }
}

enum CanonicalMicrophoneCaptureFormat {
    static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}

/// Suppresses startup and shutdown callbacks until both capture sources share a
/// stable call epoch. Those callbacks are outside the call and therefore are not
/// counted as recording loss.
final class CaptureActivationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openState = false

    var isOpen: Bool {
        lock.withLock { openState }
    }

    func open() {
        lock.withLock { openState = true }
    }

    func close() {
        lock.withLock { openState = false }
    }
}

final class CaptureTimeline: @unchecked Sendable {
    private static let maximumStartupPrerollNanoseconds: Double = 250_000_000
    private let lock = NSLock()
    private let hostClock = CMClockGetHostTimeClock()
    private var origin: CMTime?

    func activate(atHostTime hostTime: CMTime? = nil) {
        lock.withLock {
            origin = hostTime ?? CMClockGetTime(hostClock)
        }
    }

    func callRelativePresentationNanoseconds(
        _ sampleBuffer: CMSampleBuffer,
        from sourceClock: CMClock?
    ) -> UInt64? {
        let origin = lock.withLock { self.origin }
        guard let origin else { return nil }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let relativePTS = relativeTime(
            sourcePTS,
            from: sourceClock,
            origin: origin
        ) else { return nil }
        return UInt64(relativePTS.seconds * 1_000_000_000)
    }

    func retimedBuffer(
        _ sampleBuffer: CMSampleBuffer,
        from sourceClock: CMClock?
    ) throws -> CMSampleBuffer? {
        let origin = lock.withLock { self.origin }
        guard let origin else { return nil }

        var timingCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard status == noErr, timingCount > 0 else {
            throw AudioCaptureError.captureConfigurationFailed("не удалось прочитать таймкоды аудио")
        }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        status = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: timingCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: &timingCount
            )
        }
        guard status == noErr else {
            throw AudioCaptureError.captureConfigurationFailed("не удалось прочитать таймкоды аудио")
        }

        for index in timing.indices {
            let sourcePTS = timing[index].presentationTimeStamp
            guard let relativePTS = relativeTime(
                sourcePTS,
                from: sourceClock,
                origin: origin
            ) else { return nil }

            var convertedDuration = timing[index].duration
            if convertedDuration.isValid, let sourceClock {
                let hostPTS = CMSyncConvertTime(sourcePTS, from: sourceClock, to: hostClock)
                let hostEnd = CMSyncConvertTime(
                    CMTimeAdd(sourcePTS, convertedDuration),
                    from: sourceClock,
                    to: hostClock
                )
                convertedDuration = CMTimeSubtract(hostEnd, hostPTS)
            }

            var convertedDTS = timing[index].decodeTimeStamp
            if convertedDTS.isValid {
                guard let relativeDTS = relativeTime(
                    convertedDTS,
                    from: sourceClock,
                    origin: origin
                ) else { return nil }
                convertedDTS = relativeDTS
            }

            timing[index] = CMSampleTimingInfo(
                duration: convertedDuration,
                presentationTimeStamp: relativePTS,
                decodeTimeStamp: convertedDTS
            )
        }

        var retimedBuffer: CMSampleBuffer?
        status = timing.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: timing.count,
                sampleTimingArray: buffer.baseAddress!,
                sampleBufferOut: &retimedBuffer
            )
        }
        guard status == noErr else {
            throw AudioCaptureError.captureConfigurationFailed("не удалось синхронизировать аудиодорожку")
        }
        return retimedBuffer
    }

    /// Capture callbacks are delivered in packets. Right after the activation
    /// gate opens, the first delivered packet can legitimately begin a few
    /// milliseconds before the shared call origin. Ignoring that bounded
    /// preroll prevents a false recording-gap error while still treating an
    /// unrelated/invalid timestamp epoch as real loss.
    func isStartupPreroll(
        _ sampleBuffer: CMSampleBuffer,
        from sourceClock: CMClock?
    ) -> Bool {
        guard let origin = lock.withLock({ self.origin }) else { return false }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourcePTS.isValid else { return false }
        let hostTime = sourceClock.map {
            CMSyncConvertTime(sourcePTS, from: $0, to: hostClock)
        } ?? sourcePTS
        let relative = CMTimeSubtract(hostTime, origin)
        guard relative.isValid,
              relative.seconds.isFinite,
              CMTimeCompare(relative, .zero) < 0 else { return false }
        let prerollNanoseconds = -relative.seconds * 1_000_000_000
        return prerollNanoseconds <= Self.maximumStartupPrerollNanoseconds
    }

    static func estimatedDurationNanoseconds(_ sampleBuffer: CMSampleBuffer) -> UInt64 {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.seconds.isFinite, duration.seconds > 0 {
            return UInt64(duration.seconds * 1_000_000_000)
        }
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            stream.pointee.mSampleRate > 0
        else { return 0 }
        let seconds = Double(CMSampleBufferGetNumSamples(sampleBuffer))
            / stream.pointee.mSampleRate
        return UInt64(max(0, seconds) * 1_000_000_000)
    }

    private func relativeTime(
        _ sourceTime: CMTime,
        from sourceClock: CMClock?,
        origin: CMTime
    ) -> CMTime? {
        guard sourceTime.isValid else { return nil }
        // AVCapture timestamps normally share the host timebase. When the
        // optional synchronization clock is temporarily unavailable, using a
        // valid host-based PTS directly preserves the writer and live branches.
        // A PTS from another epoch fails the nonnegative/finite checks below and
        // is accounted as a dropped frame by the caller.
        let hostTime = sourceClock.map {
            CMSyncConvertTime(sourceTime, from: $0, to: hostClock)
        } ?? sourceTime
        let relative = CMTimeSubtract(hostTime, origin)
        guard relative.isValid,
              CMTimeCompare(relative, .zero) >= 0,
              relative.seconds.isFinite else { return nil }
        return relative
    }
}

private final class SampleBufferAudioWriter: @unchecked Sendable {
    private enum Constants {
        /// Keeps capture callbacks non-blocking while allowing AVAssetWriter to
        /// recover from ordinary, transient backpressure. At typical capture
        /// formats this is bounded to only a few megabytes per track.
        static let maximumPendingDurationNanoseconds: UInt64 = 10_000_000_000
        static let maximumPendingBufferCount = 4_096
        static let readinessRetryInterval = DispatchTimeInterval.milliseconds(5)
        static let finishDrainTimeoutNanoseconds: UInt64 = 15_000_000_000
    }

    private struct PendingBuffer {
        let sampleBuffer: RetainedSampleBuffer
        let durationNanoseconds: UInt64
    }

    private let outputURL: URL
    private let workingURL: URL
    private let timeline: CaptureTimeline
    private let queue = DispatchQueue(label: "com.aicallassistant.capture.file-writer")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var storedError: Error?
    private var hasWrittenSamples = false
    private var isFinishing = false
    private var hasStartedFinalizing = false
    private var droppedBuffers = 0
    private var pendingBuffers: [PendingBuffer] = []
    private var pendingBufferHead = 0
    private var pendingDurationNanoseconds: UInt64 = 0
    private var drainRetryScheduled = false
    private var finishDrainDeadlineNanoseconds: UInt64?
    private var finishContinuation: CheckedContinuation<URL?, Error>?

    init(outputURL: URL, timeline: CaptureTimeline) {
        self.outputURL = outputURL
        self.workingURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(outputURL.pathExtension)
        self.timeline = timeline
    }

    func append(_ sampleBuffer: CMSampleBuffer, sourceClock: CMClock?) {
        let retainedSampleBuffer = RetainedSampleBuffer(sampleBuffer)
        queue.async { [weak self, retainedSampleBuffer] in
            self?.appendOnQueue(retainedSampleBuffer.value, sourceClock: sourceClock)
        }
    }

    func finish() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                guard !self.isFinishing else {
                    continuation.resume(throwing: AudioCaptureError.captureConfigurationFailed("повторное завершение аудиофайла"))
                    return
                }
                self.isFinishing = true
                self.finishContinuation = continuation
                self.finishDrainDeadlineNanoseconds = DispatchTime.now().uptimeNanoseconds
                    + Constants.finishDrainTimeoutNanoseconds
                self.drainPendingBuffers()
            }
        }
    }

    func droppedBufferCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.droppedBuffers ?? 0)
            }
        }
    }

    private func appendOnQueue(_ sampleBuffer: CMSampleBuffer, sourceClock: CMClock?) {
        guard !isFinishing, storedError == nil else { return }

        do {
            guard let sampleBuffer = try timeline.retimedBuffer(
                sampleBuffer,
                from: sourceClock
            ) else {
                if !timeline.isStartupPreroll(sampleBuffer, from: sourceClock) {
                    droppedBuffers += 1
                }
                return
            }
            if writer == nil {
                try prepareWriter(using: sampleBuffer)
            }
            guard let writer, writer.status == .writing else {
                throw writer?.error
                    ?? AudioCaptureError.captureConfigurationFailed("аудиофайл перестал принимать данные")
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard timestamp.isValid, CMTimeCompare(timestamp, .zero) >= 0 else {
                droppedBuffers += 1
                return
            }
            try enqueue(sampleBuffer)
            drainPendingBuffers()
        } catch {
            storedError = error
            completeFinishAfterFailureIfNeeded()
        }
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) throws {
        let duration = CaptureTimeline.estimatedDurationNanoseconds(sampleBuffer)
        let queuedCount = pendingBuffers.count - pendingBufferHead
        let durationFits = duration <= Constants.maximumPendingDurationNanoseconds
            && pendingDurationNanoseconds
                <= Constants.maximumPendingDurationNanoseconds - duration
        guard queuedCount < Constants.maximumPendingBufferCount, durationFits else {
            // A bounded queue avoids unbounded memory growth. Unlike the old
            // readiness branch, overflow is an explicit recording failure rather
            // than a seemingly successful file with silent holes.
            droppedBuffers += 1
            throw AudioCaptureError.captureConfigurationFailed(
                "очередь записи аудио переполнена"
            )
        }
        pendingBuffers.append(PendingBuffer(
            sampleBuffer: RetainedSampleBuffer(sampleBuffer),
            durationNanoseconds: duration
        ))
        pendingDurationNanoseconds += duration
    }

    private func drainPendingBuffers() {
        guard storedError == nil else {
            completeFinishAfterFailureIfNeeded()
            return
        }
        guard let writer, let input else {
            completeFinishWithoutSamplesIfNeeded()
            return
        }
        guard writer.status == .writing else {
            storedError = writer.error
                ?? AudioCaptureError.captureConfigurationFailed("аудиофайл перестал принимать данные")
            completeFinishAfterFailureIfNeeded()
            return
        }

        while pendingBufferHead < pendingBuffers.count,
              input.isReadyForMoreMediaData {
            let pending = pendingBuffers[pendingBufferHead]
            guard input.append(pending.sampleBuffer.value) else {
                storedError = writer.error
                    ?? AudioCaptureError.captureConfigurationFailed("не удалось записать аудиобуфер")
                completeFinishAfterFailureIfNeeded()
                return
            }
            hasWrittenSamples = true
            pendingBufferHead += 1
            pendingDurationNanoseconds -= min(
                pendingDurationNanoseconds,
                pending.durationNanoseconds
            )
        }
        compactPendingBuffersIfNeeded()

        if pendingBufferHead == pendingBuffers.count {
            if isFinishing {
                beginFinalizing(writer: writer, input: input)
            }
            return
        }

        if let deadline = finishDrainDeadlineNanoseconds,
           DispatchTime.now().uptimeNanoseconds >= deadline {
            storedError = AudioCaptureError.captureConfigurationFailed(
                "не удалось дождаться записи очереди аудио"
            )
            completeFinishAfterFailureIfNeeded()
            return
        }
        scheduleDrainRetry()
    }

    private func compactPendingBuffersIfNeeded() {
        guard pendingBufferHead > 0 else { return }
        if pendingBufferHead == pendingBuffers.count {
            pendingBuffers.removeAll(keepingCapacity: true)
            pendingBufferHead = 0
        } else if pendingBufferHead >= 512 {
            pendingBuffers.removeFirst(pendingBufferHead)
            pendingBufferHead = 0
        }
    }

    private func scheduleDrainRetry() {
        guard !drainRetryScheduled else { return }
        drainRetryScheduled = true
        queue.asyncAfter(deadline: .now() + Constants.readinessRetryInterval) { [weak self] in
            guard let self else { return }
            self.drainRetryScheduled = false
            self.drainPendingBuffers()
        }
    }

    private func completeFinishWithoutSamplesIfNeeded() {
        guard isFinishing, let continuation = finishContinuation else { return }
        finishContinuation = nil
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: workingURL)
        continuation.resume(returning: nil)
    }

    private func completeFinishAfterFailureIfNeeded() {
        guard isFinishing,
              let error = storedError,
              let continuation = finishContinuation else { return }
        finishContinuation = nil
        writer?.cancelWriting()
        pendingBuffers.removeAll()
        pendingBufferHead = 0
        pendingDurationNanoseconds = 0
        try? FileManager.default.removeItem(at: workingURL)
        continuation.resume(throwing: error)
    }

    private func beginFinalizing(writer: AVAssetWriter, input: AVAssetWriterInput) {
        guard isFinishing,
              !hasStartedFinalizing,
              let continuation = finishContinuation else { return }
        guard hasWrittenSamples else {
            completeFinishWithoutSamplesIfNeeded()
            return
        }
        hasStartedFinalizing = true
        finishContinuation = nil
        input.markAsFinished()
        let writerBox = UncheckedSendableBox(writer)
        writer.finishWriting { [self] in
            queue.async {
                let writer = writerBox.value
                if writer.status == .completed {
                    do {
                        try FileManager.default.moveItem(
                            at: self.workingURL,
                            to: self.outputURL
                        )
                        continuation.resume(returning: self.outputURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    try? FileManager.default.removeItem(at: self.workingURL)
                    continuation.resume(throwing: writer.error ?? AudioCaptureError.captureConfigurationFailed("не удалось завершить аудиофайл"))
                }
            }
        }
    }

    private func prepareWriter(using sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw AudioCaptureError.captureConfigurationFailed("неизвестный формат аудио")
        }

        let channels = max(1, min(Int(streamDescription.pointee.mChannelsPerFrame), 2))
        let sampleRate = max(streamDescription.pointee.mSampleRate, 8_000)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000
        ]

        try? FileManager.default.removeItem(at: workingURL)
        let writer = try AVAssetWriter(outputURL: workingURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw AudioCaptureError.captureConfigurationFailed("кодек AAC не принял аудиопоток")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? AudioCaptureError.captureConfigurationFailed("не удалось открыть аудиофайл")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
    }
}

/// Owns the callback-provided Core Media buffer until the writer queue consumes it.
///
/// `CMSampleBuffer` is reference-counted and can safely cross this boundary when
/// retained, but the SDK type does not declare `Sendable`. The buffer is only read
/// on the writer's serial queue and is never mutated by this wrapper.
private final class RetainedSampleBuffer: @unchecked Sendable {
    let value: CMSampleBuffer

    init(_ value: CMSampleBuffer) {
        self.value = value
    }
}

private enum AudioTrackMixer {
    static func makeCombinedFile(
        incomingURL: URL?,
        outgoingURL: URL?,
        outputURL: URL,
        fileManager: FileManager
    ) async throws -> URL? {
        guard let incomingURL, let outgoingURL else { return nil }
        let sourceURLs = [incomingURL, outgoingURL]
        let workingURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(outputURL.pathExtension)

        let composition = AVMutableComposition()
        for sourceURL in sourceURLs {
            let asset = AVURLAsset(url: sourceURL)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                continue
            }
            let duration = try await asset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }

        guard !composition.tracks(withMediaType: .audio).isEmpty else { return nil }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioCaptureError.captureConfigurationFailed("не удалось создать общий аудиофайл")
        }

        exporter.outputURL = workingURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false

        let exporterBox = UncheckedSendableBox(exporter)
        let fileManagerBox = UncheckedSendableBox(fileManager)
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                let exporter = exporterBox.value
                let fileManager = fileManagerBox.value
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    try? fileManager.removeItem(at: workingURL)
                    continuation.resume(throwing: exporter.error ?? AudioCaptureError.captureConfigurationFailed("не удалось свести аудиодорожки"))
                default:
                    try? fileManager.removeItem(at: workingURL)
                    continuation.resume(throwing: AudioCaptureError.captureConfigurationFailed("экспорт общего аудио завершился некорректно"))
                }
            }
        }

        try fileManager.moveItem(at: workingURL, to: outputURL)
        return outputURL
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
