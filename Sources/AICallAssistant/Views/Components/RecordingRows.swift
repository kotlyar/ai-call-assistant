import SwiftUI

enum RecordingAudioExport: String, CaseIterable, Hashable, Identifiable {
    case combined
    case incoming
    case outgoing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combined: "Общую запись"
        case .incoming: "Звук собеседника"
        case .outgoing: "Мой микрофон"
        }
    }

    var filename: String {
        "\(rawValue).m4a"
    }

    var detail: String {
        switch self {
        case .combined: "обе стороны"
        case .incoming: "собеседник"
        case .outgoing: "ваш микрофон"
        }
    }

    var systemImage: String {
        switch self {
        case .combined: "arrow.down.circle"
        case .incoming: "speaker.wave.2"
        case .outgoing: "mic"
        }
    }
}

struct RecordingAudioRow: View {
    let duration: TimeInterval
    let isPlaying: Bool
    let elapsedTime: TimeInterval
    let playbackDuration: TimeInterval
    let playbackProgress: Double
    let availableExports: Set<RecordingAudioExport>
    let onTogglePlayback: () -> Void
    let onSeek: (Double) -> Void
    let onDownload: (RecordingAudioExport) -> Void

    @State private var isHovering = false
    @State private var scrubProgress: Double?

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPlaying ? Color.white : AssistantTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        isPlaying ? AssistantTheme.accent : AssistantTheme.accentSoft,
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(availableExports.isEmpty)
            .accessibilityLabel(isPlaying ? "Приостановить запись" : "Воспроизвести запись")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AssistantTheme.accent)
                        .accessibilityHidden(true)

                    Text(primaryAudioTitle)
                        .font(.caption.weight(.medium))

                    Spacer()

                    Text(showsElapsedTime ? "\(elapsedText) / \(durationText)" : durationText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                GeometryReader { proxy in
                    WaveformView(progress: displayedProgress)
                        .contentShape(Rectangle())
                        .gesture(seekGesture(width: proxy.size.width))
                }
                .frame(height: 20)
                .allowsHitTesting(isPlaying)
                .help(isPlaying
                    ? "Нажмите или перетащите, чтобы перемотать"
                    : "Запустите воспроизведение, чтобы перемотать"
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Позиция воспроизведения")
                .accessibilityValue("\(elapsedText) из \(durationText)")
                .accessibilityHint(isPlaying
                    ? "Изменяет позицию в аудиозаписи"
                    : "Сначала запустите воспроизведение"
                )
                .accessibilityAdjustableAction(adjustPlaybackPosition)
            }

            Divider()
                .frame(height: 28)

            Menu {
                Section("Скачать") {
                    ForEach(RecordingAudioExport.allCases.filter { availableExports.contains($0) }) { export in
                        Button {
                            onDownload(export)
                        } label: {
                            Label {
                                Text(export.title)
                            } icon: {
                                Image(systemName: export.systemImage)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(availableExports.isEmpty)
            .accessibilityLabel("Меню аудиозаписи")
            .help("Скачать общую запись или отдельную дорожку")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isHovering ? AssistantTheme.hoverSurface : AssistantTheme.subtleSurface,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AssistantTheme.contentHairline)
        }
        .onHover { isHovering = $0 }
        .onChange(of: isPlaying) { isPlaying in
            if !isPlaying {
                scrubProgress = nil
            }
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var elapsedText: String {
        RecordingListRow.durationText(displayedElapsedTime)
    }

    private var displayedElapsedTime: TimeInterval {
        if let scrubProgress {
            return resolvedDuration * scrubProgress
        }
        return elapsedTime
    }

    private var displayedProgress: Double {
        scrubProgress ?? min(max(playbackProgress, 0), 1)
    }

    private var showsElapsedTime: Bool {
        isPlaying || scrubProgress != nil
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isPlaying, width > 0 else { return }
                let progress = seekProgress(at: value.location.x, width: width)
                scrubProgress = progress
                onSeek(progress)
            }
            .onEnded { value in
                guard isPlaying, width > 0 else {
                    scrubProgress = nil
                    return
                }
                let progress = seekProgress(at: value.location.x, width: width)
                onSeek(progress)
                scrubProgress = nil
            }
    }

    private func adjustPlaybackPosition(_ direction: AccessibilityAdjustmentDirection) {
        guard isPlaying, resolvedDuration > 0 else { return }

        let step = min(5 / resolvedDuration, 1)
        let target: Double
        switch direction {
        case .increment:
            target = displayedProgress + step
        case .decrement:
            target = displayedProgress - step
        @unknown default:
            return
        }
        onSeek(min(max(target, 0), 1))
    }

    private func seekProgress(at xPosition: CGFloat, width: CGFloat) -> Double {
        min(max(Double(xPosition / width), 0), 1)
    }

    private var primaryAudioTitle: String {
        if availableExports.contains(.combined) {
            return "Общий звук"
        }
        if availableExports.contains(.incoming) {
            return "Звук собеседника"
        }
        if availableExports.contains(.outgoing) {
            return "Ваш микрофон"
        }
        return "Аудиофайл не найден"
    }

    private var durationText: String {
        RecordingListRow.durationText(resolvedDuration)
    }

    private var resolvedDuration: TimeInterval {
        playbackDuration > 0 ? playbackDuration : duration
    }
}

struct TranscriptFileRow: View {
    let participantCount: Int
    let status: RecordingArtifactStatus
    let onRetry: (() -> Void)?
    let onOpen: () -> Void
    let onRevealInFinder: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AssistantTheme.accent)
                .frame(width: 34, height: 34)
                .background(AssistantTheme.accentSoft)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("transcript.txt")
                        .font(.subheadline.weight(.semibold))

                    RecordingProcessingBadge(label: status.label)
                }

                Text("\(participantText) · таймкоды · \(status.detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let onRetry {
                Button("Повторить", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Повторно запускает обработку сохранённой аудиозаписи")
            }

            Menu {
                Button(action: onOpen) {
                    Label("Открыть", systemImage: "arrow.up.forward.app")
                }

                Button(action: onRevealInFinder) {
                    Label("Показать в Finder", systemImage: "folder")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Действия с файлом transcript.txt")
            .help("Действия с транскрипцией")
        }
        .padding(12)
        .background(AssistantTheme.surface)
        .overlay { Rectangle().stroke(AssistantTheme.contentHairline) }
    }

    private var participantText: String {
        switch participantCount {
        case 1: "1 участник"
        case 2...4: "\(participantCount) участника"
        default: "\(participantCount) участников"
        }
    }
}

struct RecordingProcessingBadge: View {
    let label: RecordingProcessingLabel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)

            Text(label.title)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.11), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Статус: \(label.title)")
    }

    private var color: Color {
        switch label {
        case .processing: .orange
        case .ready: AssistantTheme.green
        case .failed: .red
        }
    }

    private var systemImage: String {
        switch label {
        case .processing: "clock.arrow.circlepath"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

struct FinalAnalysisStatusRow: View {
    let status: RecordingArtifactStatus
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AssistantTheme.accent)
                .frame(width: 32, height: 32)
                .background(AssistantTheme.accentSoft)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                RecordingProcessingBadge(label: status.label)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let onRetry {
                Button("Повторить", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Повторно запускает итоговый анализ")
            }
        }
        .padding(12)
        .background(AssistantTheme.surface)
        .overlay { Rectangle().stroke(AssistantTheme.contentHairline) }
    }
}

