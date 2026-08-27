import SwiftUI

struct RealtimeTrackStatusPresentation: Equatable {
    enum IndicatorTone: Equatable {
        case active
        case pending
        case warning
        case error
    }

    let indicatorTone: IndicatorTone
    let statusText: String
    let indicatorHelp: String
    let warning: String?

    init(_ status: RealtimeTrackStatus) {
        switch status {
        case .connecting:
            indicatorTone = .pending
            statusText = "подключается"
            indicatorHelp = "Live-распознавание подключается."
            warning = nil
        case .live:
            indicatorTone = .active
            statusText = "live"
            indicatorHelp = "Live-распознавание работает."
            warning = nil
        case .reconnecting:
            indicatorTone = .pending
            statusText = "переподключается"
            indicatorHelp = "Live-распознавание переподключается."
            warning = nil
        case .degraded:
            // A degraded track is connected, but has a permanent historical
            // gap. Keep the live dot green and surface data loss separately.
            indicatorTone = .active
            statusText = "live, были пропуски"
            indicatorHelp = "Live-распознавание работает."
            warning = "Распознавание работает, но часть аудио могла быть пропущена."
        case .failed:
            indicatorTone = .error
            statusText = "недоступен"
            indicatorHelp = "Live-распознавание недоступно."
            warning = nil
        case .budgetStopped:
            indicatorTone = .warning
            statusText = "остановлен лимитом"
            indicatorHelp = "Live-распознавание остановлено лимитом расходов."
            warning = nil
        }
    }
}

struct RealtimeFailurePresentation: Equatable {
    let message: String

    init(_ diagnostic: RealtimeFailureDiagnostic) {
        message = Self.message(code: diagnostic.code, reason: diagnostic.reason)
    }

    private static func message(
        code: String,
        reason: RealtimeConnectionFailure.Reason
    ) -> String {
        switch code {
        case "http_401":
            return "OpenAI API key недействителен."
        case "http_403":
            return "У API key нет доступа к Realtime."
        case "insufficient_quota":
            return "Закончился баланс OpenAI API."
        case "http_429", "rate_limit_exceeded":
            return "Превышен лимит запросов OpenAI."
        case "model_unavailable":
            return "Выбранная Realtime-модель недоступна."
        case "invalid_session_configuration":
            return "Проверьте модель и настройки Realtime."
        case "handshake_timeout", "transport":
            return "Не удалось подключиться к Realtime API. Проверьте интернет."
        case "protocol_violation":
            return "Realtime API вернул неподдерживаемый ответ."
        case "server_error":
            return "Realtime API временно недоступен."
        case "provider_rejected":
            return "OpenAI отклонил Realtime-запрос."
        default:
            break
        }

        switch reason {
        case .authentication:
            return "Проверьте OpenAI API key."
        case .forbidden:
            return "У API key нет доступа к Realtime."
        case .quotaExceeded:
            return "Закончился баланс OpenAI API."
        case .invalidConfiguration:
            return "Проверьте модель и настройки Realtime."
        case .rateLimited:
            return "Превышен лимит запросов OpenAI."
        case .server:
            return "Realtime API временно недоступен."
        case .network:
            return "Не удалось подключиться к Realtime API. Проверьте интернет."
        case .protocolViolation:
            return "Realtime API вернул неподдерживаемый ответ."
        }
    }
}

/// The assistant rail's headline card: what the model heard, what to say, and
/// the one-line coaching note. It sits beside the transcript, never on top of
/// it, so guidance never costs the user their place in the conversation.
struct CurrentGuidanceCard: View {
    let moment: AssistantMoment?
    var status: LiveGuidanceStatus = .active

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let moment {
                heardBlock(moment)
                answerBlock(moment)
                adviceBlock(moment)
            } else {
                ListeningPlaceholder(status: status)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liveGlassPanel(cornerRadius: 16)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusTone)
                .frame(width: 7, height: 7)
                .shadow(color: statusTone.opacity(0.45), radius: 4)
                .accessibilityHidden(true)

