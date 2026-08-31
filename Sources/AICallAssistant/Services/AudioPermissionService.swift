import AppKit
import AVFoundation
import Foundation

enum AudioPermissionKind: Equatable, Sendable {
    case microphone
    case systemAudio
}

enum AudioPermissionStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

struct AudioPermissionSnapshot: Equatable, Sendable {
    let microphone: AudioPermissionStatus
    let systemAudio: AudioPermissionStatus

    var allGranted: Bool {
        microphone == .authorized && systemAudio == .authorized
    }
}

@MainActor
protocol AudioPermissionService {
    func currentSnapshot() -> AudioPermissionSnapshot
    func request(_ kind: AudioPermissionKind) async -> AudioPermissionStatus
    func openSettings(for kind: AudioPermissionKind)
}

@MainActor
final class SystemAudioPermissionService: AudioPermissionService {
    typealias SystemAudioAccessProbe = @MainActor () async -> AudioPermissionStatus
    typealias SettingsURLOpener = @MainActor (URL) -> Void

    private let performSystemAudioProbe: SystemAudioAccessProbe
    private let settingsURLOpener: SettingsURLOpener
    private var lastSystemAudioRequestStatus: AudioPermissionStatus?

    init(
        systemAudioAccessProbe: @escaping SystemAudioAccessProbe = {
            await SystemAudioPermissionService.probeCoreAudioAccess()
        },
        settingsURLOpener: @escaping SettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        performSystemAudioProbe = systemAudioAccessProbe
        self.settingsURLOpener = settingsURLOpener
    }

    func currentSnapshot() -> AudioPermissionSnapshot {
        AudioPermissionSnapshot(
            microphone: microphoneStatus,
            systemAudio: systemAudioStatus
        )
    }

    func request(_ kind: AudioPermissionKind) async -> AudioPermissionStatus {
        switch kind {
        case .microphone:
            return await requestMicrophoneAccess()
        case .systemAudio:
            return await requestSystemAudioAccess()
        }
    }

    func openSettings(for kind: AudioPermissionKind) {
        let anchor: String
        switch kind {
        case .microphone:
            anchor = "Privacy_Microphone"
        case .systemAudio:
            anchor = "Privacy_AudioCapture"
        }

        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        settingsURLOpener(url)
    }

    private var microphoneStatus: AudioPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    private var systemAudioStatus: AudioPermissionStatus {
        // Core Audio has no public preflight API for process taps. Keep the
        // result only for this process and probe again after the next launch,
        // so a change in System Settings can never become permanently stale.
        return lastSystemAudioRequestStatus ?? .notDetermined
    }

    private func requestMicrophoneAccess() async -> AudioPermissionStatus {
        switch microphoneStatus {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .authorized : .denied
        }
    }

    private func requestSystemAudioAccess() async -> AudioPermissionStatus {
        let status = await performSystemAudioProbe()
        if status != .notDetermined {
            lastSystemAudioRequestStatus = status
        }
        return status
    }

    private static func probeCoreAudioAccess() async -> AudioPermissionStatus {
        switch await CoreAudioProcessTap.probePermission() {
        case .available:
            return .authorized
        case .denied:
            return .denied
        case .unsupported, .failed:
            // Unsupported or transient HAL failures are not evidence that the
            // user denied access. Keep the state retryable.
            return .notDetermined
        }
    }
}
