import AppKit
import SwiftUI

/// Native library navigation inspired by the restrained sidebar hierarchy used
/// by Music, with the compact row density of a file utility.
struct AppSidebarView: View {
    @Binding var screen: AppScreen
    let recordingCount: Int
    let storagePath: String

    @State private var hoveredScreen: AppScreen?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader

            destination(title: "Новый звонок", systemImage: "phone.fill", screen: .setup)

            sidebarSection("БИБЛИОТЕКА")
                .padding(.top, 18)

            VStack(spacing: 1) {
                destination(title: "Контексты", systemImage: "doc.text", screen: .contexts)
                destination(
                    title: "Записи",
                    systemImage: "waveform",
                    screen: .recordings,
                    count: recordingCount
                )
            }

            Spacer(minLength: 24)

            Hairline(color: AssistantTheme.sidebarRule)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            destination(title: "Настройки", systemImage: "gearshape", screen: .settings)

            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(AssistantTheme.green)
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                Text("На этом Mac")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 11)
            .help(storagePath)
            .accessibilityLabel("Записи хранятся на этом Mac: \(storagePath)")
        }
        .padding(.horizontal, 9)
        .padding(.top, 46)
        .padding(.bottom, 16)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowMaterialBackground(material: .sidebar))
        .overlay(alignment: .trailing) {
            Hairline(axis: .vertical, color: AssistantTheme.sidebarEdge)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 23, height: 23)
                .accessibilityHidden(true)

            Text("Callya")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 22)
    }

    private func sidebarSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.65)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }

    private func destination(
        title: String,
        systemImage: String,
        screen destination: AppScreen,
        count: Int? = nil
    ) -> some View {
        let isSelected = screen == destination
        let isHovered = hoveredScreen == destination

        return Button {
            screen = destination
        } label: {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? AssistantTheme.accent : AssistantTheme.sidebarTint(for: destination))
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AssistantTheme.accent : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                        .accessibilityLabel("\(count) записей")
                }
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                background(isSelected: isSelected, isHovered: isHovered),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(QuietButtonStyle(pressedOpacity: 0.72))
        .onHover { hovering in
            if hovering {
                hoveredScreen = destination
            } else if hoveredScreen == destination {
                hoveredScreen = nil
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func background(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return MainWindowTheme.sidebarSelection
        }
        return isHovered ? MainWindowTheme.sidebarHover : .clear
    }
}
