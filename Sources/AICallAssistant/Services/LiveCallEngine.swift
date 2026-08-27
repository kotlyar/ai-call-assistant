import Foundation

/// Production call clock/lifecycle without fabricated transcript or advice.
/// The richer coordinators own STT and LLM state; this small engine remains the
/// compatibility boundary used by the existing window/termination flow.
@MainActor
final class LiveCallEngine: CallEngine {
    var onChange: (() -> Void)?
    private(set) var state: CallEngineState = .idle
    private(set) var elapsedTime: TimeInterval = 0
    let currentMoment: AssistantMoment? = nil
    let answerHistory: [AnswerHistoryItem] = []

    private var startedAt: Date?
    private var timer: Timer?

    func start() {
        guard state != .running else { return }
        state = .running
        elapsedTime = 0
        startedAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedTime = Date().timeIntervalSince(startedAt)
                self.onChange?()
            }
        }
        onChange?()
    }

    func stop() {
        guard state == .running else { return }
        if let startedAt {
            elapsedTime = Date().timeIntervalSince(startedAt)
        }
        timer?.invalidate()
        timer = nil
        startedAt = nil
        state = .stopped
        onChange?()
    }

    func advance() {}
}
