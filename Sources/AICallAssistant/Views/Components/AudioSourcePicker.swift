import SwiftUI

/// A native file-list-style row for one audio route.
struct AudioSourcePicker: View {
    let title: String
    let systemImage: String
    let tint: Color
    let options: [AudioSourceOption]
    @Binding var selection: AudioSourceOption

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.11))
                    .frame(width: 32, height: 32)

                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(options.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(options.isEmpty ? "Источник не найден" : selection.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if options.isEmpty {
                Text(options.isEmpty ? "Недоступно" : "Изменить")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Picker(title, selection: $selection) {
                        ForEach(options) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 5) {
                        Text("Изменить")
                            .font(.system(size: 10.5, weight: .medium))

                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(AssistantTheme.accent)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? AssistantTheme.rowHover : Color.clear)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(options.isEmpty ? "Источник не найден" : selection.title)
        .help(options.isEmpty ? "Источник не найден" : "\(title): \(selection.title)")
    }
}
