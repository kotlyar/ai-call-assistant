import AppKit
import SwiftUI

struct AudioPermissionsOnboardingView: View {
    let permissions: AudioPermissionSnapshot
    let requestingPermission: AudioPermissionKind?
    let onRequest: (AudioPermissionKind) async -> Void
    let onOpenSettings: (AudioPermissionKind) -> Void
    let onRefresh: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            permissionList
                .padding(.top, 29)

            Label("Экран не записывается. Аудио и записи остаются на этом Mac.", systemImage: "lock")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(PermissionsTheme.muted)
                .labelStyle(.titleAndIcon)
                .padding(.top, 18)

            actions
                .padding(.top, 28)
        }
        .padding(30)
        .frame(width: 680, height: 470, alignment: .topLeading)
        .background(PermissionsTheme.sheet)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(PermissionsTheme.rule, lineWidth: 1)
        }
        .shadow(color: PermissionsTheme.shadow, radius: 36, y: 14)
        .tint(PermissionsTheme.graphite)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(PermissionsTheme.ivory)
                .frame(width: 48, height: 48)
                .background(
                    PermissionsTheme.graphite,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("Первый запуск")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(PermissionsTheme.muted)

                Text("Доступ к звуку")
                    .font(.system(size: 32, weight: .medium))
                    .tracking(-1.25)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)

                Text("Разрешите микрофон и системное аудио — отдельно для вашего голоса и звука собеседника.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(PermissionsTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var permissionList: some View {
        VStack(spacing: 0) {
            permissionRule

            PermissionRow(
                title: "Микрофон",
                description: "Записывает ваш голос отдельной дорожкой.",
                systemImage: "mic",
                status: permissions.microphone,
                isRequesting: requestingPermission == .microphone,
                onRequest: { await onRequest(.microphone) },
                onOpenSettings: { onOpenSettings(.microphone) }
            )

            permissionRule

            PermissionRow(
                title: "Системное аудио",
                description: "Получает только звук приложений — без изображения экрана.",
                systemImage: "speaker.wave.2",
                status: permissions.systemAudio,
                isRequesting: requestingPermission == .systemAudio,
                onRequest: { await onRequest(.systemAudio) },
                onOpenSettings: { onOpenSettings(.systemAudio) }
            )

            permissionRule
        }
    }

    private var permissionRule: some View {
        Rectangle()
            .fill(PermissionsTheme.rule)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: 9) {
            Spacer(minLength: 0)

            Button("Продолжить позже", action: onComplete)
                .buttonStyle(PermissionsQuietButtonStyle(tone: .muted))

            Button(action: onRefresh) {
                Label("Проверить снова", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PermissionsQuietButtonStyle(tone: .primary))

            Button("Готово", action: onComplete)
                .buttonStyle(PermissionsPrimaryButtonStyle())
                .disabled(!permissions.allGranted)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let systemImage: String
    let status: AudioPermissionStatus
    let isRequesting: Bool
    let onRequest: () async -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(PermissionsTheme.text)
                .frame(width: 38, height: 38)
                .background(
                    PermissionsTheme.soft,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PermissionsTheme.text)

                Text(description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(PermissionsTheme.muted)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            trailingControl
        }
        .padding(.horizontal, 4)
        .frame(height: 81)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch status {
        case .authorized:
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PermissionsTheme.ready)

                Text("Разрешено")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(PermissionsTheme.muted)
            }
            .accessibilityElement(children: .combine)

        case .notDetermined:
            requestButton(title: "Разрешить", action: {
                Task { await onRequest() }
            })

        case .denied:
            requestButton(title: "Открыть настройки", action: onOpenSettings)
        }
    }

    private func requestButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isRequesting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(PermissionsTheme.ivory)
                } else {
                    Text(title)
                }
            }
            .frame(minWidth: title == "Разрешить" ? 76 : 126)
        }
        .buttonStyle(PermissionsPrimaryButtonStyle())
        .disabled(isRequesting)
    }
}

private struct PermissionsPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(PermissionsTheme.ivory)
            .padding(.horizontal, 15)
            .frame(height: 40)
            .background(
                PermissionsTheme.graphite.opacity(
                    isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.34
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct PermissionsQuietButtonStyle: ButtonStyle {
    enum Tone {
        case muted
        case primary
    }

    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: tone == .primary ? .medium : .regular))
            .foregroundStyle(tone == .primary ? PermissionsTheme.text : PermissionsTheme.muted)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(
                configuration.isPressed ? PermissionsTheme.soft : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private enum PermissionsTheme {
    static let sheet = adaptive(
        light: NSColor(srgbRed: 248 / 255, green: 248 / 255, blue: 245 / 255, alpha: 1),
        dark: NSColor(srgbRed: 36 / 255, green: 36 / 255, blue: 34 / 255, alpha: 1)
    )
    static let text = adaptive(
        light: NSColor(srgbRed: 28 / 255, green: 29 / 255, blue: 27 / 255, alpha: 1),
        dark: NSColor(srgbRed: 242 / 255, green: 241 / 255, blue: 237 / 255, alpha: 1)
    )
    static let muted = adaptive(
        light: NSColor(srgbRed: 112 / 255, green: 113 / 255, blue: 108 / 255, alpha: 1),
        dark: NSColor(srgbRed: 170 / 255, green: 169 / 255, blue: 163 / 255, alpha: 1)
    )
    static let soft = adaptive(
        light: NSColor(srgbRed: 232 / 255, green: 233 / 255, blue: 230 / 255, alpha: 1),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
    )
    static let rule = adaptive(
        light: NSColor(srgbRed: 226 / 255, green: 226 / 255, blue: 223 / 255, alpha: 1),
        dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
    )
    static let graphite = Color(red: 21 / 255, green: 22 / 255, blue: 21 / 255)
    static let ivory = Color(red: 244 / 255, green: 243 / 255, blue: 238 / 255)
    static let ready = Color(red: 134 / 255, green: 189 / 255, blue: 145 / 255)
    static let shadow = Color(red: 18 / 255, green: 19 / 255, blue: 17 / 255).opacity(0.24)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
