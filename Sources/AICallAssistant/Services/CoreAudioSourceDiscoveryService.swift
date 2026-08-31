@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// Discovers the processes that Core Audio can tap without asking macOS for
/// screen-recording access. The process list contains only clients currently
/// connected to the HAL, which is exactly the set a process tap can resolve.
@MainActor
final class CoreAudioSourceDiscoveryService: AudioSourceDiscoveryService {
    typealias ProcessLoader = () throws -> [CoreAudioProcessDescriptor]
    typealias MicrophoneLoader = @MainActor () -> [AudioSourceOption]

    private let processLoader: ProcessLoader
    private let microphoneLoader: MicrophoneLoader
    private let ownProcessID: Int32
    private let ownBundleIdentifier: String?

    init(
        processLoader: @escaping ProcessLoader = CoreAudioProcessCatalog.load,
        microphoneLoader: @escaping MicrophoneLoader = CoreAudioSourceDiscoveryService.microphoneSources,
        ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.processLoader = processLoader
        self.microphoneLoader = microphoneLoader
        self.ownProcessID = ownProcessID
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    func discoverSources() async throws -> AudioSourceCatalog {
        let applications = CoreAudioProcessSourceBuilder.options(
            from: try processLoader(),
            excludingProcessID: ownProcessID,
            excludingBundleIdentifier: ownBundleIdentifier
        )

        return AudioSourceCatalog(
            incoming: [.systemAudio] + applications,
            microphones: microphoneLoader()
        )
    }

    private static func microphoneSources() -> [AudioSourceOption] {
        var sources = microphoneDevices()
            .map { device in
                AudioSourceOption(
                    id: "microphone:\(device.uniqueID)",
                    title: device.localizedName,
                    kind: .microphone(uniqueID: device.uniqueID)
                )
            }
            .uniqued(by: \.id)
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

        if let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID,
           let index = sources.firstIndex(where: { source in
               guard case let .microphone(uniqueID) = source.kind else { return false }
               return uniqueID == defaultID
           }),
           index != sources.startIndex {
            sources.insert(sources.remove(at: index), at: 0)
        }
        return sources
    }

    private static func microphoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

@MainActor
protocol AudioSourceDiscoveryService: AnyObject {
    func discoverSources() async throws -> AudioSourceCatalog
}

@MainActor
final class CaptureServiceSourceDiscoveryAdapter: AudioSourceDiscoveryService {
    private let captureService: AudioCaptureService

    init(captureService: AudioCaptureService) {
        self.captureService = captureService
    }

    func discoverSources() async throws -> AudioSourceCatalog {
        try await captureService.discoverSources()
    }
}

struct CoreAudioProcessDescriptor: Equatable, Sendable {
    let processID: Int32
    let bundleIdentifier: String
    let title: String
    let isProducingOutput: Bool
}

enum CoreAudioProcessSourceBuilder {
    static func options(
        from descriptors: [CoreAudioProcessDescriptor],
        excludingProcessID ownProcessID: Int32,
        excludingBundleIdentifier ownBundleIdentifier: String?
    ) -> [AudioSourceOption] {
        let ownBundle = normalized(ownBundleIdentifier ?? "")
        var groups: [String: [CoreAudioProcessDescriptor]] = [:]

        for descriptor in descriptors where descriptor.processID > 0 {
            guard descriptor.processID != ownProcessID else { continue }

            let bundle = descriptor.bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let title = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundle.isEmpty || !title.isEmpty else { continue }
            guard ownBundle.isEmpty || normalized(bundle) != ownBundle else { continue }

            let groupingKey = !bundle.isEmpty
                ? "bundle:\(normalized(bundle))"
                : "title:\(normalized(title))"
            groups[groupingKey, default: []].append(
                CoreAudioProcessDescriptor(
                    processID: descriptor.processID,
                    bundleIdentifier: bundle,
                    title: title,
                    isProducingOutput: descriptor.isProducingOutput
                )
            )
        }

        return groups.values.compactMap { group in
            guard let representative = group.sorted(by: preferredProcess).first else {
                return nil
            }

            let title = group
                .map(\.title)
                .filter { !$0.isEmpty }
                .sorted(by: localizedTitleOrder)
                .first
                ?? representative.bundleIdentifier
            guard !title.isEmpty else { return nil }

            let bundleIdentifier = representative.bundleIdentifier
            let stableID = bundleIdentifier.isEmpty
                ? "process:\(representative.processID)"
                : "application:\(normalized(bundleIdentifier))"
            return AudioSourceOption(
                id: stableID,
                title: title,
                kind: .application(
                    bundleIdentifier: bundleIdentifier,
                    processID: representative.processID
                )
            )
        }
        .sorted { localizedTitleOrder($0.title, $1.title) }
    }

    private static func preferredProcess(
        _ lhs: CoreAudioProcessDescriptor,
        _ rhs: CoreAudioProcessDescriptor
    ) -> Bool {
        if lhs.isProducingOutput != rhs.isProducingOutput {
            return lhs.isProducingOutput
        }
        let lhsHasTitle = !lhs.title.isEmpty
        let rhsHasTitle = !rhs.title.isEmpty
        if lhsHasTitle != rhsHasTitle {
            return lhsHasTitle
        }
        return lhs.processID < rhs.processID
    }

    private static func localizedTitleOrder(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs < rhs
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}

private enum CoreAudioProcessCatalog {
    static func load() throws -> [CoreAudioProcessDescriptor] {
        try processObjectIDs().compactMap(makeDescriptor)
    }

    private static func processObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount
            ),
            operation: "получить список аудиопроцессов"
        )
        guard byteCount > 0 else { return [] }

        var objectIDs = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        let status = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        try check(status, operation: "прочитать список аудиопроцессов")
        return objectIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func makeDescriptor(
        _ objectID: AudioObjectID
    ) -> CoreAudioProcessDescriptor? {
        guard let processID: pid_t = try? scalar(
            objectID,
            selector: kAudioProcessPropertyPID,
            defaultValue: 0
        ), processID > 0 else { return nil }

        let bundleIdentifier = (try? retainedString(
            objectID,
            selector: kAudioProcessPropertyBundleID
        )) ?? ""
        let runningApplication = NSRunningApplication(
            processIdentifier: processID
        )
        let title = resolvedTitle(
            runningApplication: runningApplication,
            bundleIdentifier: bundleIdentifier,
            processID: processID
        )
        let isProducingOutput: UInt32 = (try? scalar(
            objectID,
            selector: kAudioProcessPropertyIsRunningOutput,
            defaultValue: 0
        )) ?? 0

        return CoreAudioProcessDescriptor(
            processID: processID,
            bundleIdentifier: bundleIdentifier,
            title: title,
            isProducingOutput: isProducingOutput != 0
        )
    }

    private static func resolvedTitle(
        runningApplication: NSRunningApplication?,
        bundleIdentifier: String,
        processID: pid_t
    ) -> String {
        if let localizedName = runningApplication?.localizedName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !localizedName.isEmpty {
            return localizedName
        }

        if let bundleURL = runningApplication?.bundleURL {
            let filename = bundleURL.deletingPathExtension().lastPathComponent
            if !filename.isEmpty { return filename }
        }

        if !bundleIdentifier.isEmpty,
           let applicationURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleIdentifier
           ) {
            return applicationURL.deletingPathExtension().lastPathComponent
        }

        return bundleIdentifier.isEmpty ? "Процесс \(processID)" : bundleIdentifier
    }

    private static func scalar<Value>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: Value
    ) throws -> Value {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var byteCount = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        try check(status, operation: "прочитать свойства аудиопроцесса")
        return value
    }

    private static func retainedString(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<CFString?>.size)
        try check(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &byteCount,
                &value
            ),
            operation: "прочитать bundle ID аудиопроцесса"
        )
        return value?.takeRetainedValue() as String? ?? ""
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.captureConfigurationFailed(
                "Не удалось \(operation) (Core Audio \(status))."
            )
        }
    }
}

private extension Sequence {
    func uniqued<ID: Hashable>(by keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen: Set<ID> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
