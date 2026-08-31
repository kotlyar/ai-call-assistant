import Foundation
import SwiftUI

/// The single-window call hub.
///
/// Audio, context selection, recordings and settings all begin here. Contexts
/// stay visible instead of becoming a navigation destination; secondary work
/// is presented by the stable root view as a popover or sheet.
struct SetupView: View {
    @StateObject private var audioLevelMonitor = PreflightAudioLevelMonitor()
    @State private var isHandingOffToCall = false
    @State private var monitorRevision = 0

    @Binding var incomingSource: AudioSourceOption
    @Binding var outgoingSource: AudioSourceOption

    let incomingSources: [AudioSourceOption]
    let outgoingSources: [AudioSourceOption]
    let contexts: [CallContext]
    let recordings: [Recording]
    let isDiscoveringAudioSources: Bool
    let isPreparingAudio: Bool
    let isFinalizingAudio: Bool
    let isCallRunning: Bool
    let audioSetupError: String?
    let audioPermissions: AudioPermissionSnapshot
    let openAICredentialState: OpenAICredentialState
    @Binding var isRecordingsPresented: Bool

    let onToggleContextSelection: (CallContext) -> Void
    let onCreateContext: () -> Void
    let onOpenContext: (CallContext) -> Void
    let onDeleteContext: (CallContext) -> Void
    let onRefreshAudioSources: () async -> Void
    let onOpenAudioPermissions: () -> Void
    let onOpenSettings: () -> Void
    let onOpenRecording: (Recording) -> Void
    let onStartCall: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 840

