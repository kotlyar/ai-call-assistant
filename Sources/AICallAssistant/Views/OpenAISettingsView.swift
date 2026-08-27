import AppKit
import SwiftUI

struct OpenAISettingsView: View {
    enum Layout {
        case embedded
        case standalone
    }

    @ObservedObject var store: OpenAISettingsStore
    let layout: Layout

    @State private var apiKey = ""
    @State private var draft: GuidanceConfiguration
    @State private var statusMessage: String?
    @State private var isWorking = false
    @FocusState private var focusedResponseModelID: String?

    init(store: OpenAISettingsStore, layout: Layout = .standalone) {
        self.store = store
        self.layout = layout
        _draft = State(initialValue: store.configuration)
    }

    var body: some View {
        Group {
            switch layout {
            case .embedded:
                settingsForm
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .standalone:
                settingsForm
                    .frame(width: 960, height: 660)
            }
        }
        .task {
            try? await store.refreshCredentialState()
        }
        .onAppear {
            draft = store.configuration
        }
        .tint(MainWindowTheme.primaryAction)
    }

    private var settingsForm: some View {
        GeometryReader { geometry in
            // The main window has one fixed composition. Keep the approved
            // desktop metrics instead of shrinking every control at arbitrary
            // width thresholds; only genuinely narrow standalone surfaces may
            // use a separate layout in the future.
            let compact = false
            let horizontalInset = MainWindowTheme.pageHorizontalInset
            let contentWidth = min(
                max(geometry.size.width - horizontalInset * 2, 0),
                MainWindowTheme.contentMaxWidth
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    apiSection(compact: compact, contentWidth: contentWidth)
                        .padding(.top, MainWindowTheme.pageContentTopSpacing)

                    answersHeading(compact: compact)
                        .padding(.top, 18)

                    configurationColumns(
                        contentWidth: contentWidth,
                        compact: compact
                    )
                    .padding(.top, 12)

                    saveFooter(compact: compact)
                        .padding(.top, 18)
                        .padding(.bottom, 17)
                }
                .frame(width: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
        }
        .background(MainWindowTheme.canvas)
        .controlSize(.regular)
    }

    private func apiSection(compact: Bool, contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MainWindowDeckHeader(title: "Подключение") {
                HStack(spacing: compact ? 7 : 8) {
                    MainWindowStatusDot(color: credentialStatus.color)

                    Text(credentialStatus.title)
                        .font(.system(size: compact ? 12 : 13, weight: .regular))
                        .foregroundStyle(MainWindowTheme.deckSecondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Статус API key: \(credentialStatus.title)")
                .help(credentialDescription)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("OpenAI Platform API")
                    .font(.system(size: compact ? 24 : 27, weight: .medium))
                    .tracking(compact ? -0.45 : -0.6)

                apiCredentialRow(compact: compact, contentWidth: contentWidth)
                    .padding(.top, 8)

                HStack(alignment: .center, spacing: 10) {
                    Label {
                        Text("Локальный файл · без отдельного шифрования · Keychain не используется")
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "externaldrive")
                    }
                }
                .font(.system(size: compact ? 11 : 12, weight: .regular))
                .foregroundStyle(MainWindowTheme.deckSecondary)
                .padding(.top, 11)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, MainWindowTheme.deckHorizontalInset)
        }
        .frame(height: 215, alignment: .top)
        .mainWindowDeckSurface()
        .foregroundStyle(MainWindowTheme.deckText)
    }

    @ViewBuilder
    private func apiCredentialRow(compact: Bool, contentWidth: CGFloat) -> some View {
        if contentWidth < 560 {
            VStack(alignment: .leading, spacing: 10) {
                apiKeyField(compact: true)
                apiActions(compact: true)
            }
        } else {
            HStack(alignment: .bottom, spacing: compact ? 7 : 8) {
                apiKeyField(compact: compact)
                    .frame(maxWidth: .infinity)

                apiActions(compact: compact)
            }
        }
    }

    private func apiKeyField(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 5) {
            Text("Новый API key")
                .font(.system(size: compact ? 11 : 12, weight: .regular))
                .foregroundStyle(MainWindowTheme.deckSecondary)

            HStack(spacing: compact ? 8 : 9) {
                Image(systemName: "key")
                    .font(.system(size: compact ? 13 : 14, weight: .regular))
                    .foregroundStyle(MainWindowTheme.deckSecondary)
                    .accessibilityHidden(true)

                ZStack(alignment: .leading) {
                    if apiKey.isEmpty {
                        Text(apiKeyPlaceholder)
                            .font(.system(size: compact ? 13 : 14, weight: .regular))
                            .foregroundStyle(MainWindowTheme.deckText.opacity(0.68))
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    SecureField("", text: $apiKey)
                        .textFieldStyle(.plain)
                        .textContentType(.password)
                        .font(.system(size: compact ? 13 : 14, weight: .regular))
                        .foregroundColor(MainWindowTheme.deckText)
                        .tint(MainWindowTheme.deckText)
                        .accessibilityLabel("OpenAI API key")
                }
            }
            .padding(.horizontal, compact ? 10 : 12)
            .frame(minWidth: 190, minHeight: MainWindowTheme.controlHeight)
            .background(
                MainWindowTheme.deckControl,
                in: RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusControl,
                    style: .continuous
                )
            )
        }
    }

