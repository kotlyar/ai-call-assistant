import AppKit
import AVFoundation
import CoreGraphics
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
    private let preflightSystemAudioAccess: () -> Bool
    private let performSystemAudioRequest: () -> Bool
    private var lastSystemAudioRequestStatus: AudioPermissionStatus?

    init(
        preflightSystemAudioAccess: @escaping () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        requestSystemAudioAccess: @escaping () -> Bool = {
            CGRequestScreenCaptureAccess()
        }
    ) {
        self.preflightSystemAudioAccess = preflightSystemAudioAccess
        performSystemAudioRequest = requestSystemAudioAccess
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
            return requestSystemAudioAccess()
        }
    }

    func openSettings(for kind: AudioPermissionKind) {
        let anchor: String
        switch kind {
        case .microphone:
            anchor = "Privacy_Microphone"
        case .systemAudio:
            anchor = "Privacy_ScreenCapture"
        }

        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
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
        if preflightSystemAudioAccess() {
            lastSystemAudioRequestStatus = .authorized
            return .authorized
        }

        // CoreGraphics has no public denied/not-determined status. Persisting
        // our own answer becomes stale when a development build's signing
        // identity changes and can make the permission impossible to retry.
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

    private func requestSystemAudioAccess() -> AudioPermissionStatus {
        if preflightSystemAudioAccess() {
            lastSystemAudioRequestStatus = .authorized
            return .authorized
        }

        let status: AudioPermissionStatus = performSystemAudioRequest()
            ? .authorized
            : .denied
        lastSystemAudioRequestStatus = status
        return status
    }
}
