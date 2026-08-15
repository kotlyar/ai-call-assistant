import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .setup
    @Published var incomingSource = "Системный звук Mac"
    @Published var outgoingSource = "Микрофон MacBook"
    @Published var contexts: [CallContext]
    @Published var recordings: [Recording]
    @Published var selectedRecordingID: UUID?
    @Published var editingContext: CallContext?
    @Published var isContextEditorPresented = false
    @Published var playingRecordingID: UUID?
    @Published var toastMessage: String?

    @Published private(set) var callState: CallEngineState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var currentMoment: AssistantMoment?
    @Published private(set) var answerHistory: [AnswerHistoryItem] = []

    let incomingSources = [
        "Системный звук Mac",
        "Google Meet",
        "Zoom",
        "Microsoft Teams"
    ]
    let outgoingSources = [
        "Микрофон MacBook",
        "AirPods",
        "Внешний микрофон"
    ]

    let storagePath = "Documents / AI Call Assistant"

    private let engine: CallEngine
    private let transcriptService: TranscriptFileService
    private var toastTask: Task<Void, Never>?

    init(
        engine: CallEngine = DemoCallEngine(),
        transcriptService: TranscriptFileService = TranscriptFileService(),
        contexts: [CallContext]? = nil,
        recordings: [Recording]? = nil
    ) {
        self.engine = engine
        self.transcriptService = transcriptService
        self.contexts = contexts ?? Self.sampleContexts
        self.recordings = recordings ?? Self.sampleRecordings
        selectedRecordingID = self.recordings.first?.id

        engine.onChange = { [weak self] in
            self?.synchronizeEngineState()
        }
        synchronizeEngineState()
    }

    func setScreen(_ newScreen: AppScreen) {
        screen = newScreen
    }

    func toggleContext(_ context: CallContext) {
        guard let index = contexts.firstIndex(where: { $0.id == context.id }) else { return }
        contexts[index].isSelected.toggle()
    }

    func selectAllContexts() {
        for index in contexts.indices {
            contexts[index].isSelected = true
        }
    }

    func clearContextSelection() {
        for index in contexts.indices {
            contexts[index].isSelected = false
        }
    }

    func createContext() {
        editingContext = nil
        isContextEditorPresented = true
    }

    func openContext(_ context: CallContext) {
        editingContext = context
        isContextEditorPresented = true
    }

    func saveContext(title: String, body: String) {
        if let editingContext,
           let index = contexts.firstIndex(where: { $0.id == editingContext.id }) {
            contexts[index].title = title
            contexts[index].body = body
            showToast("Контекст сохранён")
        } else {
            contexts.append(CallContext(title: title, body: body, isSelected: true))
            showToast("Контекст добавлен и выбран")
        }
        self.editingContext = nil
    }

    func deleteContext(_ context: CallContext) {
        contexts.removeAll { $0.id == context.id }
        showToast("Контекст удалён")
    }

    func startCall() {
        engine.start()
        synchronizeEngineState()
    }

    func finishCall() {
        let sessionDuration = elapsedTime
        let moments = answerHistory.reversed().map(\.moment) + [currentMoment].compactMap { $0 }
        engine.stop()
        synchronizeEngineState()

        let recording = makeRecording(duration: sessionDuration, moments: moments)
        recordings.insert(recording, at: 0)
        selectedRecordingID = recording.id
        screen = .recordings
        showToast("Запись звонка сохранена")
    }

    func togglePlayback(for recording: Recording) {
        playingRecordingID = playingRecordingID == recording.id ? nil : recording.id
        showToast(playingRecordingID == nil ? "Воспроизведение остановлено" : "Демо-воспроизведение")
    }

    func download(_ recording: Recording, export: RecordingAudioExport) {
        showToast("Экспорт \(export.filename) будет доступен после подключения аудиобэкенда")
    }

    func openTranscript(for recording: Recording) {
        do {
            let url = try transcriptService.createTranscriptFile(for: recording)
            transcriptService.open(url)
        } catch {
            showToast("Не удалось создать transcript.txt")
        }
    }

    func revealTranscript(for recording: Recording) {
        do {
            let url = try transcriptService.createTranscriptFile(for: recording)
            transcriptService.revealInFinder(url)
        } catch {
            showToast("Не удалось показать transcript.txt в Finder")
        }
    }

    private func synchronizeEngineState() {
        callState = engine.state
        elapsedTime = engine.elapsedTime
        currentMoment = engine.currentMoment
        answerHistory = engine.answerHistory
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    private func makeRecording(duration: TimeInterval, moments: [AssistantMoment]) -> Recording {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"

        var turns: [TranscriptTurn] = []
        for (index, moment) in moments.enumerated() {
            let timestamp = TimeInterval(index * 14)
            turns.append(TranscriptTurn(speaker: .participant, timestamp: timestamp, text: moment.heardText))
            turns.append(TranscriptTurn(speaker: .you, timestamp: timestamp + 3, text: moment.answer))
        }

        let titleFormatter = DateFormatter()
        titleFormatter.locale = Locale(identifier: "ru_RU")
        titleFormatter.dateFormat = "d MMMM, HH:mm"

        return Recording(
            title: "Звонок \(titleFormatter.string(from: now))",
            startedAt: now,
            duration: max(duration, 1),
            folderName: formatter.string(from: now),
            turns: turns
        )
    }
}

extension AppModel {
    static let sampleContexts: [CallContext] = [
        CallContext(
            title: "Роль и цель",
            body: "Роль Head of Product. Цель звонка — понять зону ответственности, команду и критерии успеха на первые 90 дней.",
            isSelected: true
        ),
        CallContext(
            title: "Мой опыт",
            body: "8 лет в продуктах, B2B SaaS и AI. Запускал новые направления, строил кросс-функциональные команды и систему discovery.",
            isSelected: true
        ),
        CallContext(
            title: "Вопросы для звонка",
            body: "Какой результат ждут через 3 месяца? Где сейчас главное узкое место? Как принимаются продуктовые решения?",
            isSelected: false
        )
    ]

    static let sampleRecordings: [Recording] = {
        let now = Date()
        let first = Recording(
            title: "Интервью с продуктовой командой",
            startedAt: Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now,
            duration: 32 * 60 + 18,
            folderName: "2026-08-14_product-interview",
            turns: [
                TranscriptTurn(speaker: .participant, timestamp: 12, text: "Расскажите о своём последнем продуктовом проекте."),
                TranscriptTurn(speaker: .you, timestamp: 18, text: "Мы пересобрали discovery-процесс и сократили цикл проверки гипотез с трёх недель до одной.")
            ]
        )
        let second = Recording(
            title: "Звонок с партнёром",
            startedAt: Calendar.current.date(byAdding: .day, value: -4, to: now) ?? now,
            duration: 18 * 60 + 42,
            folderName: "2026-08-11_partner-call",
            turns: [
                TranscriptTurn(speaker: .participant, timestamp: 8, text: "Как вы видите первый этап сотрудничества?"),
                TranscriptTurn(speaker: .you, timestamp: 13, text: "Предлагаю начать с одного сценария и заранее согласовать метрику успеха.")
            ]
        )
        return [first, second]
    }()
}
