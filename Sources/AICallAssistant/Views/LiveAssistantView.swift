import SwiftUI

struct LiveAssistantView: View {
    let incomingSource: String
    let outgoingSource: String
    let selectedContextCount: Int
    let elapsedTime: TimeInterval
    let currentMoment: AssistantMoment?
    let answerHistory: [AnswerHistoryItem]
    let onEndCall: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            Color.black.opacity(0.56)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titlebar
                Divider().overlay(AssistantTheme.liveSeparator)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LiveAudioStatusRow(
                            incomingSource: incomingSource,
                            outgoingSource: outgoingSource
                        )

                        Label(contextDescription, systemImage: "square.stack.3d.up")
                            .font(.caption)
                            .foregroundStyle(AssistantTheme.liveSecondaryText)
                            .padding(.horizontal, 2)

                        CurrentGuidanceCard(moment: currentMoment)

                        historySection
                    }
                    .padding(14)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Color.white.opacity(0.94))
        .frame(minWidth: 390, idealWidth: 430, minHeight: 520, idealHeight: 680)
    }

    private var titlebar: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: Color.red.opacity(0.45), radius: 4)
                .accessibilityHidden(true)

            Text("В эфире")
                .font(.caption.weight(.medium))

            Text(durationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AssistantTheme.liveSecondaryText)
                .accessibilityLabel("Продолжительность звонка \(durationText)")

            Spacer()

            Button("Завершить", role: .destructive, action: onEndCall)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .keyboardShortcut(".", modifiers: [.command])
                .accessibilityHint("Завершает анализ и сохраняет запись звонка")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.black.opacity(0.20))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Лента")
                    .font(.headline)

                Text("предыдущие ответы · новые сверху")
                    .font(.caption2)
                    .foregroundStyle(AssistantTheme.liveSecondaryText)

                Spacer()

                Text("\(answerHistory.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AssistantTheme.liveSecondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(AssistantTheme.liveSurface, in: Capsule())
                    .accessibilityLabel("Ответов в ленте: \(answerHistory.count)")
            }
            .padding(.horizontal, 2)

            if sortedHistory.isEmpty {
                Text("Предыдущие ответы появятся здесь по ходу разговора.")
                    .font(.caption)
                    .foregroundStyle(AssistantTheme.liveSecondaryText)
                    .padding(.vertical, 17)
                    .frame(maxWidth: .infinity)
                    .background(AssistantTheme.liveSubtleSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(sortedHistory) { item in
                        AnswerHistoryCard(item: item)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var sortedHistory: [AnswerHistoryItem] {
        answerHistory.sorted { $0.elapsedTime > $1.elapsedTime }
    }

    private var contextDescription: String {
        switch selectedContextCount {
        case 0: "Контексты не выбраны"
        case 1: "Используется 1 контекст"
        case 2...4: "Используются \(selectedContextCount) контекста"
        default: "Используются \(selectedContextCount) контекстов"
        }
    }

    private var durationText: String {
        RecordingListRow.durationText(elapsedTime)
    }
}
