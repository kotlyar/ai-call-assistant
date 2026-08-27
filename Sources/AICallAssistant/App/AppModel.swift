import AppKit
@preconcurrency import AVFoundation
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .setup
    @Published var incomingSource: AudioSourceOption
    @Published var outgoingSource: AudioSourceOption
    @Published private(set) var contexts: [CallContext]
    @Published var recordings: [Recording]
    @Published var selectedRecordingID: UUID?
    @Published var editingContext: CallContext?
    @Published var isContextEditorPresented = false
    @Published var isAudioPermissionsPresented: Bool
    @Published var playingRecordingID: UUID?
    @Published var toastMessage: String?
    @Published private(set) var incomingSources: [AudioSourceOption]
    @Published private(set) var outgoingSources: [AudioSourceOption]
    @Published private(set) var isDiscoveringAudioSources = false
    @Published private(set) var isPreparingAudio = false
    @Published private(set) var isFinalizingAudio = false
    @Published private(set) var audioSetupError: String?
    @Published private(set) var playbackElapsedTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    @Published private(set) var playbackProgress: Double = 0
    @Published private(set) var audioPermissions: AudioPermissionSnapshot
    @Published private(set) var requestingAudioPermission: AudioPermissionKind?

    @Published private(set) var callState: CallEngineState = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var currentMoment: AssistantMoment?
    @Published private(set) var answerHistory: [AnswerHistoryItem] = []
    @Published private(set) var liveTranscriptTurns: [LiveTranscriptTurn] = []
    @Published private(set) var guidanceCards: [QuestionAnswerPair] = []
    @Published private(set) var incomingRealtimeStatus: RealtimeTrackStatus = .connecting
    @Published private(set) var outgoingRealtimeStatus: RealtimeTrackStatus = .connecting
    @Published private(set) var incomingRealtimeFailure: RealtimeFailureDiagnostic?
    @Published private(set) var outgoingRealtimeFailure: RealtimeFailureDiagnostic?
    @Published private(set) var liveGuidanceStatus: LiveGuidanceStatus = .inactive

    let storagePath: String

    private let engine: CallEngine
    private let transcriptService: TranscriptFileService
    private let audioCaptureService: AudioCaptureService
    private let audioPlaybackService: AudioPlaybackService
    private let audioPermissionService: AudioPermissionService
    private let recordingStorage: RecordingStorageService
    private let contextLibraryStore: ContextLibraryStore
    private let contextLibraryWriter: ContextLibraryWriter
    private let contextFileTextExtractor: any ContextFileTextExtracting
    private let realtimeCoordinatorFactory: @Sendable (
        (any LiveAudioSpendAuthorizer)?
    ) -> RealtimeTranscriptionCoordinator
    private let fileTranscriptionProviderFactory: @Sendable () -> any FileTranscriptionProvider
    private let reconciliationCredentialProviderFactory: @Sendable () -> any ReconciliationCredentialProvider
    private let finalAnalysisProviderFactory: @Sendable () -> any FinalAnalysisProvider
    private let finalAnalysisCredentialProviderFactory: @Sendable () -> any FinalAnalysisCredentialProvider
    private let userDefaults: UserDefaults
    let openAISettings: OpenAISettingsStore
    private var activeCallStartedAt: Date?
    private var activeCallFolderName: String?
    private var activeCallID: UUID?
    private var activeConfiguration: GuidanceConfigurationSnapshot?
    private var activeContextStore: ConversationContextStore?
    private var activeLiveTranscriptJournal: LiveTranscriptJournal?
    private var realtimeCoordinator: RealtimeTranscriptionCoordinator?
    private var realtimeStartTask: Task<Void, Never>?
    private var liveAudioSink: DualTrackLiveAudioPCMStream?
    private var liveGuidanceCoordinator: LiveGuidanceCoordinator?
    private var activeSpendLedger: CallSpendLedger?
    private var realtimeEventTask: Task<Void, Never>?
    private var guidancePublicationTask: Task<Void, Never>?
    private var guidanceDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var enqueuedGuidanceTriggers: Set<TurnReference> = []
    private var toastTask: Task<Void, Never>?
    private var contextPersistenceTask: Task<Void, Never>?
    private var contextPersistenceRevision: Int64 = 0
    private var contextsNeedPersistence = false
    private var contextLibraryNeedsRecoveryBackup = false
    private var reconciliationTasks: [UUID: Task<Void, Never>] = [:]
    private var finalAnalysisTasks: [UUID: Task<Void, Never>] = [:]
    private var settingsCredentialCancellable: AnyCancellable?
    private var audioDeviceObservers: [NSObjectProtocol] = []

    private static let audioOnboardingSeenKey = "com.aicallassistant.onboarding.audio-permissions-seen"

    init(
        engine: CallEngine? = nil,
        transcriptService: TranscriptFileService = TranscriptFileService(),
        audioCaptureService: AudioCaptureService? = nil,
        audioPlaybackService: AudioPlaybackService? = nil,
        audioPermissionService: AudioPermissionService? = nil,
        recordingStorage: RecordingStorageService = RecordingStorageService(),
        contextLibraryStore: ContextLibraryStore = ContextLibraryStore(),
        openAISettings: OpenAISettingsStore? = nil,
        contextFileTextExtractor: any ContextFileTextExtracting = OpenAIContextFileTextExtractor(),
        realtimeCoordinatorFactory: @escaping @Sendable (
            (any LiveAudioSpendAuthorizer)?
        ) -> RealtimeTranscriptionCoordinator = { spendAuthorizer in
            RealtimeTranscriptionCoordinator(spendAuthorizer: spendAuthorizer)
        },
        fileTranscriptionProviderFactory: @escaping @Sendable () -> any FileTranscriptionProvider = {
            OpenAIFileTranscriptionProvider()
        },
        reconciliationCredentialProviderFactory: @escaping @Sendable () -> any ReconciliationCredentialProvider = {
            SecretStoreReconciliationCredentialProvider()
        },
        finalAnalysisProviderFactory: @escaping @Sendable () -> any FinalAnalysisProvider = {
            OpenAIResponsesFinalAnalysisProvider(
                transport: URLSessionOpenAIFinalAnalysisTransport(),
                promptBuilder: FinalAnalysisPromptBuilder(
                    maximumInputUTF8Bytes: 2_500_000
                )
            )
        },
        finalAnalysisCredentialProviderFactory: @escaping @Sendable () -> any FinalAnalysisCredentialProvider = {
            SecretStoreReconciliationCredentialProvider()
        },
        userDefaults: UserDefaults = .standard,
        contexts: [CallContext]? = nil,
        recordings: [Recording]? = nil
    ) {
        let captureService = audioCaptureService ?? RealAudioCaptureService()
        let playbackService = audioPlaybackService ?? RealAudioPlaybackService()
        let permissionService = audioPermissionService
            ?? SystemAudioPermissionService()
        let microphonePlaceholder = AudioSourceOption(
            id: "microphone:unavailable",
            title: "Микрофон не найден",
            kind: .microphone(uniqueID: "")
        )

        self.engine = engine ?? LiveCallEngine()
        self.transcriptService = transcriptService
        self.audioCaptureService = captureService
        self.audioPlaybackService = playbackService
        self.audioPermissionService = permissionService
        self.recordingStorage = recordingStorage
        self.contextLibraryStore = contextLibraryStore
        contextLibraryWriter = ContextLibraryWriter(store: contextLibraryStore)
        self.contextFileTextExtractor = contextFileTextExtractor
        self.realtimeCoordinatorFactory = realtimeCoordinatorFactory
        self.fileTranscriptionProviderFactory = fileTranscriptionProviderFactory
        self.reconciliationCredentialProviderFactory = reconciliationCredentialProviderFactory
        self.finalAnalysisProviderFactory = finalAnalysisProviderFactory
        self.finalAnalysisCredentialProviderFactory = finalAnalysisCredentialProviderFactory
        self.userDefaults = userDefaults
        self.openAISettings = openAISettings
            ?? OpenAISettingsStore(userDefaults: userDefaults)
        audioPermissions = permissionService.currentSnapshot()
        requestingAudioPermission = nil
        isAudioPermissionsPresented = !userDefaults.bool(forKey: Self.audioOnboardingSeenKey)
        incomingSources = [.systemAudio]
        outgoingSources = []
        incomingSource = .systemAudio
        outgoingSource = microphonePlaceholder
        if let contexts {
            // Explicit fixtures/previews take precedence over disk state.
            self.contexts = contexts
            contextPersistenceRevision = 1
            contextsNeedPersistence = true
        } else {
            do {
                self.contexts = try contextLibraryStore.load()
            } catch {
                // Keep unreadable/future data intact. The first explicit edit
                // creates a recovery copy before replacing the live library.
                self.contexts = []
                contextLibraryNeedsRecoveryBackup = true
            }
        }
        self.recordings = recordings ?? ((try? recordingStorage.loadAll()) ?? [])
        storagePath = recordingStorage.rootURL.path
        selectedRecordingID = self.recordings.first?.id

        self.engine.onChange = { [weak self] in
            self?.synchronizeEngineState()
        }
        playbackService.onProgress = { [weak self] elapsed, duration in
            self?.playbackElapsedTime = elapsed
            self?.playbackDuration = duration
            self?.playbackProgress = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
        }
        playbackService.onFinish = { [weak self] in
            self?.playingRecordingID = nil
            self?.playbackElapsedTime = 0
            self?.playbackDuration = 0
            self?.playbackProgress = 0
        }
        synchronizeEngineState()

#if DEBUG
        let performsStartupMaintenance = !CommandLine.arguments.contains("--ui-snapshot")
#else
        let performsStartupMaintenance = true
#endif
        if performsStartupMaintenance {
            settingsCredentialCancellable = self.openAISettings.$credentialState
                .dropFirst()
                .filter { $0 == .available }
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.resumePendingPostCallProcessing(
                            includeCredentialBlocked: true
                        )
                    }
            }
        }
        let center = NotificationCenter.default
        audioDeviceObservers = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification
        ].map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.callState != .running else { return }
                    await self.refreshAudioSources()
                }
            }
        }
        if performsStartupMaintenance {
            Task { @MainActor [weak self] in
                try? await self?.openAISettings.refreshCredentialState()
                await self?.resumePendingPostCallProcessing(
                    includeCredentialBlocked: true
                )
            }
        }
    }

    func setScreen(_ newScreen: AppScreen) {
        if newScreen != .recordings {
            stopPlayback()
        }
        screen = newScreen
    }

    func toggleContext(_ context: CallContext) {
        guard let index = contexts.firstIndex(where: { $0.id == context.id }) else { return }
        contexts[index].isSelected.toggle()
        persistContextsInBackground()
    }

    func selectAllContexts() {
        for index in contexts.indices {
            contexts[index].isSelected = true
        }
        persistContextsInBackground()
    }

    func clearContextSelection() {
        for index in contexts.indices {
            contexts[index].isSelected = false
        }
        persistContextsInBackground()
    }

    func createContext() {
        editingContext = nil
        isContextEditorPresented = true
    }

    func openContext(_ context: CallContext) {
        editingContext = context
        isContextEditorPresented = true
    }

    func extractContextFile(at url: URL) async throws -> ContextFileAttachment {
        let apiKey: String
        do {
            guard let storedKey = try await openAISettings.loadAPIKey(),
                  !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContextFileTextExtractionError.missingAPIKey
            }
            apiKey = storedKey
        } catch is ContextFileTextExtractionError {
            throw ContextFileTextExtractionError.missingAPIKey
        } catch {
            throw ContextFileTextExtractionError.missingAPIKey
        }

        let modelID = openAISettings.configuration.responsesModelID
        let input = try await Task.detached(priority: .userInitiated) {
            try Self.loadContextFile(at: url)
        }.value
        let extractedText = try await contextFileTextExtractor.extractText(
            from: input,
            apiKey: apiKey,
            modelID: modelID
        )

        return ContextFileAttachment(
            fileName: Self.sanitizedContextFileName(input.fileName),
            mediaType: input.mediaType,
            byteCount: input.data.count,
            contentSHA256: Self.sha256Hex(input.data),
            extractedText: extractedText
        )
    }

    func saveContext(
        title: String,
        body: String,
        attachments: [ContextFileAttachment]
    ) {
        if let editingContext,
           let index = contexts.firstIndex(where: { $0.id == editingContext.id }) {
            contexts[index].title = title
            contexts[index].body = body
            contexts[index].attachments = attachments
            showToast("Контекст сохранён")
        } else {
            contexts.append(
                CallContext(
                    title: title,
                    body: body,
                    isSelected: true,
                    attachments: attachments
                )
            )
            showToast("Контекст добавлен и выбран")
        }
        self.editingContext = nil
        persistContextsInBackground()
    }

    func deleteContext(_ context: CallContext) {
        contexts.removeAll { $0.id == context.id }
        persistContextsInBackground()
        showToast("Контекст удалён")
    }

    func presentAudioPermissions() {
        refreshAudioPermissions()
        isAudioPermissionsPresented = true
    }

    func completeAudioPermissionsOnboarding() {
        userDefaults.set(true, forKey: Self.audioOnboardingSeenKey)
        isAudioPermissionsPresented = false
        if audioPermissions.allGranted {
            Task { await refreshAudioSources() }
        }
    }

    func refreshAudioPermissions() {
        audioPermissions = audioPermissionService.currentSnapshot()
    }

    func requestAudioPermission(_ kind: AudioPermissionKind) async {
        guard requestingAudioPermission == nil else { return }
        requestingAudioPermission = kind
        let requestedStatus = await audioPermissionService.request(kind)
        requestingAudioPermission = nil

        let refreshed = audioPermissionService.currentSnapshot()
        audioPermissions = AudioPermissionSnapshot(
            microphone: kind == .microphone ? requestedStatus : refreshed.microphone,
            systemAudio: kind == .systemAudio ? requestedStatus : refreshed.systemAudio
        )

        if kind == .systemAudio, requestedStatus == .denied {
            // On current macOS versions the first ScreenCapture request adds
            // the app to System Settings but does not show an Allow dialog.
            audioPermissionService.openSettings(for: .systemAudio)
        }

        if audioPermissions.allGranted {
            await refreshAudioSources()
        }
    }

    func openAudioPermissionSettings(_ kind: AudioPermissionKind) {
        audioPermissionService.openSettings(for: kind)
    }

    func applicationDidBecomeActive() {
        refreshAudioPermissions()
        if audioPermissions.allGranted, callState != .running {
            Task { await refreshAudioSources() }
        }
    }

    func prepareForTermination() async -> Bool {
        guard await persistContextsForTermination() else { return false }
        stopPlayback()

        var remainingChecks = 200
        while isPreparingAudio, remainingChecks > 0 {
            remainingChecks -= 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !isPreparingAudio else {
            showToast("Не удалось безопасно завершить подготовку аудио")
            return false
        }

        if callState == .running {
            await finishCall()
        }

        remainingChecks = 200
        while isFinalizingAudio, remainingChecks > 0 {
            remainingChecks -= 1
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !isFinalizingAudio else {
            showToast("Не удалось безопасно завершить сохранение аудио")
            return false
        }

        return await persistContextsForTermination()
    }

    func refreshAudioSources() async {
        guard !isDiscoveringAudioSources, callState != .running else { return }
        refreshAudioPermissions()
        guard audioPermissions.allGranted else {
            incomingSources = [.systemAudio]
            outgoingSources = []
            audioSetupError = "Разрешите доступ к микрофону и системному звуку."
            return
        }
        isDiscoveringAudioSources = true
        defer { isDiscoveringAudioSources = false }

        do {
            let catalog = try await audioCaptureService.discoverSources()
            incomingSources = catalog.incoming
            outgoingSources = catalog.microphones

            incomingSource = catalog.incoming.first(where: { $0.id == incomingSource.id })
                ?? catalog.incoming.first
                ?? .systemAudio
            if let microphone = catalog.microphones.first(where: { $0.id == outgoingSource.id })
                ?? catalog.microphones.first {
                outgoingSource = microphone
            }
            audioSetupError = catalog.microphones.isEmpty
                ? "Подключённый микрофон не найден."
                : nil
        } catch {
            audioSetupError = error.localizedDescription
        }
    }

    @discardableResult
    func startCall() async -> Bool {
        guard callState != .running, !isPreparingAudio, !isFinalizingAudio else { return false }
        refreshAudioPermissions()
        guard audioPermissions.allGranted else {
            audioSetupError = "Для записи нужны доступы к микрофону и системному звуку."
            isAudioPermissionsPresented = true
            return false
        }
        guard outgoingSources.contains(where: { $0.id == outgoingSource.id }) else {
            audioSetupError = "Выберите доступный микрофон."
            return false
        }

        stopPlayback()

        isPreparingAudio = true
        audioSetupError = nil
        incomingRealtimeStatus = .connecting
        outgoingRealtimeStatus = .connecting
        incomingRealtimeFailure = nil
        outgoingRealtimeFailure = nil
        defer { isPreparingAudio = false }

        let startedAt = Date()
        let callID = UUID()
        let folderName = Self.folderName(for: startedAt)
        let folderURL = recordingStorage.rootURL.appendingPathComponent(folderName, isDirectory: true)
        let configuration = GuidanceConfigurationSnapshot.frozen(
            from: openAISettings.configuration
        )
        let contextStore = ConversationContextStore(
            callID: callID,
            contexts: contexts,
            configuration: configuration,
            frozenAt: startedAt
        )

        do {
            let frozenContexts = contextStore.frozenContexts
            let draft = makeRecording(
                id: callID,
                startedAt: startedAt,
                duration: 0,
                folderName: folderName,
                liveTurns: [],
                transcription: RecordingTranscriptionMetadata(
                    callState: .draft,
                    liveStatus: .notStarted,
                    reconciliationStatus: .pending,
                    finalAnalysisStatus: .waitingForReconciliation,
                    incomingRealtimeStatus: nil,
                    outgoingRealtimeStatus: nil,
                    incomingRealtimeFailure: nil,
                    outgoingRealtimeFailure: nil,
                    liveRevision: 0,
                    canonicalRevision: nil,
                    liveJournalSealedAt: nil,
                    provider: "openai",
                    realtimeModelID: configuration.realtimeTranscriptionModelID,
                    fileTranscriptionModelID: configuration.fileTranscriptionModelID,
                    responsesModelID: configuration.responsesModelID,
                    frozenContexts: frozenContexts,
                    frozenConfiguration: configuration,
                    lastErrorCode: nil
                )
            )
            try recordingStorage.save(draft)
            let liveTranscriptJournal = try LiveTranscriptJournal(
                callFolderURL: folderURL,
                callID: callID
            )

            activeCallID = callID
            activeCallStartedAt = startedAt
            activeCallFolderName = folderName
            activeConfiguration = configuration
            activeContextStore = contextStore
            activeLiveTranscriptJournal = liveTranscriptJournal
            liveTranscriptTurns = []
            guidanceCards = []
            enqueuedGuidanceTriggers = []
            currentMoment = nil
            answerHistory = []
            liveGuidanceStatus = .inactive

            let storedKey = try? await openAISettings.loadAPIKey()
            let environmentKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKey = storedKey ?? ((environmentKey?.isEmpty == false) ? environmentKey : nil)

            var sink: DualTrackLiveAudioPCMStream?
            if let apiKey {
                let spendLedger = try CallSpendLedger(
                    callFolderURL: folderURL,
                    callID: callID,
                    initialLimitUSD: configuration.initialPerCallSpendLimitUSD
                )
                activeSpendLedger = spendLedger
                let coordinator = realtimeCoordinatorFactory(spendLedger)
                realtimeCoordinator = coordinator
                observeRealtimeEvents(from: coordinator)
                let liveSink = DualTrackLiveAudioPCMStream(
                    maxBufferedSourceFramesPerTrack: LiveAudioPCMStreamPolicy
                        .productionMaxBufferedSourceFramesPerTrack,
                    onGap: { [weak coordinator] gap in
                        coordinator?.offer(gap)
                    }
                ) { [weak coordinator] chunk in
                    coordinator?.offer(chunk)
                }
                sink = liveSink
                liveAudioSink = liveSink

                let realtimeConfiguration = RealtimeTranscriptionConfiguration(
                    modelID: configuration.realtimeTranscriptionModelID,
                    languages: configuration.transcriptionLanguages
                )
                realtimeStartTask = Task { [weak coordinator] in
                    guard !Task.isCancelled else { return }
                    await coordinator?.start(
                        apiKey: apiKey,
                        configuration: realtimeConfiguration
                    )
                }

                do {
                    let jobStore = try GuidanceJobStore(
                        callFolderURL: folderURL,
                        callID: callID
                    )
                    let guidance = LiveGuidanceCoordinator(
                        store: jobStore,
                        provider: BudgetedLiveGuidanceProvider(
                            base: OpenAIResponsesLiveGuidanceProvider(apiKey: apiKey),
                            ledger: spendLedger
                        )
                    )
                    liveGuidanceCoordinator = guidance
                    observeGuidanceEvents(from: guidance)
                    liveGuidanceStatus = .active
                } catch {
                    liveGuidanceStatus = .failed
                }
            } else {
                incomingRealtimeStatus = .failed
                outgoingRealtimeStatus = .failed
                liveGuidanceStatus = .inactive
            }

            try await audioCaptureService.start(
                AudioCaptureRequest(
                    folderURL: folderURL,
                    incomingSource: incomingSource,
                    microphone: outgoingSource
                ),
                liveAudioSink: sink
            )
            var capturing = draft
            capturing.transcription?.callState = .capturing
            capturing.transcription?.liveStatus = apiKey == nil ? .notStarted : .running
            capturing.transcription?.incomingRealtimeStatus = apiKey == nil
                ? .failed
                : incomingRealtimeStatus
            capturing.transcription?.outgoingRealtimeStatus = apiKey == nil
                ? .failed
                : outgoingRealtimeStatus
            capturing.transcription?.incomingRealtimeFailure = incomingRealtimeFailure
            capturing.transcription?.outgoingRealtimeFailure = outgoingRealtimeFailure
            _ = try? recordingStorage.save(capturing)
            engine.start()
            synchronizeEngineState()
            if apiKey == nil {
                showToast("Запись начата без live-анализа — добавьте API key в Settings")
            }
            return true
        } catch {
            let message = error.localizedDescription
            await discardActiveLiveServices()
            try? FileManager.default.removeItem(at: folderURL)
            resetActiveCallState()
            audioSetupError = message
            showToast(message)
            return false
        }
    }

    func finishCall() async {
        guard callState == .running, !isFinalizingAudio else { return }
        isFinalizingAudio = true

        engine.stop()
        synchronizeEngineState()
        let sessionDuration = elapsedTime
        let startedAt = activeCallStartedAt ?? Date().addingTimeInterval(-sessionDuration)
        let folderName = activeCallFolderName ?? Self.folderName(for: startedAt)
        let callID = activeCallID ?? UUID()
        let contextStore = activeContextStore
        let configuration = activeConfiguration
            ?? GuidanceConfigurationSnapshot.frozen(from: openAISettings.configuration)
        var didFinalizeLiveServices = false

        defer {
            resetActiveCallState(keepGuidance: true)
            isFinalizingAudio = false
        }

        do {
            let capturedFiles = try await audioCaptureService.stop()
            guard capturedFiles.hasAudio else {
                throw AudioCaptureError.noAudioCaptured
            }

            let frozenContexts = contextStore?.frozenContexts
                ?? FrozenContextSnapshot(
                    id: "ctx-empty",
                    frozenAt: startedAt,
                    contexts: []
                )
            let initialRevision = await contextStore?.revision() ?? 0
            var recording = makeRecording(
                id: callID,
                startedAt: startedAt,
                duration: sessionDuration,
                folderName: folderName,
                liveTurns: liveTranscriptTurns,
                transcription: RecordingTranscriptionMetadata(
                    callState: .saved,
                    liveStatus: realtimeCoordinator == nil ? .notStarted : .running,
                    reconciliationStatus: .pending,
                    finalAnalysisStatus: .waitingForReconciliation,
                    incomingRealtimeStatus: incomingRealtimeStatus,
                    outgoingRealtimeStatus: outgoingRealtimeStatus,
                    incomingRealtimeFailure: incomingRealtimeFailure,
                    outgoingRealtimeFailure: outgoingRealtimeFailure,
                    liveRevision: initialRevision,
                    canonicalRevision: nil,
                    liveJournalSealedAt: nil,
                    provider: "openai",
                    realtimeModelID: configuration.realtimeTranscriptionModelID,
                    fileTranscriptionModelID: configuration.fileTranscriptionModelID,
                    responsesModelID: configuration.responsesModelID,
                    frozenContexts: frozenContexts,
                    frozenConfiguration: configuration,
                    lastErrorCode: nil
                )
            )
            // Raw audio has already finalized. Persist it before any converter or
            // network wait so STT failure can never lose the recording.
            try recordingStorage.save(recording)
            _ = try? transcriptService.updateManagedTranscriptFile(for: recording)
            publishSavedRecording(recording)

            cancelGuidanceDebounceTasks()
            var liveAudioSinkReport: LiveAudioSinkReport?
            if let liveAudioSink {
                liveAudioSinkReport = await liveAudioSink.finish()
            }
            let startTask = takeRealtimeStartTask()
            startTask?.cancel()
            if let realtimeCoordinator {
                let cutoff = UInt64(max(0, sessionDuration) * 1_000_000_000)
                let final = await realtimeCoordinator.finish(
                    cutoffCallNanoseconds: cutoff
                )
                liveTranscriptTurns = final.turns
                incomingRealtimeStatus = final.incomingStatus
                outgoingRealtimeStatus = final.outgoingStatus
                incomingRealtimeFailure = final.incomingFailure
                outgoingRealtimeFailure = final.outgoingFailure
                for turn in final.turns
                    where turn.state == .liveFinal
                        || turn.state == .gap
                        || turn.state == .superseded {
                    _ = try? await contextStore?.acceptFinal(turn)
                }
                await enqueueGuidanceThroughCutoff(
                    turns: final.turns,
                    contextStore: contextStore
                )
            }
            if let startTask {
                await startTask.value
            }
            didFinalizeLiveServices = true

            var liveJournalSealedAt: Date?
            var liveJournalWriteFailed = false
            if let activeLiveTranscriptJournal {
                do {
                    for turn in liveTranscriptTurns
                        where turn.state == .liveFinal
                            || turn.state == .reconciled
                            || turn.state == .superseded
                            || turn.state == .gap {
                        _ = try await activeLiveTranscriptJournal.upsert(turn)
                    }
                    let sealedAt = Date()
                    try await activeLiveTranscriptJournal.seal(at: sealedAt)
                    liveJournalSealedAt = sealedAt
                } catch {
                    liveJournalWriteFailed = true
                }
            } else {
                liveJournalWriteFailed = true
            }

            let finalRevision = await contextStore?.revision() ?? initialRevision
            let liveAudioSinkIncomplete = liveAudioSinkReport?.hasKnownGaps == true
            let liveIncomplete = capturedFiles.quality.hasKnownGaps
                || liveAudioSinkIncomplete
                || liveJournalWriteFailed
                || liveTranscriptTurns.contains { $0.state == .gap }
                || incomingRealtimeStatus == .degraded
                || outgoingRealtimeStatus == .degraded
                || incomingRealtimeStatus == .failed
                || outgoingRealtimeStatus == .failed
            recording = makeRecording(
                id: callID,
                startedAt: startedAt,
                duration: sessionDuration,
                folderName: folderName,
                liveTurns: liveTranscriptTurns,
                transcription: RecordingTranscriptionMetadata(
                    callState: .saved,
                    liveStatus: realtimeCoordinator == nil
                        ? .notStarted
                        : (liveIncomplete ? .incomplete : .complete),
                    reconciliationStatus: .pending,
                    finalAnalysisStatus: .waitingForReconciliation,
                    incomingRealtimeStatus: incomingRealtimeStatus,
                    outgoingRealtimeStatus: outgoingRealtimeStatus,
                    incomingRealtimeFailure: incomingRealtimeFailure,
                    outgoingRealtimeFailure: outgoingRealtimeFailure,
                    liveRevision: finalRevision,
                    canonicalRevision: nil,
                    liveJournalSealedAt: liveJournalSealedAt,
                    provider: "openai",
                    realtimeModelID: configuration.realtimeTranscriptionModelID,
                    fileTranscriptionModelID: configuration.fileTranscriptionModelID,
                    responsesModelID: configuration.responsesModelID,
                    frozenContexts: frozenContexts,
                    frozenConfiguration: configuration,
                    lastErrorCode: liveJournalWriteFailed
                        ? "live_journal_write_failed"
                        : (liveAudioSinkIncomplete
                            ? "live_audio_sink_incomplete"
                            : (liveIncomplete ? "live_incomplete" : nil)),
                    incomingWriterDroppedBuffers: capturedFiles.quality.incomingWriterDroppedBuffers,
                    outgoingWriterDroppedBuffers: capturedFiles.quality.outgoingWriterDroppedBuffers,
                    incomingLiveAudioMetrics: liveAudioSinkReport?.incoming,
                    outgoingLiveAudioMetrics: liveAudioSinkReport?.outgoing
                )
            )
            try recordingStorage.save(recording)
            _ = try? transcriptService.updateManagedTranscriptFile(for: recording)
            publishSavedRecording(recording)
            enqueuePostCallProcessing(recording)

            if let liveGuidanceCoordinator {
                Task {
                    await liveGuidanceCoordinator.waitUntilIdle()
                }
            }
            if capturedFiles.warnings.isEmpty {
                showToast("Запись звонка сохранена")
            } else {
                let warning = capturedFiles.warnings
                    .map(\.localizedDescription)
                    .joined(separator: "; ")
                showToast("Запись сохранена не полностью: \(warning)")
            }
        } catch {
            if !didFinalizeLiveServices {
                await discardActiveLiveServices()
            }
            audioSetupError = error.localizedDescription
            showToast("Не удалось сохранить запись: \(error.localizedDescription)")
        }
    }

    func togglePlayback(for recording: Recording) {
        if playingRecordingID == recording.id {
            audioPlaybackService.stop()
            playingRecordingID = nil
            playbackElapsedTime = 0
            playbackDuration = 0
            playbackProgress = 0
            return
        }

        guard let url = preferredPlaybackURL(for: recording) else {
            showToast(AudioPlaybackError.fileMissing.localizedDescription)
            return
        }

        playbackElapsedTime = 0
        playbackDuration = 0
        playbackProgress = 0
        do {
            try audioPlaybackService.play(url: url)
            playingRecordingID = recording.id
        } catch {
            playingRecordingID = nil
            showToast(error.localizedDescription)
        }
    }

    func seekPlayback(for recording: Recording, toProgress progress: Double) {
        guard playingRecordingID == recording.id, progress.isFinite else { return }
        audioPlaybackService.seek(toProgress: min(max(progress, 0), 1))
    }

    func selectRecording(_ id: UUID?) {
        if id != selectedRecordingID {
            stopPlayback()
        }
        selectedRecordingID = id
    }

    func stopRecordingPlayback() {
        stopPlayback()
    }

    func download(_ recording: Recording, export: RecordingAudioExport) {
        guard let sourceURL = audioURL(for: recording, export: export) else {
            showToast(AudioPlaybackError.fileMissing.localizedDescription)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".aicallassistant-export-\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            showToast("Файл \(destinationURL.lastPathComponent) сохранён")
        } catch {
            showToast("Не удалось сохранить аудиофайл")
        }
    }

    func availableAudioExports(for recording: Recording) -> Set<RecordingAudioExport> {
        Set(RecordingAudioExport.allCases.filter { audioURL(for: recording, export: $0) != nil })
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

    func loadFinalAnalysis(
        for recording: Recording
    ) async throws -> FinalAnalysisPublishedResult? {
        let processor = RecordingFinalAnalysisProcessor(
            recordingStorage: recordingStorage,
            provider: finalAnalysisProviderFactory(),
            credentialProvider: finalAnalysisCredentialProviderFactory()
        )
        do {
            let published = try await processor.loadPublishedResult(for: recording)
            if let repaired = try? recordingStorage.load(folderName: recording.folderName) {
                upsertRecording(repaired)
            }
            return published
        } catch {
            if let repaired = try? recordingStorage.load(folderName: recording.folderName) {
                upsertRecording(repaired)
            }
            throw error
        }
    }

    func retryPostCallProcessing(for recording: Recording) async {
        await authorizeConfiguredSpendIncreaseIfNeeded(for: recording)
        if recording.transcription?.reconciliationStatus == .complete {
            await enqueueFinalAnalysis(recording, retryFailed: true)
            return
        }
        guard reconciliationTasks[recording.id] == nil else { return }
        enqueuePostCallProcessing(recording, retryFailed: true)
    }

    private func synchronizeEngineState() {
        callState = engine.state
        elapsedTime = engine.elapsedTime
        if liveGuidanceCoordinator == nil {
            currentMoment = engine.currentMoment
            answerHistory = engine.answerHistory
        }
    }

    private func observeRealtimeEvents(
        from coordinator: RealtimeTranscriptionCoordinator
    ) {
        realtimeEventTask?.cancel()
        realtimeEventTask = Task { @MainActor [weak self] in
            for await event in coordinator.events {
                guard let self, !Task.isCancelled else { return }
                await self.handleRealtimeEvent(event)
            }
        }
    }

    private func handleRealtimeEvent(
        _ event: RealtimeTranscriptionCoordinatorEvent
    ) async {
        switch event {
        case let .trackStatus(track, status):
            switch track {
            case .incoming:
                incomingRealtimeStatus = status
            case .outgoing:
                outgoingRealtimeStatus = status
            }
            persistActiveRealtimeState()

        case let .trackFailure(track, failure):
            switch track {
            case .incoming:
                incomingRealtimeFailure = failure
            case .outgoing:
                outgoingRealtimeFailure = failure
            }
            persistActiveRealtimeState()

        case let .transcriptUpdated(turn):
            if let index = liveTranscriptTurns.firstIndex(where: { $0.id == turn.id }) {
                liveTranscriptTurns[index] = turn
            } else {
                liveTranscriptTurns.append(turn)
            }
            liveTranscriptTurns.sort(by: LiveTranscriptTurn.canonicalTimelineOrder)

            guard turn.state == .liveFinal
                    || turn.state == .gap
                    || turn.state == .superseded else { return }
            if let activeLiveTranscriptJournal {
                do {
                    _ = try await activeLiveTranscriptJournal.upsert(turn)
                } catch {
                    // Do not enqueue an analysis snapshot whose trigger has not
                    // crossed the local write-ahead boundary.
                    liveGuidanceStatus = liveGuidanceStatus.transitioning(to: .failed)
                    return
                }
            }
            _ = try? await activeContextStore?.acceptFinal(turn)
            if turn.track == .incoming,
               turn.state == .liveFinal,
               !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleGuidance(for: turn)
            }

        case .trackGap:
            break
        }
    }

    private func scheduleGuidance(for turn: LiveTranscriptTurn) {
        guidanceDebounceTasks[turn.id]?.cancel()
        let reference = turn.reference
        let cutoff = turn.endCallNanoseconds ?? turn.startCallNanoseconds
        guidanceDebounceTasks[turn.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            while !Task.isCancelled {
                guard let self,
                      let contextStore = self.activeContextStore,
                      let transcriptCoordinator = self.realtimeCoordinator,
                      let guidanceCoordinator = self.liveGuidanceCoordinator,
                      let journal = self.activeLiveTranscriptJournal else { return }

                if let barrier = await transcriptCoordinator.guidanceSnapshotIfSettled(
                    through: cutoff
                ) {
                    guard !Task.isCancelled,
                          self.realtimeCoordinator === transcriptCoordinator else { return }
                    do {
                        for terminalTurn in barrier.turns where
                            terminalTurn.state == .liveFinal
                                || terminalTurn.state == .reconciled
                                || terminalTurn.state == .gap {
                            guard !Task.isCancelled else { return }
                            _ = try await journal.upsert(terminalTurn)
                            _ = try await contextStore.acceptFinal(terminalTurn)
                        }
                        guard !Task.isCancelled else { return }
                        let snapshot = try await contextStore.makeLiveSnapshot(
                            trigger: reference
                        )
                        _ = try await guidanceCoordinator.enqueue(snapshot: snapshot)
                        self.enqueuedGuidanceTriggers.insert(reference)
                    self.liveGuidanceStatus = self.liveGuidanceStatus.transitioning(to: .active)
                } catch ConversationContextStoreError.contextLimitReached {
                    self.liveGuidanceStatus = self.liveGuidanceStatus.transitioning(
                        to: .contextLimitReached
                    )
                } catch {
                    self.liveGuidanceStatus = self.liveGuidanceStatus.transitioning(to: .failed)
                    }
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
            }
        }
    }

    /// The normal debounce improves live stability. Stop uses this durable
    /// barrier so an incoming utterance finalized by the bounded socket flush
    /// cannot disappear when live tasks are torn down.
    private func enqueueGuidanceThroughCutoff(
        turns: [LiveTranscriptTurn],
        contextStore: ConversationContextStore?
    ) async {
        guard let contextStore, let coordinator = liveGuidanceCoordinator else { return }
        for turn in turns
            .filter({
                $0.track == .incoming
                    && $0.state == .liveFinal
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
            .sorted(by: LiveTranscriptTurn.canonicalTimelineOrder) {
            guard !enqueuedGuidanceTriggers.contains(turn.reference) else { continue }
            do {
                let snapshot = try await contextStore.makeLiveSnapshot(
                    trigger: turn.reference
                )
                _ = try await coordinator.enqueue(snapshot: snapshot)
                enqueuedGuidanceTriggers.insert(turn.reference)
            } catch ConversationContextStoreError.contextLimitReached {
                liveGuidanceStatus = liveGuidanceStatus.transitioning(
                    to: .contextLimitReached
                )
            } catch {
                liveGuidanceStatus = liveGuidanceStatus.transitioning(to: .failed)
            }
        }
    }

    private func observeGuidanceEvents(from coordinator: LiveGuidanceCoordinator) {
        guidancePublicationTask?.cancel()
        guidancePublicationTask = Task { @MainActor [weak self] in
            for await event in coordinator.events {
                guard let self, !Task.isCancelled else { return }
                self.liveGuidanceStatus = self.liveGuidanceStatus.applying(event)
                switch event {
                case let .published(run):
                    for pair in run.pairs {
                        self.guidanceCards.removeAll { $0.id == pair.id }
                        self.guidanceCards.append(pair)
                    }
                    self.rebuildGuidanceProjection()
                case .failed:
                    break
                }
            }
        }
    }

    private func rebuildGuidanceProjection() {
        let ordered = guidanceCards.sorted { lhs, rhs in
            evidenceTimestamp(for: lhs) < evidenceTimestamp(for: rhs)
        }
        currentMoment = ordered.last.map(makeAssistantMoment)
        answerHistory = ordered.dropLast().map { pair in
            AnswerHistoryItem(
                id: Self.stableUUID(from: pair.id),
                moment: makeAssistantMoment(pair),
                elapsedTime: evidenceTimestamp(for: pair)
            )
        }
    }

    private func makeAssistantMoment(_ pair: QuestionAnswerPair) -> AssistantMoment {
        AssistantMoment(
            id: Self.stableUUID(from: pair.id),
            guidancePair: pair,
            transcriptTurns: liveTranscriptTurns
        )
    }

    private func evidenceTimestamp(for pair: QuestionAnswerPair) -> TimeInterval {
        let ids = Set(pair.evidence.map(\.turn.turnID))
        let nanoseconds = liveTranscriptTurns
            .filter { ids.contains($0.id) }
            .map(\.startCallNanoseconds)
            .min() ?? 0
        return TimeInterval(nanoseconds) / 1_000_000_000
    }

    private func publishSavedRecording(_ recording: Recording) {
        upsertRecording(recording)
        selectedRecordingID = recording.id
        screen = .setup
    }

    private func upsertRecording(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        recordings.append(recording)
        recordings.sort {
            if $0.startedAt == $1.startedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startedAt > $1.startedAt
        }
    }

    private func enqueuePostCallProcessing(
        _ original: Recording,
        retryFailed: Bool = false
    ) {
        guard reconciliationTasks[original.id] == nil,
              let metadata = original.transcription else { return }
        if metadata.reconciliationStatus == .complete
            || metadata.reconciliationStatus == .incomplete {
            return
        }

        var running = original
        running.transcription?.reconciliationStatus = .running
        running.transcription?.reconciliationUpdatedAt = Date()
        running.transcription?.lastErrorCode = nil
        _ = try? recordingStorage.save(running)
        upsertRecording(running)

        let processor = RecordingReconciliationProcessor(
            recordingStorage: recordingStorage,
            provider: fileTranscriptionProviderFactory(),
            credentialProvider: reconciliationCredentialProviderFactory()
        )
        let recordingID = original.id
        reconciliationTasks[recordingID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reconciliationTasks[recordingID] = nil }
            do {
                let outcome = try await processor.process(
                    recording: running,
                    retryFailed: retryFailed
                )
                if outcome.canonicalCommit != nil {
                    _ = try? self.transcriptService.updateManagedTranscriptFile(
                        for: outcome.recording
                    )
                }
                self.upsertRecording(outcome.recording)
                if outcome.recording.transcription?.reconciliationStatus == .complete {
                    await self.enqueueFinalAnalysis(
                        outcome.recording,
                        reconciliation: outcome.job
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                var failed = running
                failed.transcription?.reconciliationStatus = .failed
                failed.transcription?.finalAnalysisStatus = .waitingForReconciliation
                failed.transcription?.reconciliationUpdatedAt = Date()
                failed.transcription?.lastErrorCode = "reconciliation_pipeline_failed"
                _ = try? self.recordingStorage.save(failed)
                self.upsertRecording(failed)
            }
        }
    }

    private func enqueueFinalAnalysis(
        _ original: Recording,
        reconciliation suppliedReconciliation: ReconciliationStoredJob? = nil,
        retryFailed: Bool = false
    ) async {
        guard finalAnalysisTasks[original.id] == nil,
              let metadata = original.transcription,
              metadata.reconciliationStatus == .complete,
              let canonicalRevision = metadata.canonicalRevision,
              let canonicalTranscriptSHA256 = metadata.canonicalTranscriptSHA256 else { return }

        switch metadata.finalAnalysisStatus {
        case .contextLimitExceeded:
            return
        case .failed where !retryFailed:
            return
        case .blockedBySpendLimit where !retryFailed:
            return
        default:
            break
        }

        let reconciliation: ReconciliationStoredJob
        do {
            if let suppliedReconciliation {
                reconciliation = suppliedReconciliation
            } else {
                let folderURL = try recordingStorage.folderURL(for: original)
                let store = try ReconciliationJobStore(
                    callFolderURL: folderURL,
                    callID: original.id
                )
                guard let persisted = await store.currentJob() else { return }
                reconciliation = persisted
            }
        } catch {
            return
        }
        guard reconciliation.status == .complete else { return }

        var running = original
        running.transcription?.finalAnalysisStatus = .running
        running.transcription?.finalAnalysisUpdatedAt = Date()
        running.transcription?.lastErrorCode = nil
        if let pointer = running.transcription?.finalAnalysisResultPointer,
           !pointer.matches(
               canonicalRevision: canonicalRevision,
               canonicalTranscriptHash: canonicalTranscriptSHA256
           ) {
            running.transcription?.finalAnalysisResultPointer = nil
        }
        _ = try? recordingStorage.save(running)
        upsertRecording(running)

        let processor = RecordingFinalAnalysisProcessor(
            recordingStorage: recordingStorage,
            provider: finalAnalysisProviderFactory(),
            credentialProvider: finalAnalysisCredentialProviderFactory()
        )
        let recordingID = original.id
        finalAnalysisTasks[recordingID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finalAnalysisTasks[recordingID] = nil }
            do {
                let outcome = try await processor.process(
                    recording: running,
                    reconciliation: reconciliation,
                    retryFailed: retryFailed
                )
                self.upsertRecording(outcome.recording)
            } catch is CancellationError {
                return
            } catch {
                var failed = running
                failed.transcription?.finalAnalysisStatus = .failed
                failed.transcription?.finalAnalysisUpdatedAt = Date()
                failed.transcription?.lastErrorCode = "final_analysis_pipeline_failed"
                _ = try? self.recordingStorage.save(failed)
                self.upsertRecording(failed)
            }
        }
    }

    private func resumePendingPostCallProcessing(
        includeCredentialBlocked: Bool = false
    ) async {
        let current = (try? recordingStorage.loadAll()) ?? recordings
        for original in current {
            var recording = original
            if recording.transcription?.callState == .draft
                || recording.transcription?.callState == .capturing {
                recording = await recoverInterruptedRecording(recording)
                _ = try? transcriptService.updateManagedTranscriptFile(for: recording)
                upsertRecording(recording)
                if recording.transcription?.reconciliationStatus == .pending {
                    enqueuePostCallProcessing(recording)
                }
                continue
            }
            guard let status = recording.transcription?.reconciliationStatus else { continue }
            switch status {
            case .pending, .running:
                enqueuePostCallProcessing(recording)
            case .blockedByCredential where includeCredentialBlocked:
                enqueuePostCallProcessing(recording)
            case .complete:
                let repair = RecordingReconciliationProcessor(
                    recordingStorage: recordingStorage,
                    provider: fileTranscriptionProviderFactory(),
                    credentialProvider: reconciliationCredentialProviderFactory()
                )
                if let repaired = try? repair.repairCanonicalPointerIfNeeded(recording) {
                    recording = repaired
                    _ = try? transcriptService.updateManagedTranscriptFile(for: recording)
                    upsertRecording(recording)
                }
                let finalStatus = recording.transcription?.finalAnalysisStatus
                let shouldResumeFinal = finalStatus == .pending
                    || finalStatus == .running
                    || finalStatus == .waitingForReconciliation
                    || (includeCredentialBlocked && finalStatus == .blockedByCredential)
                    || finalStatus == .complete
                if shouldResumeFinal {
                    await enqueueFinalAnalysis(recording)
                }
            default:
                break
            }
        }
    }

    private func recoverInterruptedRecording(_ original: Recording) async -> Recording {
        var recording = original
        recording.transcription?.callState = .interrupted
        recording.transcription?.liveStatus = .incomplete
        recording.transcription?.finalAnalysisStatus = .waitingForReconciliation

        if let folderURL = try? recordingStorage.folderURL(for: recording),
           let journal = try? LiveTranscriptJournal(
               callFolderURL: folderURL,
               callID: recording.id
           ) {
            var snapshot = await journal.snapshot()
            if snapshot.sealedAt == nil {
                try? await journal.seal()
                snapshot = await journal.snapshot()
            }
            recording.turns = Self.transcriptTurns(from: snapshot.turns)
            let existingLiveRevision = recording.transcription?.liveRevision ?? 0
            recording.transcription?.liveRevision = max(
                existingLiveRevision,
                snapshot.revision
            )
            recording.transcription?.liveJournalSealedAt = snapshot.sealedAt
        }

        guard let urls = try? recordingStorage.audioURLs(for: recording) else {
            recording.transcription?.reconciliationStatus = .incomplete
            recording.transcription?.lastErrorCode = "call_interrupted_before_audio_finalize"
            _ = try? recordingStorage.save(recording)
            return recording
        }

        let inspector = ReconciliationAudioAssetInspector()
        async let incomingAsset = Self.inspectRecoveredAudio(
            inspector: inspector,
            track: .incoming,
            url: urls.incoming
        )
        async let outgoingAsset = Self.inspectRecoveredAudio(
            inspector: inspector,
            track: .outgoing,
            url: urls.outgoing
        )
        let assets = await [incomingAsset, outgoingAsset].compactMap { $0 }
        guard !assets.isEmpty else {
            recording.transcription?.reconciliationStatus = .incomplete
            recording.transcription?.lastErrorCode = "call_interrupted_before_audio_finalize"
            _ = try? recordingStorage.save(recording)
            return recording
        }

        let durationNanoseconds = assets.map(\.sourceDurationNanoseconds).max() ?? 0
        recording.duration = max(
            max(
                recording.duration,
                TimeInterval(durationNanoseconds) / 1_000_000_000
            ),
            1
        )
        recording.transcription?.reconciliationStatus = .pending
        recording.transcription?.lastErrorCode = "call_interrupted_after_audio_finalize"
        _ = try? recordingStorage.save(recording)
        return recording
    }

    private nonisolated static func inspectRecoveredAudio(
        inspector: ReconciliationAudioAssetInspector,
        track: AudioTrack,
        url: URL
    ) async -> ReconciliationAudioAsset? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? await inspector.inspect(track: track, url: url)
    }

    private func authorizeConfiguredSpendIncreaseIfNeeded(
        for recording: Recording
    ) async {
        guard let metadata = recording.transcription,
            metadata.reconciliationStatus == .blockedBySpendLimit
                || metadata.finalAnalysisStatus == .blockedBySpendLimit,
            let folderURL = try? recordingStorage.folderURL(for: recording),
            let ledger = try? CallSpendLedger(
                callFolderURL: folderURL,
                callID: recording.id,
                initialLimitUSD: metadata.frozenConfiguration.initialPerCallSpendLimitUSD
            )
        else { return }

        let snapshot = await ledger.currentSnapshot()
        guard let current = snapshot.authorizationRevisions.max(by: {
            $0.revision < $1.revision
        }) else { return }
        let proposed = openAISettings.configuration.perCallSpendLimitUSD
        guard proposed > current.authorizedLimitUSD else { return }
        let nextRevision = current.revision + 1
        try? await ledger.authorizeHigherLimit(
            SpendAuthorizationRevision(
                id: "spend:\(recording.id.uuidString):\(nextRevision)",
                callID: recording.id,
                revision: nextRevision,
                authorizedLimitUSD: proposed,
                priceCatalogVersion: snapshot.priceCatalogVersion,
                createdAt: Date()
            )
        )
    }

    private func discardActiveLiveServices() async {
        cancelGuidanceDebounceTasks()
        enqueuedGuidanceTriggers.removeAll()
        liveAudioSink?.stopAccepting()
        if let liveAudioSink {
            _ = await liveAudioSink.finish()
        }
        let startTask = takeRealtimeStartTask()
        startTask?.cancel()
        if let realtimeCoordinator {
            _ = await realtimeCoordinator.finish(
                cutoffCallNanoseconds: 0,
                finalWaitNanoseconds: 0
            )
        }
        if let startTask {
            await startTask.value
        }
        realtimeEventTask?.cancel()
        guidancePublicationTask?.cancel()
    }

    private func cancelGuidanceDebounceTasks() {
        guidanceDebounceTasks.values.forEach { $0.cancel() }
        guidanceDebounceTasks.removeAll()
    }

    private func takeRealtimeStartTask() -> Task<Void, Never>? {
        defer { realtimeStartTask = nil }
        return realtimeStartTask
    }

    private func resetActiveCallState(keepGuidance: Bool = false) {
        realtimeEventTask?.cancel()
        realtimeEventTask = nil
        cancelGuidanceDebounceTasks()
        realtimeStartTask?.cancel()
        realtimeStartTask = nil
        liveAudioSink = nil
        realtimeCoordinator = nil
        activeContextStore = nil
        activeLiveTranscriptJournal = nil
        activeConfiguration = nil
        activeSpendLedger = nil
        activeCallID = nil
        activeCallStartedAt = nil
        activeCallFolderName = nil
        incomingRealtimeStatus = .connecting
        outgoingRealtimeStatus = .connecting
        incomingRealtimeFailure = nil
        outgoingRealtimeFailure = nil
        if !keepGuidance {
            guidancePublicationTask?.cancel()
            guidancePublicationTask = nil
            liveGuidanceCoordinator = nil
        }
    }

    private func persistActiveRealtimeState() {
        guard let activeCallFolderName,
              var recording = try? recordingStorage.load(folderName: activeCallFolderName),
              recording.transcription != nil else { return }

        recording.transcription?.incomingRealtimeStatus = incomingRealtimeStatus
        recording.transcription?.outgoingRealtimeStatus = outgoingRealtimeStatus
        recording.transcription?.incomingRealtimeFailure = incomingRealtimeFailure
        recording.transcription?.outgoingRealtimeFailure = outgoingRealtimeFailure
        _ = try? recordingStorage.save(recording)
    }

    private func persistContextsInBackground() {
        contextPersistenceRevision += 1
        contextsNeedPersistence = true

        let revision = contextPersistenceRevision
        let snapshot = contexts
        let writer = contextLibraryWriter
        let preserveRecovery = contextLibraryNeedsRecoveryBackup

        contextPersistenceTask?.cancel()
        contextPersistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            do {
                try await writer.save(
                    snapshot,
                    revision: revision,
                    preservingExistingAsRecovery: preserveRecovery
                )
                guard let self,
                      self.contextPersistenceRevision == revision else {
                    return
                }
                self.contextsNeedPersistence = false
                self.contextLibraryNeedsRecoveryBackup = false
            } catch {
                guard let self,
                      self.contextPersistenceRevision == revision else {
                    return
                }
                self.contextsNeedPersistence = true
                self.showToast("Не удалось сохранить контексты")
            }
        }
    }

    private func persistContextsForTermination() async -> Bool {
        contextPersistenceTask?.cancel()
        contextPersistenceTask = nil

        while contextsNeedPersistence {
            let revision = contextPersistenceRevision
            let snapshot = contexts
            let preserveRecovery = contextLibraryNeedsRecoveryBackup

            do {
                try await contextLibraryWriter.save(
                    snapshot,
                    revision: revision,
                    preservingExistingAsRecovery: preserveRecovery
                )
            } catch {
                showToast("Не удалось сохранить контексты. Приложение осталось открытым.")
                return false
            }

            if contextPersistenceRevision == revision {
                contextsNeedPersistence = false
                contextLibraryNeedsRecoveryBackup = false
            }
        }
        return true
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

    private func makeRecording(
        id: UUID,
        startedAt: Date,
        duration: TimeInterval,
        folderName: String,
        liveTurns: [LiveTranscriptTurn],
        transcription: RecordingTranscriptionMetadata?
    ) -> Recording {
        let turns = Self.transcriptTurns(from: liveTurns)

        let titleFormatter = DateFormatter()
        titleFormatter.locale = Locale(identifier: "ru_RU")
        titleFormatter.dateFormat = "d MMMM, HH:mm"

        return Recording(
            id: id,
            title: "Звонок \(titleFormatter.string(from: startedAt))",
            startedAt: startedAt,
            duration: max(duration, 1),
            folderName: folderName,
            turns: turns,
            transcription: transcription
        )
    }

    private static func transcriptTurns(
        from liveTurns: [LiveTranscriptTurn]
    ) -> [TranscriptTurn] {
        liveTurns
            .filter { $0.state == .liveFinal || $0.state == .reconciled }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted(by: LiveTranscriptTurn.canonicalTimelineOrder)
            .map { turn in
                TranscriptTurn(
                    id: turn.id,
                    speaker: turn.track == .incoming ? .participant : .you,
                    timestamp: TimeInterval(turn.startCallNanoseconds) / 1_000_000_000,
                    text: turn.text
                )
            }
    }

    nonisolated private static func loadContextFile(
        at url: URL
    ) throws -> ContextFileExtractionInput {
        guard url.isFileURL else {
            throw ContextFileTextExtractionError.unreadableFile
        }

        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw ContextFileTextExtractionError.unreadableFile
            }
            if let fileSize = values.fileSize {
                guard fileSize > 0 else {
                    throw ContextFileTextExtractionError.emptyFile
                }
                guard fileSize < OpenAIContextFileTextExtractor.maximumFileBytes else {
                    throw ContextFileTextExtractionError.fileTooLarge
                }
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                throw ContextFileTextExtractionError.emptyFile
            }
            guard data.count < OpenAIContextFileTextExtractor.maximumFileBytes else {
                throw ContextFileTextExtractionError.fileTooLarge
            }

            let mediaType = UTType(filenameExtension: url.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"
            return ContextFileExtractionInput(
                fileName: url.lastPathComponent,
                mediaType: mediaType,
                data: data
            )
        } catch let error as ContextFileTextExtractionError {
            throw error
        } catch {
            throw ContextFileTextExtractionError.unreadableFile
        }
    }

    nonisolated private static func sanitizedContextFileName(_ fileName: String) -> String {
        String(
            fileName.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }
        )
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func stableUUID(from string: String) -> UUID {
        let bytes = Array(string.utf8)
        var value = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() {
            value[index % 16] = value[index % 16] &+ byte &+ UInt8(truncatingIfNeeded: index)
        }
        value[6] = (value[6] & 0x0F) | 0x40
        value[8] = (value[8] & 0x3F) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }

    private func preferredPlaybackURL(for recording: Recording) -> URL? {
        audioURL(for: recording, export: .combined)
            ?? audioURL(for: recording, export: .incoming)
            ?? audioURL(for: recording, export: .outgoing)
    }

    private func stopPlayback() {
        audioPlaybackService.stop()
        playingRecordingID = nil
        playbackElapsedTime = 0
        playbackDuration = 0
        playbackProgress = 0
    }

    private func audioURL(for recording: Recording, export: RecordingAudioExport) -> URL? {
        guard let urls = try? recordingStorage.audioURLs(for: recording) else { return nil }
        let url: URL
        switch export {
        case .combined:
            url = urls.combined
        case .incoming:
            url = urls.incoming
        case .outgoing:
            url = urls.outgoing
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(formatter.string(from: date))_\(UUID().uuidString.prefix(8).lowercased())"
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
