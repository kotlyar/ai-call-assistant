import Foundation

struct RealtimeTranscriptionConfiguration: Equatable, Sendable {
    var modelID: String
    var languages: [String]
    var delay: String
    var prompt: String?
    var keywords: [String]

    init(
        modelID: String = "gpt-live-transcribe",
        languages: [String] = ["ru", "en"],
        delay: String = "low",
        prompt: String? = nil,
        keywords: [String] = []
    ) {
        self.modelID = modelID
        self.languages = languages
        self.delay = delay
        self.prompt = prompt
        self.keywords = keywords
    }
}

enum RealtimeClientEvent: Encodable, Equatable, Sendable {
    case updateSession(RealtimeTranscriptionConfiguration)
    case appendAudio(Data)
    case commit(eventID: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case audio
        case eventID = "event_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .updateSession(configuration):
            try container.encode("session.update", forKey: .type)
            try container.encode(SessionPayload(configuration: configuration), forKey: .session)

        case let .appendAudio(data):
            try container.encode("input_audio_buffer.append", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .audio)

        case let .commit(eventID):
            try container.encode("input_audio_buffer.commit", forKey: .type)
            try container.encode(eventID, forKey: .eventID)
        }
    }
}

private struct SessionPayload: Encodable {
    let type = "transcription"
    let audio: AudioPayload

    init(configuration: RealtimeTranscriptionConfiguration) {
        audio = AudioPayload(input: InputPayload(configuration: configuration))
    }
}

private struct AudioPayload: Encodable {
    let input: InputPayload
}

private struct InputPayload: Encodable {
    struct PCMFormat: Encodable {
        let type = "audio/pcm"
        let rate = 24_000
    }

    struct Transcription: Encodable {
        let model: String
        let languages: [String]
        let delay: String
        let prompt: String?
        let keywords: [String]?
    }

    let format = PCMFormat()
    let transcription: Transcription
    let turnDetection: String? = nil

    private enum CodingKeys: String, CodingKey {
        case format
        case transcription
        case turnDetection = "turn_detection"
    }

    init(configuration: RealtimeTranscriptionConfiguration) {
        transcription = Transcription(
            model: configuration.modelID,
            languages: configuration.languages,
            delay: configuration.delay,
            prompt: configuration.prompt,
            keywords: configuration.keywords.isEmpty ? nil : configuration.keywords
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(transcription, forKey: .transcription)
        try container.encodeNil(forKey: .turnDetection)
    }
}

struct RealtimeProviderError: Error, Equatable, Sendable {
    let type: String?
    let code: String?
}

enum RealtimeServerEvent: Equatable, Sendable {
    case sessionUpdated(expiresAt: Int64?)
    case audioCommitted(itemID: String)
    case transcriptDelta(itemID: String, contentIndex: Int, delta: String)
    case transcriptCompleted(itemID: String, contentIndex: Int, transcript: String)
    case providerError(RealtimeProviderError)
    case ignored(type: String)
}

extension RealtimeServerEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case itemID = "item_id"
        case contentIndex = "content_index"
        case delta
        case transcript
        case error
    }

    private struct Session: Decodable {
        let expiresAt: Int64?

        private enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
        }
    }

    private struct ProviderErrorPayload: Decodable {
        let type: String?
        let code: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "session.updated":
            let session = try container.decodeIfPresent(Session.self, forKey: .session)
            self = .sessionUpdated(expiresAt: session?.expiresAt)

        case "input_audio_buffer.committed":
            self = .audioCommitted(itemID: try container.decode(String.self, forKey: .itemID))

        case "conversation.item.input_audio_transcription.delta":
            self = .transcriptDelta(
                itemID: try container.decode(String.self, forKey: .itemID),
                contentIndex: try container.decodeIfPresent(Int.self, forKey: .contentIndex) ?? 0,
                delta: try container.decode(String.self, forKey: .delta)
            )

        case "conversation.item.input_audio_transcription.completed":
            self = .transcriptCompleted(
                itemID: try container.decode(String.self, forKey: .itemID),
                contentIndex: try container.decodeIfPresent(Int.self, forKey: .contentIndex) ?? 0,
                transcript: try container.decode(String.self, forKey: .transcript)
            )

        case "error":
            let error = try container.decode(ProviderErrorPayload.self, forKey: .error)
            self = .providerError(
                RealtimeProviderError(type: error.type, code: error.code)
            )

        default:
            self = .ignored(type: type)
        }
    }
}
