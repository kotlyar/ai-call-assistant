import SwiftUI

enum RecordingAudioExport: String, CaseIterable, Identifiable {
    case combined
    case incoming
    case outgoing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combined: "Общий файл"
        case .incoming: "Входящий звук"
        case .outgoing: "Исходящий звук"
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
    let durationText: String
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    let onDownload: (RecordingAudioExport) -> Void

    var body: some View {
        HStack(spacing: 13) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(AssistantTheme.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Приостановить запись" : "Воспроизвести запись")

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("Аудиозапись звонка")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                WaveformView(progress: isPlaying ? 0.32 : 0)
                    .frame(height: 24)
            }

            Menu {
                Section("Скачать аудио") {
                    ForEach(RecordingAudioExport.allCases) { export in
                        Button {
                            onDownload(export)
                        } label: {
                            Label {
                                Text("\(export.title) — \(export.filename)")
                            } icon: {
                                Image(systemName: export.systemImage)
                            }
                        }
                    }
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
            .accessibilityLabel("Меню аудиозаписи")
            .help("Скачать аудиозапись")
        }
        .padding(14)
        .assistantCard()
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