struct FinalQuestionAnswerCardView: View {
    let card: FinalQuestionAnswerCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledText("ВОПРОС", text: card.normalizedQuestion)
            labeledText("ОТВЕТ", text: card.answer)

            if !card.advice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(AssistantTheme.accent)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Совет")
                            .font(.caption.weight(.semibold))
                        Text(card.advice)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantTheme.subtleSurface)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(AssistantTheme.accent)
                        .frame(width: 2)
                }
            }

            if let quote = card.evidence.first?.exactQuote,
               !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label {
                    Text("«\(quote)»")
                        .lineLimit(3)
                } icon: {
                    Image(systemName: "quote.opening")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Фрагмент транскрибации: \(quote)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AssistantTheme.surface)
        .overlay { Rectangle().stroke(AssistantTheme.contentHairline) }
        .accessibilityElement(children: .contain)
    }

    private func labeledText(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(AssistantTheme.accent)
            Text(text)
                .font(.subheadline.weight(label == "ВОПРОС" ? .semibold : .regular))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

struct RecordingListRow: View {
    let recording: Recording
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSelected ? AssistantTheme.accent : RecordingsChrome.sidebarSecondary)
                .frame(width: 19)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(recording.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(RecordingsChrome.sidebarPrimary)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Text(recording.startedAt, format: .dateTime.day().month(.abbreviated))
                    Text("·")
                    Text(Self.durationText(recording.duration))

                    Spacer(minLength: 4)

                    RecordingProcessingBadge(
                        label: RecordingPostCallPresentation.make(for: recording).overallLabel
                    )
                }
                .font(.caption)
                .foregroundStyle(RecordingsChrome.sidebarSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(AssistantTheme.accent)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isSelected { return RecordingsChrome.sidebarSelection }
        return isHovering ? RecordingsChrome.sidebarHover : .clear
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }
}
