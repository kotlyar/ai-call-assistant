import SwiftUI

/// A persistent call-control bar, analogous to Music's player controls.
struct PreflightDock: View {
    @Binding var incomingSource: AudioSourceOption
    @Binding var outgoingSource: AudioSourceOption

    let incomingSources: [AudioSourceOption]
    let outgoingSources: [AudioSourceOption]
    let isDiscoveringAudioSources: Bool
    let isPreparingAudio: Bool
    let isFinalizingAudio: Bool
    let audioSetupError: String?
    let audioPermissions: AudioPermissionSnapshot
    let openAICredentialState: OpenAICredentialState
    let selectedContextCount: Int
    let isCompact: Bool

    let onRefreshAudioSources: () async -> Void
    let onOpenAudioPermissions: () -> Void
    let onOpenOpenAISettings: () -> Void
    let onStartCall: () -> Void

    var body: some View {
        Group {
            if isCompact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }

    private var regularLayout: some View {
        HStack(spacing: 13) {
            readinessSummary
                .frame(minWidth: 205, alignment: .leading)

            Hairline(axis: .vertical, length: 34)

            sourceSummary(
                icon: "mic.fill",
                title: "Вы",
                value: outgoingSources.isEmpty ? "Не найден" : outgoingSource.title,
                tint: AssistantTheme.accent
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            sourceSummary(
                icon: "speaker.wave.2.fill",
                title: "Собеседник",
                value: incomingSources.isEmpty ? "Не найден" : incomingSource.title,
                tint: Color(nsColor: .systemBlue)
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            refreshButton
            permissionsButton
            startButton
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                readinessSummary
                Spacer(minLength: 8)
                refreshButton
                permissionsButton
            }

            startButton
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var readinessSummary: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AssistantTheme.accent)
                    .frame(width: 36, height: 36)

                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)

                Circle()
                    .fill(readiness.tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .offset(x: 15, y: 15)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(readiness.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(readiness.detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if openAICredentialState != .available {
                        CompatibleSettingsLink(fallbackAction: onOpenOpenAISettings) {
                            Text("Настроить")
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 9.5))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sourceSummary(
        icon: String,
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.45)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await onRefreshAudioSources() }
        } label: {
            Group {
                if isDiscoveringAudioSources {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(isDiscoveringAudioSources)
        .accessibilityLabel("Обновить источники звука")
        .help("Обновить источники звука")
    }

    private var permissionsButton: some View {
        Button(action: onOpenAudioPermissions) {
            Label(
                audioPermissions.allGranted ? "Доступы" : "Настроить доступы",
                systemImage: audioPermissions.allGranted ? "checkmark.shield.fill" : "lock.shield.fill"
            )
        }
        .controlSize(.small)
        .foregroundStyle(audioPermissions.allGranted ? AssistantTheme.green : AssistantTheme.amber)
        .help("Проверить доступы к микрофону и системному звуку")
    }

    private var startButton: some View {
        Button(action: onStartCall) {
            Group {
                if isPreparingAudio || isFinalizingAudio {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(isFinalizingAudio ? "Сохраняем…" : "Подключаем…")
                    }
                } else {
                    Label("Начать звонок", systemImage: "phone.fill")
                }
            }
            .padding(.horizontal, 5)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canStart)
        .keyboardShortcut(.defaultAction)
        .accessibilityHint("Начинает анализ разговора и открывает окно суфлёра")
    }

    private var canStart: Bool {
        !isDiscoveringAudioSources
            && !isPreparingAudio
            && !isFinalizingAudio
            && !outgoingSources.isEmpty
    }

    private struct Readiness {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
    }

    private var readiness: Readiness {
        if isFinalizingAudio {
            return Readiness(
                symbol: "arrow.down.circle",
                tint: AssistantTheme.accent,
                title: "Сохраняем запись",
                detail: "Дождитесь завершения звонка"
            )
        }

        if isPreparingAudio {
            return Readiness(
                symbol: "waveform.circle",
                tint: AssistantTheme.accent,
                title: "Подключаем звук",
                detail: contextSummary
            )
        }

        if isDiscoveringAudioSources {
            return Readiness(
                symbol: "arrow.triangle.2.circlepath.circle",
                tint: AssistantTheme.secondaryText,
                title: "Ищем источники",
                detail: contextSummary
            )
        }

        if outgoingSources.isEmpty {
            return Readiness(
                symbol: "exclamationmark.circle",
                tint: AssistantTheme.amber,
                title: "Микрофон не найден",
                detail: "Подключите микрофон"
            )
        }

        if !audioPermissions.allGranted {
            return Readiness(
                symbol: "lock.circle",
                tint: AssistantTheme.amber,
                title: "Нужны доступы",
                detail: "Микрофон и системный звук"
            )
        }

        return Readiness(
            symbol: "checkmark.circle.fill",
            tint: AssistantTheme.green,
            title: "Готово к звонку",
            detail: "\(assistantSummary) · \(contextSummary)"
        )
    }

    private var assistantSummary: String {
        switch openAICredentialState {
        case .available: "OpenAI подключён"
        case .missing: "только запись"
        case .unknown: "проверяем OpenAI"
        }
    }

    private var contextSummary: String {
        switch selectedContextCount {
        case 0: "без контекстов"
        case 1: "1 контекст"
        case 2...4: "\(selectedContextCount) контекста"
        default: "\(selectedContextCount) контекстов"
        }
    }
}
