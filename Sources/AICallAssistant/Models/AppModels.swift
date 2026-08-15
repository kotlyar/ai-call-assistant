import Foundation

enum AppScreen: String, CaseIterable, Codable {
    case setup
    case recordings
}

struct CallContext: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var isSelected: Bool

    init(id: UUID = UUID(), title: String, body: String, isSelected: Bool = false) {
        self.id = id
        self.title = title
        self.body = body
        self.isSelected = isSelected
    }
}

struct TranscriptTurn: Identifiable, Codable, Equatable {
    enum Speaker: String, Codable {
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

struct Recording: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var startedAt: Date
    var duration: TimeInterval
    var folderName: String
    var turns: [TranscriptTurn]

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        folderName: String,
        turns: [TranscriptTurn]
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.folderName = folderName
        self.turns = turns
    }
}

struct AssistantMoment: Identifiable, Equatable {
    var id: UUID
    var question: String
    var answer: String
    var advice: String
    var heardText: String

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        advice: String,
        heardText: String
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.advice = advice
        self.heardText = heardText
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
