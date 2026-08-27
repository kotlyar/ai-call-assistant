import SwiftUI

/// Kept under its original name for API compatibility, but intentionally drawn
/// as a dense native row instead of a dashboard card.
struct ContextCardView: View {
    let context: CallContext
    let onToggleSelection: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onToggleSelection) {
                Image(systemName: context.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(context.isSelected ? AssistantTheme.accent : AssistantTheme.secondaryText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(QuietButtonStyle())
            .help(context.isSelected ? "Исключить из звонка" : "Использовать в звонке")
            .accessibilityLabel(context.isSelected ? "Исключить \(context.title) из звонка" : "Использовать \(context.title) в звонке")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                    }

                    if let attachmentDescription {
                        Label(attachmentDescription, systemImage: "paperclip")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(pressedOpacity: 0.72))
            .accessibilityLabel(context.title)
            .accessibilityValue(context.isSelected ? "Используется в звонке" : "Не используется в звонке")
            .accessibilityHint("Открывает редактирование контекста")

            Menu {
                Button(action: onOpen) {
                    Label("Редактировать", systemImage: "square.and.pencil")
                }

                Divider()

                Button(role: .destructive, action: onDelete) {
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0.68)
            .accessibilityLabel("Действия с контекстом \(context.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(
            context.isSelected ? AssistantTheme.accentSoft : isHovered ? AssistantTheme.rowHover : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
        .contextMenu {
            Button("Редактировать", action: onOpen)
            Divider()
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }

    private var summary: String {
        context.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var attachmentDescription: String? {
        guard !context.attachments.isEmpty else { return nil }
        let names = context.attachments.map(\.fileName).joined(separator: ", ")
        return "\(fileCountText) · \(names)"
    }

    private var fileCountText: String {
        switch context.attachments.count {
        case 1: return "1 файл"
        case 2...4: return "\(context.attachments.count) файла"
        default: return "\(context.attachments.count) файлов"
        }
    }
}

struct AddContextCard: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AssistantTheme.accent)
                    .frame(width: 20)

                Text("Добавить контекст")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                isHovered ? AssistantTheme.rowHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 6)
        .buttonStyle(QuietButtonStyle(pressedOpacity: 0.72))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
        .accessibilityHint("Открывает форму создания контекста")
    }
}
