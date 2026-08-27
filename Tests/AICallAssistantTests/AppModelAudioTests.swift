import Foundation
import XCTest
@testable import AICallAssistant

@MainActor
final class AppModelAudioTests: XCTestCase {
    func testContextFileExtractionUsesKeyEnteredInAppAndKeepsTextHidden() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let sourceData = Data("SOURCE_FILE_BODY_🙂".utf8)
        let sourceURL = rootURL.appendingPathComponent("brief.txt")
        try sourceData.write(to: sourceURL)

        let defaults = isolatedUserDefaults()
        let extractor = RecordingContextFileTextExtractor(
            output: "HIDDEN_EXTRACTED_TEXT_🙂"
        )
        let settings = OpenAISettingsStore(
            userDefaults: defaults,
            secretStore: StaticTestSecretStore(secret: "key-entered-in-app")
        )
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            transcriptService: TranscriptFileService(documentsURL: rootURL),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(rootURL: rootURL),
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: settings,
            contextFileTextExtractor: extractor,
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: defaults,
            recordings: []
        )

        let attachment = try await model.extractContextFile(at: sourceURL)
        let captured = await extractor.capturedRequest()

        XCTAssertEqual(captured?.input.fileName, "brief.txt")
        XCTAssertEqual(captured?.input.data, sourceData)
        XCTAssertEqual(captured?.apiKey, "key-entered-in-app")
        XCTAssertEqual(captured?.modelID, GuidanceConfigurationDefaults.responsesModelID)
        XCTAssertEqual(attachment.fileName, "brief.txt")
        XCTAssertEqual(attachment.byteCount, sourceData.count)
        XCTAssertEqual(attachment.contentSHA256.count, 64)
        XCTAssertEqual(attachment.extractedText, "HIDDEN_EXTRACTED_TEXT_🙂")

        model.saveContext(
            title: "Контекст из файла",
            body: "VISIBLE_MANUAL_BODY",
            attachments: [attachment]
        )
        let saved = try XCTUnwrap(model.contexts.first)
        XCTAssertEqual(saved.body, "VISIBLE_MANUAL_BODY")
        XCTAssertFalse(saved.body.contains("HIDDEN_EXTRACTED_TEXT"))
        XCTAssertTrue(saved.assistantContextBody.contains("HIDDEN_EXTRACTED_TEXT_🙂"))
    }

    func testProductionDefaultDoesNotInjectSampleContexts() {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let defaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            transcriptService: TranscriptFileService(documentsURL: rootURL),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(rootURL: rootURL),
            contextLibraryStore: isolatedContextLibraryStore(),
            userDefaults: defaults,
            recordings: []
        )

        XCTAssertTrue(model.contexts.isEmpty)
    }

    func testIdleTerminationPersistsSavedContextAndRelaunchRestoresIt() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = ContextLibraryStore(rootURL: rootURL)
        let defaults = isolatedUserDefaults()
        let attachment = ContextFileAttachment(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            fileName: "resume.pdf",
            mediaType: "application/pdf",
            byteCount: 321,
            contentSHA256: String(repeating: "a", count: 64),
            extractedText: "Exact extracted text"
        )
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(rootURL: rootURL),
            contextLibraryStore: store,
            openAISettings: isolatedOpenAISettings(userDefaults: defaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: defaults,
            contexts: [],
            recordings: []
        )
        model.saveContext(
            title: "Senior Product Manager",
            body: "B2B SaaS experience",
            attachments: [attachment]
        )
        model.toggleContext(try XCTUnwrap(model.contexts.first))
        let expectedContexts = model.contexts

        let shouldTerminate = await model.prepareForTermination()

        XCTAssertTrue(shouldTerminate)
        XCTAssertEqual(model.callState, .idle)

        let relaunchedModel = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(rootURL: rootURL),
            contextLibraryStore: store,
            openAISettings: isolatedOpenAISettings(userDefaults: defaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: defaults,
            contexts: nil,
            recordings: []
        )

        XCTAssertEqual(relaunchedModel.contexts, expectedContexts)
    }

    func testExplicitContextsOverridePreviouslyPersistedLibrary() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = ContextLibraryStore(rootURL: rootURL)
        let persistedContext = CallContext(
            title: "Persisted context",
            body: "Must not win",
            isSelected: false
        )
        let explicitContext = CallContext(
            title: "Explicit context",
            body: "Must win",
            isSelected: true
        )
        try store.save([persistedContext])
        let defaults = isolatedUserDefaults()

        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(rootURL: rootURL),
            contextLibraryStore: store,
            openAISettings: isolatedOpenAISettings(userDefaults: defaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: defaults,
            contexts: [explicitContext],
            recordings: []
        )

        XCTAssertEqual(model.contexts, [explicitContext])
    }

    func testEditAfterUnreadableLibraryPreservesRecoveryCopy() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let contextsURL = rootURL.appendingPathComponent(ContextLibraryStore.filename)
        let futureLibrary = Data(
            """
            {"schemaVersion":999,"contexts":[]}
            """.utf8
        )
        try futureLibrary.write(to: contextsURL, options: .atomic)

        let store = ContextLibraryStore(rootURL: rootURL)
        let defaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(
                rootURL: rootURL.appendingPathComponent("Recordings", isDirectory: true)
            ),
            contextLibraryStore: store,
            openAISettings: isolatedOpenAISettings(userDefaults: defaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: defaults,
            contexts: nil,
            recordings: []
        )
        XCTAssertTrue(model.contexts.isEmpty)

        model.saveContext(
            title: "Новый контекст",
            body: "Новая библиотека",
            attachments: []
        )
        let shouldTerminate = await model.prepareForTermination()
        XCTAssertTrue(shouldTerminate)

        let recoveryURLs = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(ContextLibraryStore.recoveryFilenamePrefix)
        }
        XCTAssertEqual(recoveryURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(recoveryURLs.first)), futureLibrary)
        XCTAssertEqual(try store.load(), model.contexts)
    }

    func testTerminationReturnsFalseWhenContextLibraryCannotBeSaved() async throws {
        let rootURL = temporaryRoot()
        let temporaryContainerURL = rootURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: temporaryContainerURL) }
        try FileManager.default.createDirectory(
            at: temporaryContainerURL,
            withIntermediateDirectories: true
        )
        try Data("ordinary file".utf8).write(to: rootURL)
        let store = ContextLibraryStore(rootURL: rootURL)
        let defaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(
                rootURL: temporaryContainerURL.appendingPathComponent(
                    "Recordings",
                    isDirectory: true
                )
            ),
            contextLibraryStore: store,
            openAISettings: isolatedOpenAISettings(userDefaults: defaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: defaults,
            contexts: [],
            recordings: []
        )
        model.saveContext(
            title: "Unsaved context",
            body: "The app must remain open",
            attachments: []
        )

        let shouldTerminate = await model.prepareForTermination()

        XCTAssertFalse(shouldTerminate)
        XCTAssertEqual(model.contexts.map(\.title), ["Unsaved context"])
    }

    func testCallLifecycleCapturesAudioAndPersistsRecording() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let application = AudioSourceOption(
            id: "application:com.example.call",
            title: "Call App",
            kind: .application(bundleIdentifier: "com.example.call", processID: 42)
        )
        let microphone = AudioSourceOption(
            id: "microphone:test",
            title: "Test Microphone",
            kind: .microphone(uniqueID: "test")
        )
        let capture = FakeAudioCaptureService(
            catalog: AudioSourceCatalog(
                incoming: [.systemAudio, application],
                microphones: [microphone]
            )
        )
        let storage = RecordingStorageService(rootURL: rootURL)
        let userDefaults = isolatedUserDefaults()
        let permissions = FakeAudioPermissionService(authorized: true)
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            transcriptService: TranscriptFileService(documentsURL: rootURL),
            audioCaptureService: capture,
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: permissions,
            recordingStorage: storage,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )

        await model.refreshAudioSources()
        model.incomingSource = application
        let didStart = await model.startCall()

        XCTAssertTrue(didStart)
        XCTAssertEqual(model.callState, .running)
        XCTAssertEqual(capture.startRequests.first?.incomingSource, application)
        XCTAssertEqual(capture.startRequests.first?.microphone, microphone)
        XCTAssertEqual(try storage.loadAll().first?.transcription?.callState, .capturing)

        await model.finishCall()

        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(model.callState, .stopped)
        XCTAssertEqual(model.recordings.count, 1)
        // Recordings now open from the main call hub instead of replacing it.
        XCTAssertEqual(model.screen, .setup)

        let persisted = try storage.loadAll()
        XCTAssertEqual(persisted, model.recordings)
        let urls = try storage.audioURLs(for: persisted[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.combined.path))
        let callFolder = rootURL.appendingPathComponent(persisted[0].folderName)
        let journal = try LiveTranscriptJournal(
            callFolderURL: callFolder,
            callID: persisted[0].id
        )
        let journalSnapshot = await journal.snapshot()
        XCTAssertNotNil(journalSnapshot.sealedAt)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: callFolder
                    .appendingPathComponent("transcript.txt")
                    .path
            )
        )
    }

    func testRawCaptureAndEngineStartDoNotWaitForRealtimeReadiness() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let microphone = AudioSourceOption(
            id: "microphone:test",
            title: "Test Microphone",
            kind: .microphone(uniqueID: "test")
        )
        let capture = FakeAudioCaptureService(
            catalog: AudioSourceCatalog(
                incoming: [.systemAudio],
                microphones: [microphone]
            )
        )
        let incoming = GatedStartTranscriptionClient()
        let outgoing = GatedStartTranscriptionClient()
        let resultProbe = StartCallResultProbe()
        let userDefaults = isolatedUserDefaults()
        let settings = OpenAISettingsStore(
            userDefaults: userDefaults,
            secretStore: StaticTestSecretStore(secret: "unit-test-key")
        )
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            transcriptService: TranscriptFileService(documentsURL: rootURL),
            audioCaptureService: capture,
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: RecordingStorageService(rootURL: rootURL),
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: settings,
            realtimeCoordinatorFactory: { spendAuthorizer in
                RealtimeTranscriptionCoordinator(
                    incomingClient: incoming,
                    outgoingClient: outgoing,
                    spendAuthorizer: spendAuthorizer
                )
            },
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )
        await model.refreshAudioSources()

        let startTask = Task { @MainActor in
            let result = await model.startCall()
            await resultProbe.set(result)
            return result
        }
        let bothConnectionsStarted = await eventuallyAsync {
            let incomingCount = await incoming.connectCount
            let outgoingCount = await outgoing.connectCount
            return incomingCount == 1 && outgoingCount == 1
        }
        XCTAssertTrue(bothConnectionsStarted)
        let returnedBeforeReadiness = await eventuallyAsync(
            timeoutNanoseconds: 500_000_000
        ) {
            await resultProbe.result != nil
        }
        XCTAssertTrue(returnedBeforeReadiness)
        XCTAssertEqual(capture.startRequests.count, 1)
        XCTAssertEqual(model.callState, .running)

        await incoming.releaseConnections()
        await outgoing.releaseConnections()
        let didStart = await startTask.value
        XCTAssertTrue(didStart)
        await model.finishCall()
    }

    func testLaunchRecoveryRestoresTerminalTurnsFromLiveJournal() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storage = RecordingStorageService(rootURL: rootURL)
        let callID = UUID()
        let folderName = "interrupted-live-journal"
        let configuration = GuidanceConfigurationSnapshot.frozen(
            from: GuidanceConfiguration.default
        )
        let frozenContexts = FrozenContextSnapshot(
            id: "ctx-empty",
            frozenAt: Date(timeIntervalSince1970: 1),
            contexts: []
        )
        let draft = Recording(
            id: callID,
            title: "Interrupted",
            startedAt: Date(timeIntervalSince1970: 10),
            duration: 1,
            folderName: folderName,
            turns: [],
            transcription: RecordingTranscriptionMetadata(
                callState: .capturing,
                liveStatus: .running,
                reconciliationStatus: .pending,
                finalAnalysisStatus: .waitingForReconciliation,
                incomingRealtimeStatus: .live,
                outgoingRealtimeStatus: .live,
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
        try storage.save(draft)
        let folder = try storage.folderURL(for: draft)
        let journal = try LiveTranscriptJournal(callFolderURL: folder, callID: callID)
        let liveTurn = LiveTranscriptTurn(
            id: UUID(),
            track: .incoming,
            startCallNanoseconds: 2_000_000_000,
            endCallNanoseconds: 3_000_000_000,
            text: "Какой следующий шаг?",
            revision: 1,
            state: .liveFinal,
            sessionEpoch: 1,
            providerItemID: "item-recovered",
            providerContentIndex: 0
        )
        _ = try await journal.upsert(liveTurn)

        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: storage,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: [draft]
        )

        await waitUntil {
            model.recordings.first?.transcription?.callState == .interrupted
        }
        let recovered = try XCTUnwrap(model.recordings.first)
        XCTAssertEqual(recovered.transcription?.liveStatus, .incomplete)
        XCTAssertEqual(recovered.transcription?.liveRevision, 1)
        XCTAssertNotNil(recovered.transcription?.liveJournalSealedAt)
        XCTAssertEqual(recovered.turns, [
            TranscriptTurn(
                id: liveTurn.id,
                speaker: .participant,
                timestamp: 2,
                text: liveTurn.text
            )
        ])
    }

    func testCaptureFailureDoesNotOpenCall() async {
        let microphone = AudioSourceOption(
            id: "microphone:test",
            title: "Test Microphone",
            kind: .microphone(uniqueID: "test")
        )
        let capture = FakeAudioCaptureService(
            catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [microphone])
        )
        capture.startError = AudioCaptureError.microphonePermissionDenied
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: capture,
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )

        await model.refreshAudioSources()
        let didStart = await model.startCall()

        XCTAssertFalse(didStart)
        XCTAssertEqual(model.callState, .idle)
        XCTAssertNotNil(model.audioSetupError)
        XCTAssertEqual(capture.stopCount, 0)
    }

    func testRealtimeFailureIsSurfacedAndPersistedForBothTracks() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let microphone = AudioSourceOption(
            id: "microphone:test",
            title: "Test Microphone",
            kind: .microphone(uniqueID: "test")
        )
        let capture = FakeAudioCaptureService(
            catalog: AudioSourceCatalog(
                incoming: [.systemAudio],
                microphones: [microphone]
            )
        )
        let failure = RealtimeConnectionFailure(reason: .authentication)
        let incoming = FailingStartTranscriptionClient(failure: failure)
        let outgoing = FailingStartTranscriptionClient(failure: failure)
        let storage = RecordingStorageService(rootURL: rootURL)
        let userDefaults = isolatedUserDefaults()
        let settings = OpenAISettingsStore(
            userDefaults: userDefaults,
            secretStore: StaticTestSecretStore(secret: "unit-test-key")
        )
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            transcriptService: TranscriptFileService(documentsURL: rootURL),
            audioCaptureService: capture,
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: storage,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: settings,
            realtimeCoordinatorFactory: { spendAuthorizer in
                RealtimeTranscriptionCoordinator(
                    incomingClient: incoming,
                    outgoingClient: outgoing,
                    spendAuthorizer: spendAuthorizer
                )
            },
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )
        await model.refreshAudioSources()

        let didStart = await model.startCall()
        XCTAssertTrue(didStart)
        await waitUntil {
            model.incomingRealtimeFailure?.reason == .authentication
                && model.outgoingRealtimeFailure?.reason == .authentication
                && model.incomingRealtimeStatus == .failed
                && model.outgoingRealtimeStatus == .failed
        }

        XCTAssertEqual(model.incomingRealtimeStatus, .failed)
        XCTAssertEqual(model.outgoingRealtimeStatus, .failed)
        let capturing = try XCTUnwrap(storage.loadAll().first)
        XCTAssertEqual(
            capturing.transcription?.incomingRealtimeFailure?.reason,
            .authentication
        )
        XCTAssertEqual(
            capturing.transcription?.outgoingRealtimeFailure?.reason,
            .authentication
        )

        await model.finishCall()

        let persisted = try XCTUnwrap(storage.loadAll().first)
        XCTAssertEqual(
            persisted.transcription?.incomingRealtimeFailure?.reason,
            .authentication
        )
        XCTAssertEqual(
            persisted.transcription?.outgoingRealtimeFailure?.reason,
            .authentication
        )
        XCTAssertNil(model.incomingRealtimeFailure)
        XCTAssertNil(model.outgoingRealtimeFailure)
    }

    func testMissingPermissionsOpensOnboardingWithoutStartingCapture() async {
        let microphone = AudioSourceOption(
            id: "microphone:test",
            title: "Test Microphone",
            kind: .microphone(uniqueID: "test")
        )
        let capture = FakeAudioCaptureService(
            catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [microphone])
        )
        let permissions = FakeAudioPermissionService(authorized: false)
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: capture,
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: permissions,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )

        let didStart = await model.startCall()

        XCTAssertFalse(didStart)
        XCTAssertTrue(model.isAudioPermissionsPresented)
        XCTAssertTrue(capture.startRequests.isEmpty)
    }

    func testPermissionRequestUsesAcceptedResultWhilePreflightCatchesUp() async {
        let permissions = FakeAudioPermissionService(authorized: false)
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: permissions,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )

        await model.requestAudioPermission(.systemAudio)

        XCTAssertEqual(model.audioPermissions.systemAudio, .authorized)
    }

    func testDeniedSystemAudioRequestOpensTheCorrectSettingsPane() async {
        let permissions = FakeAudioPermissionService(
            authorized: false,
            requestResult: .denied
        )
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [])
            ),
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: permissions,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )

        await model.requestAudioPermission(.systemAudio)

        XCTAssertEqual(permissions.openedSettings, [.systemAudio])
    }

    func testBecomingActiveRefreshesDevicesEvenWhenPermissionsDidNotChange() async {
        let microphone = AudioSourceOption(
            id: "microphone:airpods",
            title: "Test AirPods",
            kind: .microphone(uniqueID: "airpods")
        )
        let capture = FakeAudioCaptureService(
            catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [microphone])
        )
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            audioCaptureService: capture,
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )

        model.applicationDidBecomeActive()
        for _ in 0..<20 where capture.discoverCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(capture.discoverCount, 1)
        XCTAssertEqual(model.outgoingSources, [microphone])
    }

    func testLeavingRecordingsStopsPlayback() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = Recording(
            title: "Playback",
            startedAt: Date(),
            duration: 5,
            folderName: "playback",
            turns: []
        )
        let storage = RecordingStorageService(rootURL: rootURL)
        let urls = try storage.audioURLs(for: recording)
        try FileManager.default.createDirectory(
            at: urls.combined.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: urls.combined)
        let playback = FakeAudioPlaybackService()
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [])
            ),
            audioPlaybackService: playback,
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: storage,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: [recording]
        )

        model.setScreen(.recordings)
        model.togglePlayback(for: recording)
        XCTAssertEqual(model.playingRecordingID, recording.id)

        model.setScreen(.contexts)

        XCTAssertNil(model.playingRecordingID)
        XCTAssertEqual(playback.stopCount, 1)
    }

    func testSeekingActiveRecordingClampsAndDelegatesProgress() throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let recording = Recording(
            title: "Playback",
            startedAt: Date(),
            duration: 60,
            folderName: "playback-seek",
            turns: []
        )
        let storage = RecordingStorageService(rootURL: rootURL)
        let urls = try storage.audioURLs(for: recording)
        try FileManager.default.createDirectory(
            at: urls.combined.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("audio".utf8).write(to: urls.combined)
        let playback = FakeAudioPlaybackService()
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            audioCaptureService: FakeAudioCaptureService(
                catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [])
            ),
            audioPlaybackService: playback,
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: storage,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: [recording]
        )

        model.seekPlayback(for: recording, toProgress: 0.25)
        XCTAssertTrue(playback.seekProgresses.isEmpty)

        model.togglePlayback(for: recording)
        model.seekPlayback(for: recording, toProgress: 0.25)
        XCTAssertEqual(model.playbackElapsedTime, 25)
        XCTAssertEqual(model.playbackDuration, 100)
        XCTAssertEqual(model.playbackProgress, 0.25)

        let otherRecording = Recording(
            title: "Other playback",
            startedAt: Date(),
            duration: 30,
            folderName: "other-playback-seek",
            turns: []
        )
        model.seekPlayback(for: otherRecording, toProgress: 0.75)
        model.seekPlayback(for: recording, toProgress: .nan)
        model.seekPlayback(for: recording, toProgress: -1)
        model.seekPlayback(for: recording, toProgress: 2)

        XCTAssertEqual(playback.seekProgresses, [0.25, 0, 1])
    }

    func testPartialCaptureDoesNotPretendToHaveACombinedTrack() async throws {
        let rootURL = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let microphone = AudioSourceOption(
            id: "microphone:test",
            title: "Test Microphone",
            kind: .microphone(uniqueID: "test")
        )
        let capture = FakeAudioCaptureService(
            catalog: AudioSourceCatalog(incoming: [.systemAudio], microphones: [microphone])
        )
        capture.stopResult = CapturedAudioFiles(
            incomingFilename: "incoming.m4a",
            outgoingFilename: nil,
            combinedFilename: nil,
            warnings: [.outgoing("аудиоданные не получены")]
        )
        let storage = RecordingStorageService(rootURL: rootURL)
        let userDefaults = isolatedUserDefaults()
        let model = AppModel(
            engine: DemoCallEngine(automaticUpdatesEnabled: false),
            transcriptService: TranscriptFileService(documentsURL: rootURL),
            audioCaptureService: capture,
            audioPlaybackService: FakeAudioPlaybackService(),
            audioPermissionService: FakeAudioPermissionService(authorized: true),
            recordingStorage: storage,
            contextLibraryStore: isolatedContextLibraryStore(),
            openAISettings: isolatedOpenAISettings(userDefaults: userDefaults),
            reconciliationCredentialProviderFactory: { EmptyTestCredentialProvider() },
            finalAnalysisCredentialProviderFactory: { EmptyTestCredentialProvider() },
            userDefaults: userDefaults,
            recordings: []
        )

        await model.refreshAudioSources()
        let didStart = await model.startCall()
        XCTAssertTrue(didStart)
        await model.finishCall()

        let recording = try XCTUnwrap(model.recordings.first)
        XCTAssertEqual(model.availableAudioExports(for: recording), [.incoming])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("AI Call Assistant", isDirectory: true)
    }

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "AppModelAudioTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func isolatedContextLibraryStore() -> ContextLibraryStore {
        ContextLibraryStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AppModelAudioTests.ContextLibrary.\(UUID().uuidString)",
                    isDirectory: true
                )
        )
    }

    private func isolatedOpenAISettings(
        userDefaults: UserDefaults
    ) -> OpenAISettingsStore {
        OpenAISettingsStore(
            userDefaults: userDefaults,
            secretStore: EmptyTestSecretStore()
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let step: UInt64 = 5_000_000
        var elapsed: UInt64 = 0
        while elapsed < timeoutNanoseconds {
            if condition() { return }
            try? await Task.sleep(nanoseconds: step)
            elapsed += step
        }
        XCTFail("Timed out waiting for AppModel recovery")
    }

    private func eventuallyAsync(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .nanoseconds(Int64(clamping: timeoutNanoseconds))
        )
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private struct EmptyTestSecretStore: SecretStore {
    func readSecret(for identifier: SecretIdentifier) throws -> String? { nil }
    func writeSecret(_ secret: String, for identifier: SecretIdentifier) throws {}
    func deleteSecret(for identifier: SecretIdentifier) throws {}
}

private struct StaticTestSecretStore: SecretStore {
    let secret: String?

    func readSecret(for identifier: SecretIdentifier) throws -> String? { secret }
    func writeSecret(_ secret: String, for identifier: SecretIdentifier) throws {}
    func deleteSecret(for identifier: SecretIdentifier) throws {}
}

private actor RecordingContextFileTextExtractor: ContextFileTextExtracting {
    struct CapturedRequest: Sendable {
        let input: ContextFileExtractionInput
        let apiKey: String
        let modelID: String
    }

    private let output: String
    private var captured: CapturedRequest?

    init(output: String) {
        self.output = output
    }

    func extractText(
        from input: ContextFileExtractionInput,
        apiKey: String,
        modelID: String
    ) async throws -> String {
        captured = CapturedRequest(input: input, apiKey: apiKey, modelID: modelID)
        return output
    }

    func capturedRequest() -> CapturedRequest? {
        captured
    }
}

private actor StartCallResultProbe {
    private(set) var result: Bool?

    func set(_ result: Bool) {
        self.result = result
    }
}

private actor GatedStartTranscriptionClient: RealtimeTranscriptionClientProtocol {
    nonisolated let signals: AsyncStream<RealtimeClientSignal>
    private nonisolated let continuation: AsyncStream<RealtimeClientSignal>.Continuation
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var connectCount = 0

    init() {
        let pair = AsyncStream<RealtimeClientSignal>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        signals = pair.stream
        continuation = pair.continuation
    }

    func connect(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async throws -> RealtimeClientConnection {
        connectCount += 1
        let connectionID = UInt64(connectCount)
        await withCheckedContinuation { continuation in
            connectionWaiters.append(continuation)
        }
        continuation.yield(
            .server(connectionID: connectionID, .sessionUpdated(expiresAt: nil))
        )
        return RealtimeClientConnection(id: connectionID, expiresAt: nil)
    }

    func appendPCM16(_ data: Data) async throws {}
    func commit(eventID: String) async throws {}
    func disconnect() async {}

    func releaseConnections() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor FailingStartTranscriptionClient: RealtimeTranscriptionClientProtocol {
    nonisolated let signals: AsyncStream<RealtimeClientSignal>
    private let failure: RealtimeConnectionFailure

    init(failure: RealtimeConnectionFailure) {
        self.failure = failure
        signals = AsyncStream { continuation in
            continuation.finish()
        }
    }

    func connect(
        apiKey: String,
        configuration: RealtimeTranscriptionConfiguration
    ) async throws -> RealtimeClientConnection {
        throw failure
    }

    func appendPCM16(_ data: Data) async throws {}
    func commit(eventID: String) async throws {}
    func disconnect() async {}
}

private struct EmptyTestCredentialProvider:
    ReconciliationCredentialProvider,
    FinalAnalysisCredentialProvider
{
    func currentAPIKey() async throws -> String? { nil }
}

@MainActor
private final class FakeAudioCaptureService: AudioCaptureService {
    let catalog: AudioSourceCatalog
    var discoverCount = 0
    var startRequests: [AudioCaptureRequest] = []
    var stopCount = 0
    var startError: Error?
    var stopResult = CapturedAudioFiles(
        incomingFilename: "incoming.m4a",
        outgoingFilename: "outgoing.m4a",
        combinedFilename: "combined.m4a"
    )
    private var activeFolderURL: URL?

    init(catalog: AudioSourceCatalog) {
        self.catalog = catalog
    }

    func discoverSources() async throws -> AudioSourceCatalog {
        discoverCount += 1
        return catalog
    }

    func start(
        _ request: AudioCaptureRequest,
        liveAudioSink: LiveAudioSampleSink?
    ) async throws {
        if let startError { throw startError }
        startRequests.append(request)
        activeFolderURL = request.folderURL
        try FileManager.default.createDirectory(at: request.folderURL, withIntermediateDirectories: true)
    }

    func stop() async throws -> CapturedAudioFiles {
        stopCount += 1
        guard let activeFolderURL else { throw AudioCaptureError.notRecording }
        let filenames = [
            stopResult.incomingFilename,
            stopResult.outgoingFilename,
            stopResult.combinedFilename
        ].compactMap { $0 }
        for filename in filenames {
            try Data("test audio".utf8).write(
                to: activeFolderURL.appendingPathComponent(filename),
                options: .atomic
            )
        }
        return stopResult
    }
}

@MainActor
private final class FakeAudioPlaybackService: AudioPlaybackService {
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?
    var onFinish: (() -> Void)?
    var stopCount = 0
    var seekProgresses: [Double] = []

    func play(url: URL) throws {}
    func seek(toProgress progress: Double) {
        seekProgresses.append(progress)
        onProgress?(progress * 100, 100)
    }
    func stop() { stopCount += 1 }
}

@MainActor
private final class FakeAudioPermissionService: AudioPermissionService {
    var snapshot: AudioPermissionSnapshot
    var requestResult: AudioPermissionStatus
    var openedSettings: [AudioPermissionKind] = []

    init(
        authorized: Bool,
        requestResult: AudioPermissionStatus = .authorized
    ) {
        let status: AudioPermissionStatus = authorized ? .authorized : .notDetermined
        snapshot = AudioPermissionSnapshot(microphone: status, systemAudio: status)
        self.requestResult = requestResult
    }

    func currentSnapshot() -> AudioPermissionSnapshot {
        snapshot
    }

    func request(_ kind: AudioPermissionKind) async -> AudioPermissionStatus {
        requestResult
    }

    func openSettings(for kind: AudioPermissionKind) {
        openedSettings.append(kind)
    }
}