            VStack(spacing: 0) {
                titlebar
                MainWindowPageHeader(
                    title: "Новый звонок",
                    subtitle: "Проверьте источники звука и начинайте."
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 18 : 22) {
                        audioDeck(compact: compact)

                        if let visibleAudioSetupError {
                            Label(visibleAudioSetupError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(AssistantTheme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        contextLibrary
                    }
                    .frame(
                        maxWidth: MainWindowTheme.contentMaxWidth,
                        alignment: .topLeading
                    )
                    .padding(
                        .horizontal,
                        compact ? 28 : MainWindowTheme.pageHorizontalInset
                    )
                    .padding(.top, MainWindowTheme.pageContentTopSpacing)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .background(MainWindowTheme.canvas)
        .task {
            await onRefreshAudioSources()
        }
        .task(id: monitorConfigurationID) {
            await audioLevelMonitor.stop()
            guard shouldMonitorAudio else { return }
            await audioLevelMonitor.configure(
                microphone: outgoingSource,
                monitorMicrophone: canMonitorMicrophone
            )
        }
        .onDisappear {
            Task { await audioLevelMonitor.stop() }
        }
    }

    private var titlebar: some View {
        MainWindowTitlebar {
            Button {
                isRecordingsPresented.toggle()
            } label: {
                Image(systemName: "clock")
                    .frame(
                        width: MainWindowTheme.toolbarControlSize,
                        height: MainWindowTheme.toolbarControlSize
                    )
            }
            .buttonStyle(MainWindowToolbarButtonStyle())
            .popover(isPresented: $isRecordingsPresented, arrowEdge: .top) {
                RecordingsPopoverView(
                    recordings: recordings,
                    onOpenRecording: onOpenRecording
                )
            }
            .help("Записи")
            .accessibilityLabel("Записи")

            Button(action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
                    .frame(
                        width: MainWindowTheme.toolbarControlSize,
                        height: MainWindowTheme.toolbarControlSize
                    )
            }
            .buttonStyle(MainWindowToolbarButtonStyle())
            .help("Настройки")
            .accessibilityLabel("Настройки")
        }
    }

    private func audioDeck(compact: Bool) -> some View {
        VStack(spacing: 0) {
            MainWindowDeckHeader(title: "Звук звонка") {
                Button {
                    Task { await onRefreshAudioSources() }
                } label: {
                    Group {
                        if isDiscoveringAudioSources {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MainWindowTheme.deckText)
                    .tint(MainWindowTheme.deckText)
                    .frame(
                        width: MainWindowTheme.deckHeaderControlSize,
                        height: MainWindowTheme.deckHeaderControlSize
                    )
                }
                .buttonStyle(DeckQuietButtonStyle())
                .disabled(isDiscoveringAudioSources)
                .help("Обновить источники звука")
                .accessibilityLabel("Обновить источники звука")
            }

            HubAudioSourceRow(
                label: "Микрофон",
                systemImage: "mic",
                options: outgoingSources,
                selection: $outgoingSource,
                permission: audioPermissions.microphone,
                authorizedText: "Доступ разрешён",
                missingText: "Микрофон не найден",
                compact: compact,
                level: audioLevelMonitor.microphoneLevel,
                showsLiveLevel: true,
                onOpenPermissions: onOpenAudioPermissions
            )

            HubAudioSourceRow(
                label: "Звук собеседника",
                systemImage: "waveform",
                options: incomingSources,
                selection: $incomingSource,
                permission: audioPermissions.systemAudio,
                authorizedText: "Системный звук подключён",
                missingText: "Источник звука не найден",
                compact: compact,
                level: 0,
                showsLiveLevel: false,
                onOpenPermissions: onOpenAudioPermissions
            )

            HStack(spacing: 14) {
                Button(action: onOpenSettings) {
                    HStack(spacing: 10) {
                        Image(systemName: credentialIcon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(
                                width: MainWindowTheme.deckHeaderControlSize,
                                height: MainWindowTheme.deckHeaderControlSize
                            )
                            .background(MainWindowTheme.deckText, in: Circle())
                            .foregroundStyle(MainWindowTheme.deck)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Live-анализ")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(MainWindowTheme.deckText)
                            Text(credentialStatus)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundStyle(MainWindowTheme.deckSecondary)
                        }
                    }
                }
                .buttonStyle(DeckQuietButtonStyle())

                Spacer(minLength: 12)

                Button {
                    Task { @MainActor in
                        guard !isHandingOffToCall else { return }
                        isHandingOffToCall = true
                        await audioLevelMonitor.stop()
                        onStartCall()

                        // The coordinator starts its async preparation on the
                        // next main-actor turn. This fallback also restarts the
                        // meters if that preparation exits before publishing a
                        // busy/running state.
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        isHandingOffToCall = false
                        if !isPreparingAudio, !isFinalizingAudio, !isCallRunning {
                            monitorRevision &+= 1
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        if isHandingOffToCall || isPreparingAudio || isFinalizingAudio {
                            ProgressView()
                                .controlSize(.small)
                            Text(isFinalizingAudio ? "Сохраняем…" : "Подключаем…")
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                            Text("Начать звонок")
                            Text("⌘↩")
                                .font(.system(size: 11, weight: .regular).monospaced())
                                .foregroundStyle(MainWindowTheme.deck.opacity(0.58))
                        }
                    }
                    .font(
                        .system(
                            size: MainWindowTheme.primaryActionFontSize,
                            weight: .medium
                        )
                    )
                    .frame(
                        width: compact ? 128 : MainWindowTheme.primaryActionWidth,
                        height: MainWindowTheme.prominentActionHeight
                    )
                }
                .buttonStyle(HubStartButtonStyle())
                .disabled(!canStart)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Начинает запись и открывает окно live-ассистента")
            }
            .padding(
                .horizontal,
                compact ? 20 : MainWindowTheme.deckHorizontalInset
            )
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .mainWindowDeckSurface()
    }

    private var contextLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Контексты")
                    .font(.system(size: MainWindowTheme.sectionTitleSize, weight: .medium))
                    .tracking(MainWindowTheme.sectionTitleTracking)

                Text("\(selectedContextCount) выбрано")
                    .font(.system(size: 12, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: onCreateContext) {
                    Label("Новый контекст", systemImage: "plus")
                        .font(.system(size: 13, weight: .regular))
                        .padding(.horizontal, 9)
                        .frame(height: MainWindowTheme.compactActionHeight)
                }
                .buttonStyle(HubQuietButtonStyle())
            }
            .padding(.horizontal, 4)

            if contexts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Контекстов пока нет")
                        .font(.system(size: 15, weight: .medium))
                    Text("Добавьте роль, опыт или вопросы — новый контекст сразу будет выбран.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                    Button(action: onCreateContext) {
                        Label("Добавить контекст", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: MainWindowTheme.compactActionHeight)
                    }
                    .buttonStyle(HubQuietButtonStyle())
                }
                .padding(18)
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(contexts) { context in
                        HubContextRow(
                            context: context,
                            onToggle: { onToggleContextSelection(context) },
                            onOpen: { onOpenContext(context) },
                            onDelete: { onDeleteContext(context) }
                        )
                    }
                }
            }
        }
    }

    private var canStart: Bool {
        !isDiscoveringAudioSources
            && !isPreparingAudio
            && !isFinalizingAudio
            && !isCallRunning
            && !isHandingOffToCall
            && !outgoingSources.isEmpty
    }

    private var canMonitorMicrophone: Bool {
        audioPermissions.microphone == .authorized
            && outgoingSources.contains(where: { $0.id == outgoingSource.id })
    }

    private var shouldMonitorAudio: Bool {
        !isDiscoveringAudioSources
            && !isPreparingAudio
            && !isFinalizingAudio
            && !isCallRunning
            && !isHandingOffToCall
            && canMonitorMicrophone
    }

    /// SwiftUI cancels and recreates the monitor task whenever a selected
    /// device, permission or call-lifecycle state changes.
    private var monitorConfigurationID: String {
        [
            outgoingSource.id,
            canMonitorMicrophone ? "microphone-on" : "microphone-off",
            isDiscoveringAudioSources ? "discovering" : "discovered",
            isPreparingAudio ? "preparing" : "idle-preparation",
            isFinalizingAudio ? "finalizing" : "idle-finalization",
            isCallRunning ? "running" : "not-running",
            "revision-\(monitorRevision)"
        ].joined(separator: "|")
    }

    private var selectedContextCount: Int {
        contexts.lazy.filter(\.isSelected).count
    }

    /// Permission and missing-device states already live beside the affected
    /// source. Keep this line for capture/discovery failures that add new
    /// information, rather than repeating the two source statuses below them.
    private var visibleAudioSetupError: String? {
        guard let audioSetupError else { return nil }

        let normalized = audioSetupError.lowercased()
        let permissionIsExplained =
            audioPermissions.microphone != .authorized
                || audioPermissions.systemAudio != .authorized
        if permissionIsExplained,
           normalized.contains("доступ") || normalized.contains("разреш") {
            return nil
        }
        if outgoingSources.isEmpty, normalized.contains("микрофон") {
            return nil
        }
        if incomingSources.isEmpty,
           normalized.contains("системн") || normalized.contains("источник звука") {
            return nil
        }
        return audioSetupError
    }

    private var credentialIcon: String {
        switch openAICredentialState {
        case .available: "checkmark"
        case .missing: "minus"
        case .unknown: "ellipsis"
        }
    }

    private var credentialStatus: String {
        switch openAICredentialState {
        case .available: "OpenAI подключён"
        case .missing: "Звонок запишется без подсказок"
        case .unknown: "Проверяем подключение"
        }
    }
}

private struct HubAudioSourceRow: View {
    let label: String
    let systemImage: String
    let options: [AudioSourceOption]
    @Binding var selection: AudioSourceOption
    let permission: AudioPermissionStatus
    let authorizedText: String
    let missingText: String
    let compact: Bool
    let level: Double
    let showsLiveLevel: Bool
    let onOpenPermissions: () -> Void

