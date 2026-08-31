import Foundation

struct AudioSourceOption: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case systemAudio
        case application(bundleIdentifier: String, processID: Int32)
        case microphone(uniqueID: String)
    }

    let id: String
    let title: String
    let kind: Kind

    static let systemAudio = AudioSourceOption(
        id: "system-audio",
        title: "Весь системный звук",
        kind: .systemAudio
    )
}

struct AudioSourceCatalog: Equatable {
    let incoming: [AudioSourceOption]
    let microphones: [AudioSourceOption]
}

struct AudioCaptureRequest: Equatable {
    let folderURL: URL
    let incomingSource: AudioSourceOption
    let microphone: AudioSourceOption
}

struct CapturedAudioFiles: Equatable {
    let incomingFilename: String?
    let outgoingFilename: String?
    let combinedFilename: String?
    var warnings: [AudioCaptureWarning] = []
    var quality = AudioCaptureQuality()

    var hasAudio: Bool {
        incomingFilename != nil || outgoingFilename != nil || combinedFilename != nil
    }
}

struct AudioCaptureQuality: Equatable, Sendable {
    var incomingWriterDroppedBuffers = 0
    var outgoingWriterDroppedBuffers = 0

    var hasKnownGaps: Bool {
        incomingWriterDroppedBuffers > 0 || outgoingWriterDroppedBuffers > 0
    }
}

enum AudioCaptureWarning: Equatable {
    case incoming(String)
    case outgoing(String)
    case combined(String)

    var localizedDescription: String {
        switch self {
        case let .incoming(message):
            return "системный звук: \(message)"
        case let .outgoing(message):
            return "микрофон: \(message)"
        case let .combined(message):
            return "общий файл: \(message)"
        }
    }
}

@MainActor
protocol AudioCaptureService: AnyObject {
    func discoverSources() async throws -> AudioSourceCatalog
    func start(_ request: AudioCaptureRequest, liveAudioSink: LiveAudioSampleSink?) async throws
    func stop() async throws -> CapturedAudioFiles
}

extension AudioCaptureService {
    func start(_ request: AudioCaptureRequest) async throws {
        try await start(request, liveAudioSink: nil)
    }
}

enum AudioCaptureError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case microphoneUnavailable(String)
    case systemAudioUnavailable
    case sourceApplicationUnavailable(String)
    case captureConfigurationFailed(String)
    case captureStopped(String)
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Запись уже идёт."
        case .notRecording:
            return "Активная запись не найдена."
        case .microphonePermissionDenied:
            return "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон."
        case let .microphoneUnavailable(name):
            return "Микрофон «\(name)» недоступен. Подключите его или выберите другой источник."
        case .systemAudioUnavailable:
            return "Не удалось получить системный звук. Разрешите запись системного аудио в настройках macOS."
        case let .sourceApplicationUnavailable(name):
            return "Источник «\(name)» не найден. Откройте приложение или окно звонка и попробуйте снова."
        case let .captureConfigurationFailed(message):
            return "Не удалось настроить запись: \(message)"
        case let .captureStopped(message):
            return "Захват звука был остановлен: \(message)"
        case .noAudioCaptured:
            return "Во время звонка не удалось получить аудиоданные."
        }
    }
}
