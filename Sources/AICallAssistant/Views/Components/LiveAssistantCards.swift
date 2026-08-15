import SwiftUI

struct LiveAudioStatusRow: View {
    let incomingSource: String
    let outgoingSource: String

    var body: some View {
        HStack(spacing: 0) {
            source(
                label: "Собеседник",
                source: incomingSource,
                systemImage: "speaker.wave.2.fill"
            )

            Rectangle()
                .fill(AssistantTheme.liveSeparator)
                .frame(width: 1, height: 22)
                .padding(.horizontal, 12)

            source(
                label: "Вы",
                source: outgoingSource,
                systemImage: "mic.fill"
            )
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(AssistantTheme.liveSubtleSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AssistantTheme.liveSeparator)
        }
        .accessibilityElement(children: .contain)
    }

    private func source(label: String, source: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(AssistantTheme.liveAccent)
                .accessibilityHidden(true)

            Text(label)
                .font(.caption.weight(.medium))

            Text(source)
                .font(.caption2)
                .foregroundStyle(AssistantTheme.liveSecondaryText)
                .lineLimit(1)

            Circle()
                .fill(AssistantTheme.liveGreen)
                .frame(width: 6, height: 6)
                .shadow(color: AssistantTheme.liveGreen.opacity(0.35), radius: 3)
                .accessibilityLabel("Активен")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(source), активен")
    }
}

struct CurrentGuidanceCard: View {
    let moment: AssistantMoment?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(AssistantTheme.liveGreen)
                    .frame(width: 7, height: 7)
                    .shadow(color: AssistantTheme.liveGreen.opacity(0.45), radius: 4)
                    .accessibilityHidden(true)

                Text("АНАЛИЗИРУЕТ ОНЛАЙН")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(AssistantTheme.liveGreen)

                Spacer()

                Text("Обновлено сейчас")
                    .font(.caption2)
                    .foregroundStyle(AssistantTheme.liveSecondaryText)
            }
            .padding(.bottom, 12)

            if let moment {
                VStack(alignment: .leading, spacing: 6) {
                    Text("СЛЫШУ")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(AssistantTheme.liveAccent)

                    Text(heardText(for: moment))
                        .font(.system(size: 15, weight: .medium))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantTheme.liveAccent.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AssistantTheme.liveAccent.opacity(0.22))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("ЧТО СКАЗАТЬ")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.5)
                        .foregroundStyle(AssistantTheme.liveAccent)

                    Text(moment.answer)
                        .font(.system(size: 18, weight: .medium))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.top, 15)

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(AssistantTheme.liveAccent)
                        .padding(.top, 2)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Совет")
                            .font(.caption.weight(.semibold))

                        Text(moment.advice)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.76))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantTheme.liveSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 14)
            } else {
                ListeningPlaceholder()
            }
        }
        .padding(15)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AssistantTheme.liveSeparator)
        }
        .accessibilityElement(children: .contain)
    }

    private func heardText(for moment: AssistantMoment) -> String {
        let heard = moment.heardText.trimmingCharacters(in: .whitespacesAndNewlines)
        return heard.isEmpty ? moment.question : heard
    }
}

private struct ListeningPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(AssistantTheme.liveAccent)

            Text("Слушаю разговор…")
                .font(.headline)

            Text("Совет появится здесь, когда собеседник задаст вопрос.")
                .font(.caption)
                .foregroundStyle(AssistantTheme.liveSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct AnswerHistoryCard: View {
    let item: AnswerHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.timecode)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AssistantTheme.liveAccent)

                Text(item.moment.question)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)

                Spacer(minLength: 0)
            }

            Text(item.moment.answer)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.86))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Label(item.moment.advice, systemImage: "sparkle")
                .font(.caption)
                .foregroundStyle(AssistantTheme.liveSecondaryText)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AssistantTheme.liveSubtleSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AssistantTheme.liveSeparator)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ответ в \(item.timecode). Вопрос: \(item.moment.question). Ответ: \(item.moment.answer). Совет: \(item.moment.advice)")
    }
}