    var body: some View {
        HStack(spacing: compact ? 14 : 20) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 48, height: 48)
                .background(MainWindowTheme.deckControl, in: Circle())
                .foregroundStyle(MainWindowTheme.deckText)

            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(MainWindowTheme.deckSecondary)

                if options.isEmpty {
                    Text("Источник не найден")
                        .font(.system(size: compact ? 17 : 20, weight: .medium))
                        .foregroundStyle(MainWindowTheme.deckText.opacity(0.68))
                } else {
                    Menu {
                        ForEach(options) { option in
                            Button {
                                selection = option
                            } label: {
                                if option.id == selection.id {
                                    Label(option.title, systemImage: "checkmark")
                                } else {
                                    Text(option.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(selection.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(MainWindowTheme.deckSecondary)
                        }
                        .font(.system(size: compact ? 17 : 20, weight: .medium))
                        .foregroundStyle(MainWindowTheme.deckText)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(MainWindowTheme.deckText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: onOpenPermissions) {
                    HStack(spacing: 6) {
                        MainWindowStatusDot(color: statusColor)
                        Text(statusText)
                    }
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(permission == .authorized ? MainWindowTheme.deckSecondary : AssistantTheme.amber)
                }
                .buttonStyle(DeckQuietButtonStyle())
                .disabled(permission == .authorized && !options.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if showsLiveLevel {
                    HubSegmentedLevelMeter(
                        level: level,
                        label: "Уровень: \(label.lowercased())",
                        segmentCount: compact ? 8 : 11
                    )
                } else {
                    HStack(spacing: 9) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 18, weight: .regular))
                        Text("Включится со звонком")
                            .font(.system(size: 11, weight: .regular))
                    }
                    .foregroundStyle(MainWindowTheme.deckSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Системный звук включится после начала звонка")
                }
            }
                .frame(
                    width: compact ? 128 : MainWindowTheme.primaryActionWidth,
                    height: 58
                )
        }
        .padding(
            .horizontal,
            compact ? 20 : MainWindowTheme.deckHorizontalInset
        )
        .frame(minHeight: compact ? 84 : 94)
        .accessibilityElement(children: .contain)
    }

    private var statusText: String {
        if options.isEmpty { return missingText }
        switch permission {
        case .authorized: return authorizedText
        case .notDetermined: return "Нужно разрешение macOS"
        case .denied: return "Доступ запрещён — открыть настройки"
        }
    }

    private var statusColor: Color {
        options.isEmpty || permission != .authorized
            ? AssistantTheme.amber
            : MainWindowTheme.deckLevelActive
    }
}

private struct HubSegmentedLevelMeter: View {
    let level: Double
    let label: String
    let segmentCount: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index < activeSegments ? activeColor(for: index) : inactiveColor)
                    .frame(width: 10, height: 24)

                if index < segmentCount - 1 {
                    Spacer(minLength: 5)
                }
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.linear(duration: 0.08), value: activeSegments)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(clampedLevel * 100)) процентов")
    }

    private var clampedLevel: Double {
        min(max(level, 0), 1)
    }

    private var activeSegments: Int {
        guard clampedLevel > 0.018 else { return 0 }
        return min(segmentCount, max(1, Int(ceil(clampedLevel * Double(segmentCount)))))
    }

    private var inactiveColor: Color {
        MainWindowTheme.deckText.opacity(0.12)
    }

    private func activeColor(for index: Int) -> Color {
        let finalSegment = index == segmentCount - 1
        return finalSegment ? AssistantTheme.amber : MainWindowTheme.deckLevelActive
    }
}