            Text(statusTitle)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.9)
                .foregroundStyle(statusTone)

            Spacer(minLength: 6)

            if moment?.isLate == true {
                Label("С ЗАДЕРЖКОЙ", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AssistantTheme.liveAmber)
                    .accessibilityLabel("Ответ получен с задержкой")
            }
        }
        .padding(.bottom, moment == nil ? 4 : 14)
    }

    private func heardBlock(_ moment: AssistantMoment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("СЛЫШУ")

            highlightedHeardText(for: moment)
                .font(.system(size: 13.5, weight: .medium))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AssistantTheme.liveAccent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(AssistantTheme.liveAccent.opacity(0.22), lineWidth: 1)
        }
    }

    private func answerBlock(_ moment: AssistantMoment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ЧТО СКАЗАТЬ")

            Text(moment.answer)
                .font(.system(size: 17, weight: .medium))
                .tracking(-0.2)
                .lineSpacing(4)
                .foregroundStyle(Color.white.opacity(0.97))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, 16)
    }

    private func adviceBlock(_ moment: AssistantMoment) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AssistantTheme.liveAccent)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Совет")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))

                Text(moment.advice)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.74))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .padding(.top, 14)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .tracking(0.9)
            .foregroundStyle(AssistantTheme.liveAccent)
    }

    private func highlightedHeardText(for moment: AssistantMoment) -> Text {
        let heard = moment.heardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? moment.question
            : moment.heardText
        guard heard == moment.heardText,
              let range = moment.heardTextHighlightRange,
              range.lowerBound >= 0,
              range.lowerBound < range.upperBound,
              range.upperBound <= heard.unicodeScalars.count else {
            return Text(heard)
        }

        let scalars = heard.unicodeScalars
        let lower = scalars.index(scalars.startIndex, offsetBy: range.lowerBound)
        let upper = scalars.index(scalars.startIndex, offsetBy: range.upperBound)
        let prefix = String(heard[..<lower])
        let highlighted = String(heard[lower..<upper])
        let suffix = String(heard[upper...])
        let emphasized = Text(highlighted)
            .fontWeight(.medium)
            .foregroundColor(AssistantTheme.liveAccent)
        return Text("\(Text(prefix))\(emphasized)\(Text(suffix))")
    }

    private var statusTitle: String {
        switch status {
        case .inactive: "LIVE-СОВЕТЫ ОТКЛЮЧЕНЫ"
        case .active: "АНАЛИЗИРУЕТ ОНЛАЙН"
        case .contextLimitReached: "ДОСТИГНУТ ЛИМИТ КОНТЕКСТА"
        case .budgetStopped: "ОСТАНОВЛЕНО ЛИМИТОМ"
        case .failed: "АНАЛИЗ НЕДОСТУПЕН"
        }
    }

    private var statusTone: Color {
        switch status {
        case .active: AssistantTheme.liveGreen
        case .inactive: Color.white.opacity(0.5)
        case .contextLimitReached, .budgetStopped: AssistantTheme.liveAmber
        case .failed: .red
        }
    }
}

private struct ListeningPlaceholder: View {
    let status: LiveGuidanceStatus

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(AssistantTheme.liveAccent)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(AssistantTheme.liveSecondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var glyph: String {
        switch status {
        case .active: "waveform"
        case .inactive: "moon.zzz"
        case .contextLimitReached: "square.stack.3d.up.slash"
        case .budgetStopped: "gauge.with.dots.needle.33percent"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch status {
        case .active: "Слушаю разговор…"
        case .inactive: "Live-советы выключены"
        case .contextLimitReached: "Слишком большой полный контекст"
        case .budgetStopped: "Достигнут лимит расходов"
        case .failed: "Не удалось получить совет"
        }
    }

    private var detail: String {
        switch status {
        case .active:
            return "Совет появится здесь, когда собеседник задаст вопрос."
        case .inactive:
            return "Добавьте OpenAI API key в Settings. Запись продолжает работать."
        case .contextLimitReached:
            return "Текст не обрезан. Уменьшите выбранные контексты перед следующим звонком."
        case .budgetStopped:
            return "Запись и локальная аудиодорожка продолжаются."
        case .failed:
            return "Запись продолжается; проверьте подключение и API key."
        }
    }
}

/// One earlier answer in the rail's feed. Each card is anchored to the call
/// timecode it belongs to, which matches the marks on the timeline below.
struct AnswerHistoryCard: View {
    let item: AnswerHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.timecode)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(AssistantTheme.liveAccent)

                Text(item.moment.question)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(2)

                if item.moment.isLate {
                    Text("С ЗАДЕРЖКОЙ")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(AssistantTheme.liveAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AssistantTheme.liveAmber.opacity(0.13), in: Capsule())
                        .accessibilityLabel("Ответ получен с задержкой")
                }

                Spacer(minLength: 0)
            }

            Text(item.moment.answer)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.84))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Label(item.moment.advice, systemImage: "sparkle")
                .font(.system(size: 11.5))
                .foregroundStyle(AssistantTheme.liveSecondaryText)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ответ в \(item.timecode). Вопрос: \(item.moment.question). Ответ: \(item.moment.answer). Совет: \(item.moment.advice)")
    }
}
