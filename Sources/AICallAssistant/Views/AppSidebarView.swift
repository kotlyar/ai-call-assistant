import SwiftUI

struct AppSidebarView: View {
    @Binding var screen: AppScreen
    let recordingCount: Int
    var storageFolderName = "AI Call Assistant"
    @State private var hoveredScreen: AppScreen?

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            Divider()
                .padding(.bottom, 13)

            Text("РАЗДЕЛЫ")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            VStack(spacing: 4) {
                navigationButton(
                    title: "Новый звонок",
                    systemImage: "phone",
                    destination: .setup
                )

                navigationButton(
                    title: "Записи",
                    systemImage: "waveform",
                    destination: .recordings,
                    badge: recordingCount
                )
            }

            Spacer()

            storageCard
        }
        .padding(12)
        .background(AssistantTheme.sidebarBackground)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AssistantTheme.accent)
                .frame(width: 34, height: 34)
                .background(AssistantTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Call Assistant")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text("Помощник для звонков")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .padding(.bottom, 8)
    }

    private var storageCard: some View {
        HStack(spacing: 9) {
            Image(systemName: "externaldrive")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(AssistantTheme.subtleSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Локальное хранилище")
                    .font(.caption.weight(.medium))

                Text("Documents / \(storageFolderName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AssistantTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AssistantTheme.separator.opacity(0.8))
        }
        .help("Documents / \(storageFolderName)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Папка записей Documents, \(storageFolderName)")
    }

    private func navigationButton(
        title: String,
        systemImage: String,
        destination: AppScreen,
        badge: Int? = nil
    ) -> some View {
        Button {
            screen = destination
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 17)
                    .foregroundStyle(screen == destination ? AssistantTheme.accent : AssistantTheme.secondaryText)

                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AssistantTheme.subtleSurface, in: Capsule())
                        .accessibilityLabel("\(badge) записей")
                }
            }
            .font(.subheadline)
            .foregroundStyle(screen == destination ? Color.primary : AssistantTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(
                screen == destination
                    ? AssistantTheme.surface
                    : hoveredScreen == destination ? AssistantTheme.hoverSurface : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                if screen == destination {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AssistantTheme.separator)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            if isHovered {
                hoveredScreen = destination
            } else if hoveredScreen == destination {
                hoveredScreen = nil
            }
        }
        .accessibilityAddTraits(screen == destination ? .isSelected : [])
    }
}