private struct HubContextRow: View {
    let context: CallContext
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: context.isSelected ? "checkmark" : "")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(context.isSelected ? MainWindowTheme.canvas : Color.clear)
                        .frame(width: 24, height: 24)
                        .background(
                            context.isSelected ? MainWindowTheme.primaryAction : AssistantTheme.contentHairline,
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)

                        Text(summary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !context.attachments.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Text("\(context.attachments.count)")
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(attachmentAccessibilityLabel)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(context.isSelected ? "Убрать контекст" : "Выбрать контекст")
            .accessibilityValue(context.title)

            Button(action: onOpen) {
                HStack(spacing: 5) {
                    Text("Открыть")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: MainWindowTheme.compactActionHeight)
            }
            .buttonStyle(HubQuietButtonStyle())
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(
            rowBackground,
            in: RoundedRectangle(
                cornerRadius: MainWindowTheme.radiusField,
                style: .continuous
            )
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: MainWindowTheme.radiusField,
                style: .continuous
            )
        )
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Редактировать", action: onOpen)
            Divider()
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }

    private var summary: String {
        let trimmed = context.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return context.attachments.isEmpty ? "Без описания" : "Контекст находится в прикреплённых файлах"
    }

    private var attachmentAccessibilityLabel: String {
        switch context.attachments.count {
        case 0: "Нет файлов"
        case 1: "1 файл"
        case 2...4: "\(context.attachments.count) файла"
        default: "\(context.attachments.count) файлов"
        }
    }

    private var rowBackground: Color {
        if context.isSelected { return MainWindowTheme.selectedRow }
        return isHovered ? AssistantTheme.rowHover : .clear
    }
}

private struct RecordingsPopoverView: View {
    let recordings: [Recording]
    let onOpenRecording: (Recording) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Записи")
                    .font(.system(size: 20, weight: .medium))
                Spacer()
                Text("На этом Mac")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            Hairline()

            if recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("Записей пока нет")
                        .font(.system(size: 14, weight: .medium))
                    Text("После звонка здесь появятся аудио, транскрипт и анализ.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(recordings) { recording in
                            Button {
                                onOpenRecording(recording)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundStyle(MainWindowTheme.deckText)
                                        .frame(width: 42, height: 42)
                                        .background(
                                            MainWindowTheme.deck,
                                            in: RoundedRectangle(
                                                cornerRadius: MainWindowTheme.radiusControl,
                                                style: .continuous
                                            )
                                        )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recording.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Text(metadata(for: recording))
                                            .font(.system(size: 11, weight: .regular).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 62)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HubQuietButtonStyle())
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 330)
            }

            Hairline()
            Label("Записи хранятся локально", systemImage: "internaldrive")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .frame(height: 36)
        }
        .frame(width: 390)
        .background(MainWindowTheme.canvas)
    }

    private func metadata(for recording: Recording) -> String {
        let date = recording.startedAt.formatted(.relative(presentation: .named))
        return "\(date) · \(RecordingListRow.durationText(recording.duration))"
    }
}

private struct DeckQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .contentShape(Rectangle())
    }
}

private struct HubQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? AssistantTheme.contentHairline : Color.clear,
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
    }
}

private struct HubStartButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(MainWindowTheme.deck)
            .background(
                MainWindowTheme.deckText.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42),
                in: RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusProminent,
                    style: .continuous
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: MainWindowTheme.radiusProminent,
                    style: .continuous
                )
            )
    }
}
