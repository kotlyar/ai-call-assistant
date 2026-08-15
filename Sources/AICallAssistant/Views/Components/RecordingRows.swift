import SwiftUI

enum RecordingAudioExport: String, CaseIterable, Identifiable {
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
        "\(rawValue).mp4"
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
    let onTogglePlayback: () -> Void
    let onDownload: (RecordingAudioExport) -> Void

    @State private var isHovering = false

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
            .accessibilityLabel(isPlaying ? "Приостановить запись" : "Воспроизвести запись")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AssistantTheme.accent)
                        .accessibilityHidden(true)

                    Text("Общий звук")
                        .font(.caption.weight(.medium))

                    Spacer()

                    Text(isPlaying ? "\(elapsedText) / \(durationText)" : durationText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                WaveformView(progress: playbackProgress)
                    .frame(height: 20)
            }

            Divider()
                .frame(height: 28)

            Menu {
                Section("Скачать") {
                    ForEach(RecordingAudioExport.allCases) { export in
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
            .accessibilityLabel("Меню аудиозаписи")
            .help("Скачать общую запись или отдельную дорожку")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isHovering ? AssistantTheme.hoverSurface : AssistantTheme.subtleSurface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AssistantTheme.separator.opacity(isHovering ? 0.85 : 0.45))
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var playbackProgress: Double {
        isPlaying ? 0.32 : 0
    }

    private var elapsedText: String {
        RecordingListRow.durationText(duration * playbackProgress)
    }

    private var durationText: String {
        RecordingListRow.durationText(duration)
    }
}

struct TranscriptFileRow: View {
    let participantCount: Int
    let onOpen: () -> Void
    let onRevealInFinder: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AssistantTheme.accent)
                .frame(width: 38, height: 38)
                .background(AssistantTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("transcript.txt")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 5) {
                        Circle()
                            .fill(AssistantTheme.green)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)

                        Text("Готов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Статус: готов")
                }

                Text("\(participantText) · таймкоды")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

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
        .padding(14)
        .assistantCard()
    }

    private var participantText: String {
        switch participantCount {
        case 1: "1 участник"
        case 2...4: "\(participantCount) участника"
        default: "\(participantCount) участников"
        }
    }
}

struct RecordingListRow: View {
    let recording: Recording
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 5) {
                Text(recording.startedAt, format: .dateTime.day().month(.abbreviated))
                Text("·")
                Text(Self.durationText(recording.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? AssistantTheme.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(AssistantTheme.accent)
                    .frame(width: 3)
                    .padding(.vertical, 7)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
