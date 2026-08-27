import AppKit
import SwiftUI

struct AppShellView: View {
    @ObservedObject var model: AppModel
    @StateObject private var livePanelCoordinator = LivePanelCoordinator()
    @State private var isRecordingsPresented = false
    @State private var isRecordingDetailPresented = false
    @State private var isSettingsPresented = false
    @State private var returnToRecordingsAfterDetail = false

    var body: some View {
        Group {
            if isSettingsPresented {
                settingsRoot
            } else {
                setupRoot
            }
        }
        // One stable, near-square composition. The 32 pt native safe-area /
        // titlebar allowance makes the complete window 900×800.
        .frame(width: 900, height: 768)
        .background {
            MainWindowTheme.canvas
                .ignoresSafeArea()
        }
        .background(MainWindowBackdrop())
        .ignoresSafeArea(.container, edges: .top)
        .tint(MainWindowTheme.primaryAction)
        .sheet(isPresented: $model.isContextEditorPresented) {
            ContextEditorView(
                context: model.editingContext,
                onExtractFile: { url in
                    try await model.extractContextFile(at: url)
                },
                onSave: { title, body, attachments in
                    model.saveContext(
                        title: title,
                        body: body,
                        attachments: attachments
                    )
                }
            )
        }
        .sheet(
            isPresented: $isRecordingDetailPresented,
            onDismiss: reopenRecordingsIfNeeded
        ) {
            recordingDetail
        }
        .sheet(isPresented: $model.isAudioPermissionsPresented) {
            AudioPermissionsOnboardingView(
                permissions: model.audioPermissions,
                requestingPermission: model.requestingAudioPermission,
                onRequest: model.requestAudioPermission,
                onOpenSettings: model.openAudioPermissionSettings,
                onRefresh: model.refreshAudioPermissions,
                onComplete: model.completeAudioPermissionsOnboarding
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.applicationDidBecomeActive()
        }
        .onAppear {
            ApplicationTerminationCoordinator.shared.model = model
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toastMessage {
                ToastView(message: toast)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toastMessage)
    }

    private var setupRoot: some View {
        SetupView(
            incomingSource: $model.incomingSource,
            outgoingSource: $model.outgoingSource,
            incomingSources: model.incomingSources,
            outgoingSources: model.outgoingSources,
            contexts: model.contexts,
            recordings: model.recordings,
            isDiscoveringAudioSources: model.isDiscoveringAudioSources,
            isPreparingAudio: model.isPreparingAudio,
            isFinalizingAudio: model.isFinalizingAudio,
            isCallRunning: model.callState == .running,
            audioSetupError: model.audioSetupError,
            audioPermissions: model.audioPermissions,
            openAICredentialState: model.openAISettings.credentialState,
            isRecordingsPresented: $isRecordingsPresented,
            onToggleContextSelection: model.toggleContext,
            onCreateContext: model.createContext,
            onOpenContext: model.openContext,
            onDeleteContext: model.deleteContext,
            onRefreshAudioSources: model.refreshAudioSources,
            onOpenAudioPermissions: model.presentAudioPermissions,
            onOpenSettings: { isSettingsPresented = true },
            onOpenRecording: openRecording,
            onStartCall: { livePanelCoordinator.begin(with: model) }
        )
    }

    private var settingsRoot: some View {
        VStack(spacing: 0) {
            settingsTitlebar

            AppSettingsView(
                store: model.openAISettings,
                presentation: .embedded
            )
        }
        .background(MainWindowTheme.canvas)
    }

    private var settingsTitlebar: some View {
        MainWindowTitlebar {
            Button {
                isSettingsPresented = false
            } label: {
                Image(systemName: "phone")
                    .frame(
                        width: MainWindowTheme.toolbarControlSize,
                        height: MainWindowTheme.toolbarControlSize
                    )
            }
            .buttonStyle(MainWindowToolbarButtonStyle())
            .help("Новый звонок")
            .accessibilityLabel("Вернуться к новому звонку")
        }
    }

    private func openRecording(_ recording: Recording) {
        model.selectRecording(recording.id)
        returnToRecordingsAfterDetail = true
        isRecordingsPresented = false
        DispatchQueue.main.async {
            isRecordingDetailPresented = true
        }
    }

    private func reopenRecordingsIfNeeded() {
        guard returnToRecordingsAfterDetail else { return }
        returnToRecordingsAfterDetail = false
        DispatchQueue.main.async {
            isRecordingsPresented = true
        }
    }

    private var recordingDetail: some View {
        RecordingsView(
            recordings: model.recordings,
            selectedRecordingID: Binding(
                get: { model.selectedRecordingID },
                set: { model.selectRecording($0) }
            ),
            storagePath: model.storagePath,
            playingRecordingID: model.playingRecordingID,
            playbackElapsedTime: model.playbackElapsedTime,
            playbackDuration: model.playbackDuration,
            playbackProgress: model.playbackProgress,
            availableAudioExports: model.availableAudioExports,
            loadFinalAnalysis: { recording in
                try await model.loadFinalAnalysis(for: recording)
            },
            onTogglePlayback: model.togglePlayback,
            onSeekPlayback: model.seekPlayback,
            onDownload: model.download,
            onOpenTranscript: model.openTranscript,
            onRevealTranscript: model.revealTranscript,
            onRetryPostCallProcessing: { recording in
                Task { await model.retryPostCallProcessing(for: recording) }
            },
            presentation: .detail,
            onClose: {
                model.stopRecordingPlayback()
                isRecordingDetailPresented = false
            }
        )
        .frame(
            minWidth: 680,
            idealWidth: 900,
            maxWidth: 960,
            minHeight: 600,
            idealHeight: 680
        )
    }
}

private struct MainWindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindow(for: nsView)
    }

    private func updateWindow(for view: NSView) {
        DispatchQueue.main.async {
            view.window?.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 28 / 255, alpha: 1)
                    : NSColor(srgbRed: 244 / 255, green: 244 / 255, blue: 241 / 255, alpha: 1)
            }
        }
    }
}

@MainActor
private final class LivePanelCoordinator: ObservableObject {
    private let controller = LivePanelController()
    private var startTask: Task<Void, Never>?

    func begin(with model: AppModel) {
        guard !controller.isPresented, startTask == nil else { return }

        startTask = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            let didStart = await model.startCall()
            self.startTask = nil
            guard didStart else { return }

            self.controller.present(
                rootView: LivePanelRoot(model: model) { [weak self] in
                    self?.controller.finish()
                },
                onFinish: { [weak model] in
                    Task { @MainActor in
                        await model?.finishCall()
                    }
                }
            )
        }
    }
}

private struct LivePanelRoot: View {
    @ObservedObject var model: AppModel
    let onEndCall: () -> Void

    var body: some View {
        LiveAssistantView(
            incomingSource: model.incomingSource.title,
            outgoingSource: model.outgoingSource.title,
            selectedContextCount: model.contexts.lazy.filter(\.isSelected).count,
            elapsedTime: model.elapsedTime,
            currentMoment: model.currentMoment,
            answerHistory: model.answerHistory,
            transcriptTurns: model.liveTranscriptTurns,
            incomingStatus: model.incomingRealtimeStatus,
            outgoingStatus: model.outgoingRealtimeStatus,
            incomingFailure: model.incomingRealtimeFailure,
            outgoingFailure: model.outgoingRealtimeFailure,
            guidanceStatus: model.liveGuidanceStatus,
            onEndCall: onEndCall
        )
    }
}
