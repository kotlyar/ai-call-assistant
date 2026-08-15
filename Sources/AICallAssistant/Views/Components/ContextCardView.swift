import SwiftUI

struct ContextCardView: View {
    let context: CallContext
    let onToggleSelection: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onToggleSelection) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: context.isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(context.isSelected ? AssistantTheme.accent : AssistantTheme.secondaryText)
                            .accessibilityHidden(true)

                        Text(context.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 28)
                    }

                    Text(context.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(13)
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
                .assistantCard(selected: context.isSelected)
            }
            .buttonStyle(PressableCardButtonStyle())
            .accessibilityLabel(context.title)
            .accessibilityValue(context.isSelected ? "Выбран" : "Не выбран")
            .accessibilityHint("Выбирает этот контекст для звонка")

            Menu {
                Button(action: onOpen) {
                    Label("Открыть", systemImage: "square.and.pencil")
                }

                Divider()

                Button(role: .destructive, action: onDelete) {
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(7)
            .accessibilityLabel("Действия с контекстом \(context.title)")
        }
    }
}

struct AddContextCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AssistantTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(AssistantTheme.accentSoft, in: Circle())

                Text("Добавить контекст")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 114)
            .background(
                RoundedRectangle(cornerRadius: AssistantTheme.cornerRadius, style: .continuous)
                    .fill(Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AssistantTheme.cornerRadius, style: .continuous)
                    .stroke(AssistantTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
        }
        .buttonStyle(PressableCardButtonStyle())
        .accessibilityHint("Открывает форму создания контекста")
    }
}
