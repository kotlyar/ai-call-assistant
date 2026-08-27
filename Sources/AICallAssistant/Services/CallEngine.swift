import Foundation

enum CallEngineState: String, Codable, Equatable {
    case idle
    case running
    case stopped
}

@MainActor
protocol CallEngine: AnyObject {
    var state: CallEngineState { get }
    var elapsedTime: TimeInterval { get }
    var currentMoment: AssistantMoment? { get }
    var answerHistory: [AnswerHistoryItem] { get }
    var onChange: (() -> Void)? { get set }

    func start()
    func stop()
    func advance()
}
