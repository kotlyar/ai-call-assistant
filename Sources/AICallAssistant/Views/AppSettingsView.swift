import AppKit
import SwiftUI

struct AppSettingsView: View {
    enum Presentation {
        case embedded
        case sheet
        case settingsWindow
    }

    @ObservedObject private var store: OpenAISettingsStore
    @Environment(\.dismiss) private var dismiss
    private let presentation: Presentation

    init(
        store: OpenAISettingsStore,
        presentation: Presentation = .embedded
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.presentation = presentation
    }

    var body: some View {
        Group {
            switch presentation {
            case .embedded:
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .sheet:
                content
                    .frame(
                        minWidth: 720,
                        idealWidth: 760,
                        maxWidth: 960,
                        minHeight: 640,
                        idealHeight: 700,
                        maxHeight: 760
                    )

            case .settingsWindow:
                content
                    .frame(width: 960, height: 760)
            }
        }
        .background(MainWindowTheme.canvas)
        .tint(MainWindowTheme.primaryAction)
        .navigationTitle("Настройки")
    }

    private var content: some View {
        VStack(spacing: 0) {
            settingsHeader

            OpenAISettingsView(store: store, layout: .embedded)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var settingsHeader: some View {
        MainWindowPageHeader(
            title: "Настройки",
            subtitle: "OpenAI, модель и формат подсказок."
        ) {
            if showsCloseButton {
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .frame(
                    width: MainWindowTheme.pageHeaderActionSize,
                    height: MainWindowTheme.pageHeaderActionSize
                )
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(
                        cornerRadius: MainWindowTheme.radiusSmall,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Закрыть настройки")
        .help("Закрыть")
    }

    private var showsCloseButton: Bool {
        if case .sheet = presentation {
            return true
        }
        return false
    }

}
