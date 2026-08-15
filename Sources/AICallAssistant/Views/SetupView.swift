import SwiftUI

struct SetupView: View {
    @Binding var incomingSource: String
    @Binding var outgoingSource: String

    let incomingSources: [String]
    let outgoingSources: [String]
    let contexts: [CallContext]

    let onToggleContextSelection: (CallContext) -> Void
    let onCreateContext: () -> Void
    let onOpenContext: (CallContext) -> Void
    let onDeleteContext: (CallContext) -> Void
    let onSelectAllContexts: () -> Void
    let onClearContextSelection: () -> Void
    let onStartCall: () -> Void

    private let gridColumns = [
        GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 10, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    audioSection
                    contextSection
                }
                .frame(maxWidth: AssistantTheme.contentWidth, alignment: .leading)
                .padding(.horizontal, 26)
                .padding(.top, 26)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            footer
        }
        .background(AssistantTheme.windowBackground)
        .navigationTitle("Новый звонок")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Новый звонок")
                .font(.system(size: 24, weight: .semibold))

            Text("Выберите источники звука и контексты, которые ассистент должен учитывать.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeading(
                title: "Захват аудио",
                subtitle: "Входящий и исходящий звук сохраняются отдельно"
            )

            HStack(alignment: .top, spacing: 10) {
                AudioSourcePicker(
                    title: "Входящий звук",
                    subtitle: "Голос собеседника",
                    systemImage: "speaker.wave.2.fill",
                    options: incomingSources,
                    selection: $incomingSource
                )

                AudioSourcePicker(
                    title: "Исходящий звук",
                    subtitle: "Ваш голос",
                    systemImage: "mic.fill",
                    options: outgoingSources,
                    selection: $outgoingSource
                )
            }
        }
        .padding(.top, 26)
    }

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .bottom, spacing: 12) {
                SectionHeading(
                    title: "Контексты для звонка",
                    subtitle: contextLibraryDescription
                )

                Spacer()

                if !contexts.isEmpty {
                    HStack(spacing: 2) {
                        Button("Выбрать все", action: onSelectAllContexts)
                            .buttonStyle(.borderless)
                            .disabled(selectedContextCount == contexts.count)

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Button("Снять выбор", action: onClearContextSelection)
                            .buttonStyle(.borderless)
                            .disabled(selectedContextCount == 0)
                    }
                    .font(.caption)
                }
            }

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                ForEach(contexts) { context in
                    ContextCardView(
                        context: context,
                        onToggleSelection: { onToggleContextSelection(context) },
                        onOpen: { onOpenContext(context) },
                        onDelete: { onDeleteContext(context) }
                    )
                }

                AddContextCard(action: onCreateContext)
            }
        }
        .padding(.top, 26)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 16) {
                Text(selectionDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onStartCall) {
                    Label("Начать", systemImage: "phone.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Начинает анализ разговора и открывает окно суфлёра")
            }
            .frame(maxWidth: AssistantTheme.contentWidth)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .background(AssistantTheme.surface)
    }

    private var selectedContextCount: Int {
        contexts.lazy.filter(\.isSelected).count
    }

    private var contextLibraryDescription: String {
        switch contexts.count {
        case 1:
            return "1 материал в библиотеке"
        case 2...4:
            return "\(contexts.count) материала в библиотеке"
        default:
            return "\(contexts.count) материалов в библиотеке"
        }
    }

    private var selectionDescription: String {
        selectedContextCount == 0
            ? "Контексты не выбраны"
            : "Выбрано: \(selectedContextCount)"
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
