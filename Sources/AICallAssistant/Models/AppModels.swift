import Foundation

enum AppScreen: String, CaseIterable, Codable {
    case setup
    case contexts
    case recordings
    case settings
}

struct ContextFileAttachment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var fileName: String
    var mediaType: String
    var byteCount: Int
    var contentSHA256: String
    var extractedText: String

    init(
        id: UUID = UUID(),
        fileName: String,
        mediaType: String,
        byteCount: Int,
        contentSHA256: String,
        extractedText: String
    ) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
        self.extractedText = extractedText
    }
}

struct CallContext: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var isSelected: Bool
    var attachments: [ContextFileAttachment]

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        isSelected: Bool = false,
        attachments: [ContextFileAttachment] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.isSelected = isSelected
        self.attachments = attachments
    }

    var assistantContextBody: String {
        guard !attachments.isEmpty else { return body }

        let attachmentSections = attachments.map { attachment in
            let fileName = Self.sanitizedFileName(attachment.fileName)
            return """
            <<< BEGIN CONTEXT FILE: \(fileName) >>>
            \(attachment.extractedText)
            <<< END CONTEXT FILE: \(fileName) >>>
            """
        }
        let visibleSections = body.isEmpty ? [] : [body]
        return (visibleSections + attachmentSections).joined(separator: "\n\n")
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case isSelected
        case attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        isSelected = try container.decode(Bool.self, forKey: .isSelected)
        attachments = try container.decodeIfPresent(
            [ContextFileAttachment].self,
            forKey: .attachments
        ) ?? []
    }

    private static func sanitizedFileName(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

struct TranscriptTurn: Identifiable, Codable, Equatable, Sendable {
    enum Speaker: String, Codable, Sendable {
        case you = "Вы"
        case participant = "Собеседник"
    }

    var id: UUID
    var speaker: Speaker
    var timestamp: TimeInterval
    var text: String

    init(id: UUID = UUID(), speaker: Speaker, timestamp: TimeInterval, text: String) {
        self.id = id
        self.speaker = speaker
        self.timestamp = timestamp
        self.text = text
    }
}

struct RecordingTranscriptionMetadata: Codable, Equatable, Sendable {
    var callState: PersistedCallState
    var liveStatus: LiveTranscriptionStatus
    var reconciliationStatus: ReconciliationStatus
    var finalAnalysisStatus: FinalAnalysisStatus
    var incomingRealtimeStatus: RealtimeTrackStatus?
    var outgoingRealtimeStatus: RealtimeTrackStatus?
    var incomingRealtimeFailure: RealtimeFailureDiagnostic? = nil
    var outgoingRealtimeFailure: RealtimeFailureDiagnostic? = nil
    var liveRevision: Int64
    var canonicalRevision: Int64?
    var canonicalTranscriptFilename: String? = nil
    var canonicalTranscriptSHA256: String? = nil
    var reconciliationJobID: String? = nil
    var reconciliationAttempts: Int? = nil
    var reconciliationUpdatedAt: Date? = nil
    var finalAnalysisJobID: String? = nil
    var finalAnalysisAttempts: Int? = nil
    var finalAnalysisUpdatedAt: Date? = nil
    var finalAnalysisResultPointer: FinalAnalysisResultPointer? = nil
    var liveJournalSealedAt: Date?
    var provider: String
    var realtimeModelID: String
    var fileTranscriptionModelID: String
    var responsesModelID: String
    var frozenContexts: FrozenContextSnapshot
    var frozenConfiguration: GuidanceConfigurationSnapshot
    var lastErrorCode: String?
    var incomingWriterDroppedBuffers: Int? = nil
    var outgoingWriterDroppedBuffers: Int? = nil
    var incomingLiveAudioMetrics: LiveAudioTrackMetrics? = nil
    var outgoingLiveAudioMetrics: LiveAudioTrackMetrics? = nil
}

struct Recording: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var folderName: String
    var turns: [TranscriptTurn]
    var transcription: RecordingTranscriptionMetadata?

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        folderName: String,
        turns: [TranscriptTurn],
        transcription: RecordingTranscriptionMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.folderName = folderName
        self.turns = turns
        self.transcription = transcription
    }
}

struct AssistantMoment: Identifiable, Equatable {
    var id: UUID
    var question: String
    var answer: String
    var advice: String
    var heardText: String
    var heardTextHighlightRange: Range<Int>?
    var isLate: Bool

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        advice: String,
        heardText: String,
        heardTextHighlightRange: Range<Int>? = nil,
        isLate: Bool = false
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.advice = advice
        self.heardText = heardText
        self.heardTextHighlightRange = heardTextHighlightRange
        self.isLate = isLate
    }

    init(
        id: UUID = UUID(),
        guidancePair pair: QuestionAnswerPair,
        transcriptTurns: [LiveTranscriptTurn]
    ) {
        let presentation = Self.evidencePresentation(
            for: pair,
            transcriptTurns: transcriptTurns
        )
        self.init(
            id: id,
            question: pair.normalizedQuestion,
            answer: pair.answer,
            advice: pair.advice,
            heardText: presentation.text,
            heardTextHighlightRange: presentation.highlightRange,
            isLate: pair.isLate
        )
    }

    private static func evidencePresentation(
        for pair: QuestionAnswerPair,
        transcriptTurns: [LiveTranscriptTurn]
    ) -> (text: String, highlightRange: Range<Int>?) {
        let fallback = pair.evidence.map(\.exactQuote).joined(separator: " … ")
        guard pair.evidence.count == 1,
              let evidence = pair.evidence.first,
              let range = evidence.unicodeScalarRange else {
            return (fallback, nil)
        }

        if let turn = transcriptTurns.first(where: { $0.reference == evidence.turn }),
           range.lowerBound >= 0,
           range.lowerBound < range.upperBound,
           range.upperBound <= turn.text.unicodeScalars.count {
            return (turn.text, range)
        }

        guard !evidence.exactQuote.isEmpty else { return (fallback, nil) }
        return (
            evidence.exactQuote,
            0..<evidence.exactQuote.unicodeScalars.count
        )
    }
}

struct AnswerHistoryItem: Identifiable, Equatable {
    var id: UUID
    var moment: AssistantMoment
    var elapsedTime: TimeInterval

    init(id: UUID = UUID(), moment: AssistantMoment, elapsedTime: TimeInterval) {
        self.id = id
        self.moment = moment
        self.elapsedTime = elapsedTime
    }

    var timecode: String {
        elapsedTime.callTimecode
    }
}

extension TimeInterval {
    var callTimecode: String {
        let seconds = max(0, Int(self.rounded(.down)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
