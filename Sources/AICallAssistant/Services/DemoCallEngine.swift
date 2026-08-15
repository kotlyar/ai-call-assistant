import Combine
import Foundation

final class DemoCallEngine: ObservableObject, CallEngine {
    static let defaultScript: [AssistantMoment] = [
        AssistantMoment(
            question: "Как вы решаете конфликт между срочным запросом клиента и продуктовой стратегией?",
            answer: "Я быстро проверяю масштаб риска и выбираю обратимый шаг. В Aurora мы удержали клиента, не останавливая основной roadmap.",
            advice: "Покажите критерии решения: влияние на клиента, стратегию и стоимость переключения команды.",
            heardText: "«…между срочным запросом клиента и продуктовой стратегией?»"
        ),
        AssistantMoment(
            question: "Как вы поняли, что это решение сработало?",
            answer: "Мы сохранили клиента и выполнили план релиза. Time-to-value после изменений сократился на 22%, а команда не потеряла фокус.",
            advice: "Сначала назовите бизнес-результат, затем одну продуктовую метрику и вывод для следующих решений.",
            heardText: "«…как вы измерили результат и поняли, что решение сработало?»"
        ),
        AssistantMoment(
            question: "Что бы вы сделали иначе сейчас?",
            answer: "Я бы раньше зафиксировал критерии исключений для ключевых клиентов, чтобы похожие решения принимались быстрее.",
            advice: "Не оправдывайтесь. Покажите, чему научились и какое системное изменение сделали после ситуации.",
            heardText: "«…если бы вернулись назад, что сделали бы иначе?»"
        )
    ]

    @Published private(set) var state: CallEngineState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var currentMoment: AssistantMoment?
    @Published private(set) var answerHistory: [AnswerHistoryItem] = []
    var onChange: (() -> Void)?

    let moments: [AssistantMoment]
    let updateInterval: TimeInterval
    let maximumHistoryCount: Int
    let automaticUpdatesEnabled: Bool

    private var currentIndex = 0
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var momentTimer: Timer?

    init(
        moments: [AssistantMoment]? = nil,
        updateInterval: TimeInterval = 4.6,
        maximumHistoryCount: Int = 8,
        automaticUpdatesEnabled: Bool = true
    ) {
        self.moments = moments ?? Self.defaultScript
        self.updateInterval = max(0.1, updateInterval)
        self.maximumHistoryCount = max(1, maximumHistoryCount)
        self.automaticUpdatesEnabled = automaticUpdatesEnabled
    }

    var isRunning: Bool { state == .running }
    var formattedElapsedTime: String { elapsedTime.callTimecode }

    func start() {
        guard state != .running else { return }
        invalidateTimers()
        state = .running
        elapsedTime = 0
        answerHistory = []
        currentIndex = 0
        currentMoment = moments.first
        startedAt = Date()
        onChange?()

        guard automaticUpdatesEnabled else { return }
        installTimers()
    }

    func stop() {
        guard state == .running else { return }
        refreshElapsedTime()
        invalidateTimers()
        state = .stopped
        onChange?()
    }

    /// Advances immediately and is also used by tests, so tests never wait for a real timer.
    func advance() {
        guard state == .running, !moments.isEmpty else { return }

        if let currentMoment {
            answerHistory.insert(
                AnswerHistoryItem(moment: currentMoment, elapsedTime: elapsedTime),
                at: 0
            )
            if answerHistory.count > maximumHistoryCount {
                answerHistory.removeLast(answerHistory.count - maximumHistoryCount)
            }
        }

        currentIndex = (currentIndex + 1) % moments.count
        currentMoment = moments[currentIndex]
        onChange?()
    }

    private func installTimers() {
        let elapsedTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshElapsedTime()
                self?.onChange?()
            }
        }
        let momentTimer = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshElapsedTime()
                self?.advance()
            }
        }

        RunLoop.main.add(elapsedTimer, forMode: .common)
        RunLoop.main.add(momentTimer, forMode: .common)
        self.elapsedTimer = elapsedTimer
        self.momentTimer = momentTimer
    }

    private func refreshElapsedTime() {
        guard state == .running, let startedAt else { return }
        elapsedTime = max(0, Date().timeIntervalSince(startedAt))
    }

    private func invalidateTimers() {
        elapsedTimer?.invalidate()
        momentTimer?.invalidate()
        elapsedTimer = nil
        momentTimer = nil
    }

    deinit {
        elapsedTimer?.invalidate()
        momentTimer?.invalidate()
    }
}
