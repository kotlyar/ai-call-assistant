import SwiftUI

enum RecordingsChrome {
    static let sidebar = AssistantTheme.sidebarBackground
    static let sidebarHover = AssistantTheme.rowHover
    static let sidebarSelection = AssistantTheme.accentSoft
    static let sidebarSeparator = AssistantTheme.contentHairline
    static let sidebarPrimary = Color.primary
    static let sidebarSecondary = AssistantTheme.secondaryText
}

struct RecordingsView: View {
    enum Presentation {
        case library
        case detail
    }

    private enum DetailTab: String, CaseIterable, Identifiable {
        case transcript = "Транскрипт"
        case analysis = "AI-анализ"
        case files = "Файлы"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .transcript: "text.alignleft"
            case .analysis: "sparkles"
            case .files: "folder"
            }
        }
    }

    let recordings: [Recording]
    @Binding var selectedRecordingID: UUID?
    let storagePath: String
    let playingRecordingID: UUID?
    let playbackElapsedTime: TimeInterval
    let playbackDuration: TimeInterval
    let playbackProgress: Double
    let availableAudioExports: (Recording) -> Set<RecordingAudioExport>
    let loadFinalAnalysis: (Recording) async throws -> FinalAnalysisPublishedResult?

    let onTogglePlayback: (Recording) -> Void
    let onSeekPlayback: (Recording, Double) -> Void
    let onDownload: (Recording, RecordingAudioExport) -> Void
    let onOpenTranscript: (Recording) -> Void
    let onRevealTranscript: (Recording) -> Void
    let onRetryPostCallProcessing: ((Recording) -> Void)?
    let presentation: Presentation
    let onClose: (() -> Void)?

    @State private var finalAnalysisCards: [FinalQuestionAnswerCard] = []
    @State private var loadedFinalAnalysisRecordingID: UUID?
    @State private var isLoadingFinalAnalysis = false
    @State private var didFailToLoadFinalAnalysis = false
    @State private var searchText = ""
    @State private var selectedDetailTab: DetailTab = .transcript

    init(
        recordings: [Recording],
        selectedRecordingID: Binding<UUID?>,
        storagePath: String,
        playingRecordingID: UUID?,
        playbackElapsedTime: TimeInterval,
        playbackDuration: TimeInterval,
        playbackProgress: Double,
        availableAudioExports: @escaping (Recording) -> Set<RecordingAudioExport>,
        loadFinalAnalysis: @escaping (Recording) async throws -> FinalAnalysisPublishedResult?,
        onTogglePlayback: @escaping (Recording) -> Void,
        onSeekPlayback: @escaping (Recording, Double) -> Void,
        onDownload: @escaping (Recording, RecordingAudioExport) -> Void,
        onOpenTranscript: @escaping (Recording) -> Void,
        onRevealTranscript: @escaping (Recording) -> Void,
        onRetryPostCallProcessing: ((Recording) -> Void)?,
        presentation: Presentation = .library,
        onClose: (() -> Void)? = nil
    ) {
        self.recordings = recordings
        _selectedRecordingID = selectedRecordingID
        self.storagePath = storagePath
        self.playingRecordingID = playingRecordingID
        self.playbackElapsedTime = playbackElapsedTime
        self.playbackDuration = playbackDuration
        self.playbackProgress = playbackProgress
        self.availableAudioExports = availableAudioExports
        self.loadFinalAnalysis = loadFinalAnalysis
        self.onTogglePlayback = onTogglePlayback
        self.onSeekPlayback = onSeekPlayback
        self.onDownload = onDownload
        self.onOpenTranscript = onOpenTranscript
        self.onRevealTranscript = onRevealTranscript
        self.onRetryPostCallProcessing = onRetryPostCallProcessing
        self.presentation = presentation
        self.onClose = onClose
    }

    var body: some View {
        Group {
            switch presentation {
            case .library:
                VStack(spacing: 0) {
                    toolbar
                    Hairline()

                    HStack(spacing: 0) {
                        recordingList
                        Hairline(axis: .vertical, color: AssistantTheme.sidebarEdge)
                        recordingDetail
                    }
                }

            case .detail:
                VStack(spacing: 0) {
                    HStack {
                        Text("Запись разговора")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if let onClose {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(QuietButtonStyle())
                            .help("Закрыть")
                            .accessibilityLabel("Закрыть запись")
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 48)
                    .background(MainWindowTheme.canvas)

                    Hairline()
                    recordingDetail
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MainWindowTheme.canvas)
        .navigationTitle("Записи")
        .onAppear {
            if selectedRecordingID == nil {
                selectedRecordingID = recordings.first?.id
            }
        }
        .task(id: finalAnalysisLoadID) {
            await loadSelectedFinalAnalysis()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Записи")
                .font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            Text(recordingCountText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            searchField
                .frame(width: 230)
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .background(AssistantTheme.surface)
    }

    private var recordingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(searchQuery.isEmpty ? "Все записи" : "Результаты")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(filteredRecordings.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)

            Hairline()

            if filteredRecordings.isEmpty {
                listEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredRecordings) { recording in
                            Button {
                                selectedRecordingID = recording.id
                            } label: {
                                RecordingListRow(
                                    recording: recording,
                                    isSelected: selectedRecording?.id == recording.id
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Показывает эту запись")

                            Hairline(color: RecordingsChrome.sidebarSeparator)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .frame(width: 294)
        .background(RecordingsChrome.sidebar)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Поиск", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Поиск записей")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(AssistantTheme.subtleSurface)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(AssistantTheme.separator)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var listEmptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: searchQuery.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(searchQuery.isEmpty ? "Записей пока нет" : "Ничего не найдено")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)

            if !searchQuery.isEmpty {
                Text("Измените запрос")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var recordingDetail: some View {
        if let recording = selectedRecording {
            let presentation = RecordingPostCallPresentation.make(for: recording)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    recordingDetailHeader(recording, presentation: presentation)

                    RecordingAudioRow(
                        duration: recording.duration,
                        isPlaying: playingRecordingID == recording.id,
                        elapsedTime: playingRecordingID == recording.id ? playbackElapsedTime : 0,
                        playbackDuration: playingRecordingID == recording.id ? playbackDuration : 0,
                        playbackProgress: playingRecordingID == recording.id ? playbackProgress : 0,
                        availableExports: availableAudioExports(recording),
                        onTogglePlayback: { onTogglePlayback(recording) },
                        onSeek: { onSeekPlayback(recording, $0) },
                        onDownload: { onDownload(recording, $0) }
                    )
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 14)

                detailTabBar
                Hairline()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        detailTabContent(recording: recording, presentation: presentation)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(AssistantTheme.canvas)
        } else {
            emptyState
        }
    }

    private var detailTabBar: some View {
        HStack(spacing: 24) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    selectedDetailTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .accessibilityHidden(true)

                        Text(tab.rawValue)
                    }
                    .font(.system(size: 12, weight: selectedDetailTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedDetailTab == tab ? .primary : .secondary)
                    .frame(height: 35)
                    .overlay(alignment: .bottom) {
                        if selectedDetailTab == tab {
                            Rectangle()
                                .fill(AssistantTheme.accent)
                                .frame(height: 2)
                        }
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityAddTraits(selectedDetailTab == tab ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Раздел записи")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            Text(recordings.isEmpty ? "Записей пока нет" : "Выберите запись")
                .font(.headline)

            Text(recordings.isEmpty
                ? "После первого звонка здесь появятся аудио, транскрипт и AI-анализ."
                : "Выберите разговор в списке слева, чтобы открыть его материалы."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AssistantTheme.canvas)
        .accessibilityElement(children: .combine)
    }

    private func recordingDetailHeader(
        _ recording: Recording,
        presentation: RecordingPostCallPresentation
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(AssistantTheme.accent)
                .frame(width: 58, height: 58)
                .background(
                    AssistantTheme.accentSoft,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AssistantTheme.contentHairline)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(recording.title)
                    .font(.system(size: 25, weight: .semibold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 7) {
                    Label(recordingMetadata(recording), systemImage: "calendar")

                    if !recording.turns.isEmpty {
                        Text("·")
                        Label(participantDescription(for: recording), systemImage: "person.2")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RecordingProcessingBadge(label: presentation.overallLabel)
        }
    }

    private func participantDescription(for recording: Recording) -> String {
        let count = participantCount(for: recording)
        switch count {
        case 1: return "1 участник"
        case 2...4: return "\(count) участника"
        default: return "\(count) участников"
        }
    }

    private var selectedRecording: Recording? {
        if let selectedRecordingID,
           let selected = filteredRecordings.first(where: { $0.id == selectedRecordingID }) {
            return selected
        }
        return presentation == .library ? filteredRecordings.first : nil
    }

    private var filteredRecordings: [Recording] {
        guard !searchQuery.isEmpty else { return recordings }
        return recordings.filter { recording in
            recording.title.localizedCaseInsensitiveContains(searchQuery)
                || recording.folderName.localizedCaseInsensitiveContains(searchQuery)
                || recording.turns.contains {
                    $0.text.localizedCaseInsensitiveContains(searchQuery)
                }
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recordingCountText: String {
        if !searchQuery.isEmpty {
            return "Найдено: \(filteredRecordings.count) из \(recordings.count)"
        }

        switch recordings.count {
        case 1: return "1 запись"
        case 2...4: return "\(recordings.count) записи"
        default: return "\(recordings.count) записей"
        }
    }

    private func recordingMetadata(_ recording: Recording) -> String {
        let date = recording.startedAt.formatted(
            .dateTime.day().month(.wide).year().hour().minute()
        )
        return "\(date) · \(RecordingListRow.durationText(recording.duration))"
    }

    @ViewBuilder
    private func detailTabContent(
        recording: Recording,
        presentation: RecordingPostCallPresentation
    ) -> some View {
        switch selectedDetailTab {
        case .transcript:
            transcriptSection(recording)

        case .analysis:
            if let analysisStatus = presentation.finalAnalysis {
                finalAnalysisSection(recording: recording, status: analysisStatus)
            } else {
                unavailableDetail(
                    title: "AI-анализ пока недоступен",
                    detail: "Он появится после обработки транскрипта."
                )
            }

        case .files:
            filesSection(recording: recording, presentation: presentation)
        }
    }

    private func transcriptSection(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if recording.turns.isEmpty {
                unavailableDetail(
                    title: "Транскрипт пока пуст",
                    detail: "Откройте вкладку «Файлы», чтобы проверить статус обработки."
                )
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Расшифровка разговора")
                        .font(.system(size: 14, weight: .semibold))

                    Spacer()

                    Text("\(recording.turns.count) реплик")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                LazyVStack(spacing: 0) {
                    ForEach(recording.turns) { turn in
                        transcriptTurnRow(turn)
                        Hairline()
                            .padding(.leading, 106)
                    }
                }
            }
        }
    }

    private func transcriptTurnRow(_ turn: TranscriptTurn) -> some View {
        let isQuestion = turn.speaker == .participant && turn.text.contains("?")

        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.speaker.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        turn.speaker == .participant
                            ? AssistantTheme.accent
                            : AssistantTheme.secondaryText
                    )
                Text(RecordingListRow.durationText(turn.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 92, alignment: .leading)

            Text(turn.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 11)
        .background(isQuestion ? AssistantTheme.accentSoft.opacity(0.62) : Color.clear)
        .overlay(alignment: .leading) {
            if isQuestion {
                Rectangle()
                    .fill(AssistantTheme.accent)
                    .frame(width: 2)
            }
        }
    }

    private func filesSection(
        recording: Recording,
        presentation: RecordingPostCallPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TranscriptFileRow(
                participantCount: participantCount(for: recording),
                status: presentation.transcription,
                onRetry: recording.transcription?.reconciliationStatus == .complete
                    ? nil
                    : retryAction(for: recording, presentation: presentation),
                onOpen: { onOpenTranscript(recording) },
                onRevealInFinder: { onRevealTranscript(recording) }
            )

            Label {
                Text("\(storagePath)/\(recording.folderName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "folder")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .help("\(storagePath)/\(recording.folderName)")
        }
    }

    private func unavailableDetail(title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(AssistantTheme.subtleSurface)
        .overlay { Rectangle().stroke(AssistantTheme.contentHairline) }
    }

    private var finalAnalysisLoadID: String {
        guard let recording = selectedRecording,
              let metadata = recording.transcription else {
            return "none"
        }
        return [
            recording.id.uuidString,
            String(metadata.canonicalRevision ?? -1),
            metadata.canonicalTranscriptSHA256 ?? "no-canonical-hash",
            metadata.finalAnalysisStatus.rawValue,
            metadata.finalAnalysisResultPointer?.analysisHash ?? "no-analysis-pointer"
        ].joined(separator: ":")
    }

    @ViewBuilder
    private func finalAnalysisSection(
        recording: Recording,
        status: RecordingArtifactStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Итоговые вопросы и ответы")
                .font(.headline)

            if status.label != .ready {
                FinalAnalysisStatusRow(
                    status: status,
                    onRetry: recording.transcription?.reconciliationStatus == .complete
                        ? retryAction(for: recording, presentation: .make(for: recording))
                        : nil
                )
            } else if isLoadingFinalAnalysis {
                FinalAnalysisStatusRow(
                    status: RecordingArtifactStatus(
                        label: .processing,
                        detail: "Загружаем итоговый анализ"
                    ),
                    onRetry: nil
                )
            } else if didFailToLoadFinalAnalysis {
                FinalAnalysisStatusRow(
                    status: RecordingArtifactStatus(
                        label: .failed,
                        detail: "Не удалось прочитать сохранённый итоговый анализ"
                    ),
                    onRetry: finalAnalysisReadRetryAction(for: recording)
                )
            } else if loadedFinalAnalysisRecordingID == recording.id {
                if finalAnalysisCards.isEmpty {
                    FinalAnalysisStatusRow(
                        status: RecordingArtifactStatus(
                            label: .ready,
                            detail: "В разговоре не найдено вопросов собеседника"
                        ),
                        onRetry: nil
                    )
                } else {
                    ForEach(finalAnalysisCards) { card in
                        FinalQuestionAnswerCardView(card: card)
                    }
                }
            } else {
                FinalAnalysisStatusRow(status: status, onRetry: nil)
            }
        }
    }

    private func retryAction(
        for recording: Recording,
        presentation: RecordingPostCallPresentation
    ) -> (() -> Void)? {
        guard presentation.canRetryPostCallProcessing,
              let onRetryPostCallProcessing else {
            return nil
        }
        return { onRetryPostCallProcessing(recording) }
    }

    private func finalAnalysisReadRetryAction(
        for recording: Recording
    ) -> (() -> Void)? {
        guard let onRetryPostCallProcessing else { return nil }
        return { onRetryPostCallProcessing(recording) }
    }

    @MainActor
    private func loadSelectedFinalAnalysis() async {
        finalAnalysisCards = []
        loadedFinalAnalysisRecordingID = nil
        didFailToLoadFinalAnalysis = false
        isLoadingFinalAnalysis = false

        guard let recording = selectedRecording,
              let metadata = recording.transcription,
              metadata.reconciliationStatus == .complete,
              metadata.finalAnalysisStatus == .complete else {
            return
        }

        let requestedRecordingID = recording.id
        isLoadingFinalAnalysis = true
        defer { isLoadingFinalAnalysis = false }

        do {
            let published = try await loadFinalAnalysis(recording)
            guard !Task.isCancelled,
                  selectedRecording?.id == requestedRecordingID else {
                return
            }
            finalAnalysisCards = published?.artifact.cards ?? []
            loadedFinalAnalysisRecordingID = requestedRecordingID
            didFailToLoadFinalAnalysis = published == nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  selectedRecording?.id == requestedRecordingID else {
                return
            }
            didFailToLoadFinalAnalysis = true
        }
    }

    private func participantCount(for recording: Recording) -> Int {
        Set(recording.turns.map(\.speaker)).count
    }
}