    private func apiActions(compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 8) {
            Button("Сохранить") {
                Task { await saveKey() }
            }
            .buttonStyle(SettingsDeckButtonStyle(kind: .primary, compact: compact))
            .disabled(
                isWorking
                    || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            Button("Проверить") {
                Task { await testConnection() }
            }
            .buttonStyle(SettingsDeckButtonStyle(kind: .secondary, compact: compact))
            .disabled(isWorking)

            Button {
                Task { await deleteKey() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: compact ? 13 : 14, weight: .regular))
                    .frame(
                        width: MainWindowTheme.controlHeight,
                        height: MainWindowTheme.controlHeight
                    )
            }
            .buttonStyle(SettingsDeckButtonStyle(kind: .quiet, compact: compact))
            .disabled(isWorking || store.credentialState == .missing)
            .accessibilityLabel("Удалить API key")
            .help("Удалить сохранённый ключ")
        }
    }

    private func answersHeading(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 5) {
            Text("Ответы")
                .font(
                    .system(
                        size: compact ? 21 : MainWindowTheme.sectionTitleSize,
                        weight: .medium
                    )
                )
                .tracking(
                    compact ? -0.35 : MainWindowTheme.sectionTitleTracking
                )

            Text("Модель, длина подсказок и лимит на звонок")
                .font(
                    .system(
                        size: compact ? 12 : MainWindowTheme.sectionSubtitleSize,
                        weight: .regular
                    )
                )
                .foregroundStyle(MainWindowTheme.secondaryText)
        }
        .frame(minHeight: compact ? 39 : 48, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func configurationColumns(
        contentWidth: CGFloat,
        compact: Bool
    ) -> some View {
        if contentWidth < 520 {
            VStack(alignment: .leading, spacing: 24) {
                modelColumn(compact: true)
                answerControls(compact: true)
            }
        } else {
            let columnGap = MainWindowTheme.settingsGridColumnGap
            let modelWidth = round((contentWidth - columnGap) * 0.44)

            HStack(alignment: .top, spacing: columnGap) {
                modelColumn(compact: compact)
                    .frame(width: modelWidth, alignment: .topLeading)

                answerControls(compact: compact)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func modelColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Модель ответов")
                .font(.system(size: compact ? 12 : 13, weight: .regular))
                .frame(
                    maxWidth: .infinity,
                    minHeight: MainWindowTheme.settingsGridRowHeight,
                    maxHeight: MainWindowTheme.settingsGridRowHeight,
                    alignment: .leading
                )
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                ForEach(responseModelIDs.indices, id: \.self) { index in
                    let modelID = responseModelIDs[index]
                    let isSelected = modelID == draft.responsesModelID

                    Button {
                        draft.responsesModelID = modelID
                        focusedResponseModelID = modelID
                    } label: {
                        HStack(spacing: 11) {
                            ZStack {
                                Circle()
                                    .strokeBorder(
                                        isSelected
                                            ? MainWindowTheme.primaryAction
                                            : MainWindowTheme.secondaryText.opacity(0.7),
                                        lineWidth: 1.5
                                    )
                                    .frame(width: 16, height: 16)

                                if isSelected {
                                    Circle()
                                        .fill(MainWindowTheme.primaryAction)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            .accessibilityHidden(true)

                            Text(modelID)
                                .font(
                                    .system(
                                        size: compact ? 14 : 15,
                                        weight: isSelected ? .medium : .regular
                                    )
                                )

                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: MainWindowTheme.settingsGridRowHeight,
                            maxHeight: MainWindowTheme.settingsGridRowHeight,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(
                        SettingsModelRadioButtonStyle(
                            isSelected: isSelected,
                            isFocused: focusedResponseModelID == modelID
                        )
                    )
                    // A radio group contributes one tab stop: only its current
                    // selection enters the focus chain. Arrow keys then move
                    // both selection and focus through the group.
                    .focusable(isSelected)
                    .focused($focusedResponseModelID, equals: modelID)
                    .mainWindowFocusEffectDisabled()
                    .onMoveCommand(perform: moveResponseModelSelection)
                }
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusField,
                    style: .continuous
                )
            )
            .mainWindowFieldSurface(cornerRadius: MainWindowTheme.radiusField)
            .accessibilityRepresentation {
                Picker("Модель ответов", selection: $draft.responsesModelID) {
                    ForEach(responseModelIDs, id: \.self) { modelID in
                        Text(modelID).tag(modelID)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
    }

    private func moveResponseModelSelection(_ direction: MoveCommandDirection) {
        guard !responseModelIDs.isEmpty else { return }

        let offset: Int
        switch direction {
        case .up, .left:
            offset = -1
        case .down, .right:
            offset = 1
        default:
            return
        }

        let currentIndex = responseModelIDs.firstIndex(of: draft.responsesModelID) ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), responseModelIDs.count - 1)
        guard nextIndex != currentIndex else { return }

        let nextModelID = responseModelIDs[nextIndex]
        draft.responsesModelID = nextModelID
        focusedResponseModelID = nextModelID
    }

    private func answerControls(compact: Bool) -> some View {
        VStack(spacing: 0) {
            settingRow("Формат", compact: compact) {
                formatControl(compact: compact)
            }

            settingRow("Краткий ответ", compact: compact) {
                wordLimitField(
                    value: $draft.briefAnswerMaxWords,
                    range: 20...120,
                    compact: compact,
                    accessibilityLabel: "Максимальная длина краткого ответа"
                )
            }

            settingRow(compact ? "Подробный" : "Подробный ответ", compact: compact) {
                wordLimitField(
                    value: $draft.detailedAnswerMaxWords,
                    range: 60...300,
                    compact: compact,
                    accessibilityLabel: "Максимальная длина подробного ответа"
                )
            }

            settingRow("Совет", compact: compact) {
                wordLimitField(
                    value: $draft.adviceMaxWords,
                    range: 10...80,
                    compact: compact,
                    accessibilityLabel: "Максимальная длина совета"
                )
            }

            settingRow(compact ? "Лимит" : "Лимит на звонок", compact: compact) {
                spendLimitField(compact: compact)
            }
        }
    }

    private func formatControl(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach([AnswerStyle.brief, .detailed], id: \.self) { style in
                Button {
                    draft.answerStyle = style
                } label: {
                    Text(style == .brief ? "Кратко" : "Подробнее")
                        .font(.system(size: compact ? 11 : 13, weight: draft.answerStyle == style ? .medium : .regular))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(SettingsFormatButtonStyle(isSelected: draft.answerStyle == style))
            }
        }
        .padding(3)
        .frame(width: 248, height: MainWindowTheme.controlHeight)
        .background(
            MainWindowTheme.controlSoft,
            in: RoundedRectangle(
                cornerRadius: MainWindowTheme.radiusControl,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Формат ответа")
    }

    private func settingRow<Control: View>(
        _ title: String,
        compact: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: compact ? 9 : 16) {
            Text(title)
                .font(.system(size: compact ? 12 : 13, weight: .regular))
                .lineLimit(1)

            Spacer(minLength: 8)

            control()
        }
        .frame(
            minHeight: compact ? 38 : MainWindowTheme.settingsGridRowHeight,
            maxHeight: compact ? 38 : MainWindowTheme.settingsGridRowHeight
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: MainWindowTheme.radiusControl,
                style: .continuous
            )
        )
    }

    private func wordLimitField(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        compact: Bool,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: compact ? 5 : 7) {
            Text("до")

            TextField("0", value: bounded(value, in: range), format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 13 : 14, weight: .regular).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, compact ? 5 : 7)
                .frame(width: 75, height: MainWindowTheme.controlHeight)
                .mainWindowFieldSurface(cornerRadius: MainWindowTheme.radiusSmall)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue("\(value.wrappedValue) слов")

            Text("слов")
        }
        .font(.system(size: compact ? 11 : 13, weight: .regular))
        .foregroundStyle(MainWindowTheme.secondaryText)
    }

    private func spendLimitField(compact: Bool) -> some View {
        HStack(spacing: compact ? 5 : 7) {
            TextField(
                "0",
                value: $draft.perCallSpendLimitUSD,
                format: .number.precision(.fractionLength(0...2))
            )
            .textFieldStyle(.plain)
            .font(.system(size: compact ? 13 : 14, weight: .regular).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, compact ? 5 : 7)
            .frame(width: 75, height: MainWindowTheme.controlHeight)
            .mainWindowFieldSurface(cornerRadius: MainWindowTheme.radiusSmall)
            .accessibilityLabel("Лимит на звонок, USD")

            Text("USD")
        }
        .font(.system(size: compact ? 11 : 13, weight: .regular))
        .foregroundStyle(MainWindowTheme.secondaryText)
    }

    private func saveFooter(compact: Bool) -> some View {
        HStack(spacing: 20) {
            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark")
                    .font(.system(size: compact ? 12 : 13, weight: .regular))
                    .foregroundStyle(MainWindowTheme.secondaryText)
                    .lineLimit(2)
                    .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 12)

            Button("Сохранить настройки") {
                saveConfiguration()
            }
            .buttonStyle(SettingsSaveButtonStyle(compact: compact))
        }
        .padding(.horizontal, compact ? 5 : 4)
        .frame(minHeight: compact ? 36 : 38)
    }

    private func bounded(
        _ source: Binding<Int>,
        in range: ClosedRange<Int>
    ) -> Binding<Int> {
        Binding(
            get: { source.wrappedValue },
            set: { newValue in
                source.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    private var responseModelIDs: [String] {
        let preferredOrder = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        return preferredOrder.filter {
            OpenAIModelCatalog.current.supports($0, for: .responses)
        }
    }

    private var apiKeyPlaceholder: String {
        guard apiKey.isEmpty else { return "sk-…" }

        switch store.credentialState {
        case .available:
            // This is deliberately a placeholder, not the persisted secret:
            // the draft stays empty, so Save remains disabled until the user
            // types a replacement key.
            return "••••••••••••••••"
        case .unknown, .missing:
            return "sk-…"
        }
    }

    private var credentialStatus: (title: String, color: Color) {
        switch store.credentialState {
        case .unknown:
            return ("Статус неизвестен", MainWindowTheme.deckSecondary)
        case .missing:
            return ("Ключ не сохранён", MainWindowTheme.deckSecondary)
        case .available:
            return ("Ключ сохранён", MainWindowTheme.deckLevelActive)
        }
    }

    private var credentialDescription: String {
        switch store.credentialState {
        case .unknown:
            return "Состояние ключа неизвестно. Keychain и пароль macOS не используются."
        case .missing:
            return "Ключ не сохранён; live-анализ отключён. После сохранения он останется в локальном файле с правами только вашего пользователя."
        case .available:
            return "Ключ хранится в локальном файле с правами только вашего пользователя. Keychain и пароль macOS не используются."
        }
    }

    private func saveConfiguration() {
        do {
            // Settings intentionally omitted from this screen remain in the
            // complete draft and are persisted unchanged.
            try store.updateConfiguration(draft)
            draft = store.configuration
            statusMessage = "Настройки сохранены"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func saveKey() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.saveAPIKey(apiKey)
            apiKey = ""
            statusMessage = "API key сохранён локально"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func deleteKey() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.deleteAPIKey()
            apiKey = ""
            statusMessage = "API key удалён"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func testConnection() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let typed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = typed.isEmpty ? try await store.loadAPIKey() : typed
            guard let key else {
                statusMessage = "Сначала сохраните или введите API key"
                return
            }
            try await OpenAIConnectionTester().test(apiKey: key)
            statusMessage = "Подключение к OpenAI работает"
        } catch {
            statusMessage = "Проверка не прошла: \(error.localizedDescription)"
        }
    }
}

private struct SettingsDeckButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case quiet
    }

    let kind: Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: kind == .primary ? .medium : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? 0 : compact ? 11 : 13)
            .frame(
                minHeight: MainWindowTheme.controlHeight,
                maxHeight: MainWindowTheme.controlHeight
            )
            .background(
                background(configuration: configuration),
                in: RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusControl,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusControl,
                    style: .continuous
                )
            )
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foreground: Color {
        kind == .primary ? MainWindowTheme.deck : MainWindowTheme.deckText
    }

    private func background(configuration: Configuration) -> Color {
        switch kind {
        case .primary:
            return MainWindowTheme.deckText.opacity(configuration.isPressed ? 0.78 : 1)
        case .secondary:
            return configuration.isPressed
                ? MainWindowTheme.deckControlHover
                : MainWindowTheme.deckControl
        case .quiet:
            return configuration.isPressed ? MainWindowTheme.deckControl : .clear
        }
    }
}

private struct SettingsFormatButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .background(
                isSelected
                    ? MainWindowTheme.controlSurface
                    : configuration.isPressed
                        ? Color.primary.opacity(0.05)
                        : Color.clear,
                in: RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusSmall,
                    style: .continuous
                )
            )
            .shadow(color: isSelected ? Color.black.opacity(0.10) : .clear, radius: 2, y: 1)
    }
}

private struct SettingsModelRadioButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(
                isSelected
                    ? MainWindowTheme.controlSoft
                    : configuration.isPressed
                        ? Color.primary.opacity(0.06)
                        : Color.clear
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusSmall,
                    style: .continuous
                )
                .strokeBorder(
                    isFocused
                        ? MainWindowTheme.primaryAction.opacity(0.55)
                        : Color.clear,
                    lineWidth: 1.5
                )
                .padding(2)
            }
    }
}

private struct SettingsSaveButtonStyle: ButtonStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(
                .system(
                    size: MainWindowTheme.primaryActionFontSize,
                    weight: .medium
                )
            )
            .foregroundStyle(MainWindowTheme.canvas)
            .frame(
                width: MainWindowTheme.primaryActionWidth,
                height: MainWindowTheme.fieldHeight
            )
            .background(
                MainWindowTheme.primaryAction.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusField,
                    style: .continuous
                )
            )
    }
}
