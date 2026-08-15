import SwiftUI

struct AppShellView: View {
    @ObservedObject var model: AppModel
    @StateObject private var livePanelCoordinator = LivePanelCoordinator()

    var body: some View {
        HStack(spacing: 0) {
            AppSidebarView(
                screen: $model.screen,
                recordingCount: model.recordings.count
            )
            .frame(width: 236)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 930, minHeight: 650)
        .background(AssistantTheme.windowBackground)
        .tint(AssistantTheme.accent)
        .sheet(isPresented: $model.isContextEditorPresented) {
            ContextEditorView(context: model.editingContext) { title, body in
                model.saveContext(title: title, body: body)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toastMessage {
                ToastView(message: toast)
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toastMessage)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.screen {
        case .setup:
            SetupView(
                incomingSource: $model.incomingSource,
                outgoingSource: $model.outgoingSource,
                incomingSources: model.incomingSources,
                outgoingSources: model.outgoingSources,
                contexts: model.contexts,
                onToggleContextSelection: model.toggleContext,
                onCreateContext: model.createContext,
                onOpenContext: model.openContext,
                onDeleteContext: model.deleteContext,
                onSelectAllContexts: model.selectAllContexts,
                onClearContextSelection: model.clearContextSelection,
                onStartCall: { livePanelCoordinator.begin(with: model) }
            )

        case .recordings:
            RecordingsView(
                recordings: model.recordings,
                selectedRecordingID: $model.selectedRecordingID,
                storagePath: model.storagePath,
                playingRecordingID: model.playingRecordingID,
                onTogglePlayback: model.togglePlayback,
                onDownload: model.download,
                onOpenTranscript: model.openTranscript,
                onRevealTranscript: model.revealTranscript
            )
        }
    }
}

@MainActor
private final class LivePanelCoordinator: ObservableObject {
    private let controller = LivePanelController()

    func begin(with model: AppModel) {
        guard !controller.isPresented else { return }

        model.startCall()
        controller.present(
            rootView: LivePanelRoot(model: model) { [weak self] in
                self?.controller.finish()
            },
            onFinish: { [weak model] in
                model?.finishCall()
            }
        )
    }
}

private struct LivePanelRoot: View {
    @ObservedObject var model: AppModel
    let onEndCall: () -> Void

    var body: some View {
        LiveAssistantView(
            incomingSource: model.incomingSource,
            outgoingSource: model.outgoingSource,
            selectedContextCount: model.contexts.lazy.filter(\.isSelected).count,
            elapsedTime: model.elapsedTime,
            currentMoment: model.currentMoment,
            answerHistory: model.answerHistory,
            onEndCall: onEndCall
        )
    }
}
