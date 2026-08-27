import SwiftUI

/// Compact master-list rows used by the planning screen.
struct ContextChecklist: View {
    let contexts: [CallContext]
    let isWide: Bool
    let onToggleSelection: (CallContext) -> Void
    let onOpenContext: (CallContext) -> Void
    let onDeleteContext: (CallContext) -> Void
    let onCreateContext: () -> Void

    var body: some View {
        if contexts.isEmpty {
            emptyState
        } else if isWide {
            HStack(alignment: .top, spacing: 0) {
                column(for: Array(contexts.prefix(leftColumnCount)))
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Hairline(axis: .vertical)
                    .padding(.horizontal, 26)

                column(for: Array(contexts.dropFirst(leftColumnCount)))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            column(for: contexts)
        }
    }

    private var leftColumnCount: Int {
        (contexts.count + 1) / 2
    }

    private func column(for items: [CallContext]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { context in
                ContextChecklistRow(
                    context: context,
                    onToggleSelection: { onToggleSelection(context) },
                    onOpen: { onOpenContext(context) },
                    onDelete: { onDeleteContext(context) }
                )

                if context.id != items.last?.id {
                    Hairline()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Пока нет ни одного контекста")
                .font(.system(size: 15, weight: .semibold))

            Text("Добавьте материалы разговора — ассистент будет опираться на них во время звонка.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onCreateContext) {
                Label("Добавить контекст", systemImage: "plus")
            }
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.vertical, 8)
    }
}

private struct ContextChecklistRow: View {
    let context: CallContext
    let onToggleSelection: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: selectionBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .padding(.top, 2)
                .accessibilityHidden(true)

            marker

            VStack(alignment: .leading, spacing: 3) {
                Text(context.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let attachmentDescription {
                    Text(attachmentDescription)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only the text block carries the tap: the checkbox handles its own
            // click, and overlapping the two would toggle twice.
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleSelection)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackground)
        )
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .contextMenu {
            Button("Редактировать", action: onOpen)
            Divider()
            Button("Удалить", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Включает контекст в звонок; правый клик — редактировать или удалить")
        .accessibilityAddTraits(context.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Переключить", onToggleSelection)
        .help(context.isSelected ? "Исключить «\(context.title)» из звонка" : "Включить «\(context.title)» в звонок")
    }

    private var marker: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(context.isSelected ? AssistantTheme.accent : AssistantTheme.separator)
            .frame(width: 3, height: 31)
            .accessibilityHidden(true)
    }

    private var rowBackground: Color {
        if context.isSelected {
            return AssistantTheme.accent.opacity(isHovered ? 0.13 : 0.07)
        }
        return isHovered ? AssistantTheme.rowHover : .clear
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { context.isSelected },
            set: { _ in onToggleSelection() }
        )
    }

    private var summary: String {
        context.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var attachmentDescription: String? {
        switch context.attachments.count {
        case 0: nil
        case 1: "1 файл"
        case 2...4: "\(context.attachments.count) файла"
        default: "\(context.attachments.count) файлов"
        }
    }

    private var accessibilityValue: String {
        var parts = [context.isSelected ? "Выбран" : "Не выбран"]
        if !summary.isEmpty {
            parts.append(summary)
        }
        if let attachmentDescription {
            parts.append(attachmentDescription)
        }
        return parts.joined(separator: ". ")
    }
}
