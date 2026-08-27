import SwiftUI

/// A compact master-detail library. The left pane is for scanning and choosing;
/// the quiet workspace on the right is for reading before opening the editor.
struct ContextLibraryView: View {
    let contexts: [CallContext]
    let onCreateContext: () -> Void
    let onOpenContext: (CallContext) -> Void
    let onDeleteContext: (CallContext) -> Void

    @State private var searchText = ""
    @State private var selectedContextID: UUID?
    @State private var contextPendingDeletion: CallContext?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline(color: AssistantTheme.separator)

            HStack(spacing: 0) {
                masterPane
                    .frame(minWidth: 270, idealWidth: 300, maxWidth: 330)

                Hairline(axis: .vertical, color: AssistantTheme.separator)

                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AssistantTheme.windowBackground)
        .navigationTitle("Контексты")
        .onAppear { reconcileSelection() }
        .onChange(of: contexts.map(\.id)) { _ in
            reconcileSelection()
        }
        .onChange(of: searchText) { _ in
            reconcileSelection(preferFilteredResult: true)
        }
        .confirmationDialog(
            "Удалить контекст?",
            isPresented: deletionDialogBinding,
            titleVisibility: .visible,
            presenting: contextPendingDeletion
        ) { context in
            Button("Удалить «\(context.title)»", role: .destructive) {
                onDeleteContext(context)
                contextPendingDeletion = nil
            }
            Button("Отмена", role: .cancel) {
                contextPendingDeletion = nil
            }
        } message: { _ in
            Text("Это действие нельзя отменить.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Контексты")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                Text(contextCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            searchField

            Button(action: onCreateContext) {
                Label("Новый контекст", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("n", modifiers: .command)
            .help("Добавить контекст")
            .accessibilityHint("Открывает форму создания контекста")
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(AssistantTheme.surface)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Поиск", text: $searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Поиск контекстов")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 220, height: 30)
        .background(
            AssistantTheme.rowHover,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private var masterPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(searchQuery.isEmpty ? "ВСЕ КОНТЕКСТЫ" : "РЕЗУЛЬТАТЫ")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.65)
                    .foregroundStyle(.secondary)

                Spacer()

                if selectedCallContextCount > 0 {
                    Label("\(selectedCallContextCount)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AssistantTheme.accent)
                        .accessibilityLabel("Для звонка выбрано: \(selectedCallContextCount)")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            if filteredContexts.isEmpty {
                masterEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredContexts) { context in
                            ContextMasterRow(
                                context: context,
                                isCurrent: selectedContextID == context.id,
                                onSelect: { selectedContextID = context.id },
                                onOpen: { onOpenContext(context) },
                                onDelete: { contextPendingDeletion = context }
                            )

                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(AssistantTheme.subtleSurface)
    }

    private var masterEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(searchQuery.isEmpty ? "Контекстов пока нет" : "Ничего не найдено")
                .font(.system(size: 13, weight: .semibold))

            Text(searchQuery.isEmpty
                 ? "Добавьте материалы для будущих звонков."
                 : "Попробуйте изменить запрос.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if searchQuery.isEmpty {
                Button("Добавить контекст", action: onCreateContext)
                    .buttonStyle(.link)
            } else {
                Button("Очистить поиск") { searchText = "" }
                    .buttonStyle(.link)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedContext {
            ContextLibraryDetail(
                context: selectedContext,
                onOpen: { onOpenContext(selectedContext) },
                onDelete: { contextPendingDeletion = selectedContext }
            )
        } else {
            VStack(spacing: 9) {
                Image(systemName: contexts.isEmpty ? "doc.text" : "sidebar.left")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(contexts.isEmpty ? "Добавьте первый контекст" : "Выберите контекст")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AssistantTheme.canvas)
        }
    }

    private var filteredContexts: [CallContext] {
        guard !searchQuery.isEmpty else { return contexts }
        return contexts.filter { context in
            context.title.localizedCaseInsensitiveContains(searchQuery)
                || context.body.localizedCaseInsensitiveContains(searchQuery)
                || context.attachments.contains {
                    $0.fileName.localizedCaseInsensitiveContains(searchQuery)
                }
        }
    }

    private var selectedContext: CallContext? {
        guard let selectedContextID else { return nil }
        return contexts.first { $0.id == selectedContextID }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedCallContextCount: Int {
        contexts.lazy.filter(\.isSelected).count
    }

    private var contextCountText: String {
        switch contexts.count {
        case 1: return "1 контекст"
        case 2...4: return "\(contexts.count) контекста"
        default: return "\(contexts.count) контекстов"
        }
    }

    private func reconcileSelection(preferFilteredResult: Bool = false) {
        let visibleIDs = Set(filteredContexts.map(\.id))
        if preferFilteredResult, !searchQuery.isEmpty,
           selectedContextID.map({ !visibleIDs.contains($0) }) ?? true {
            selectedContextID = filteredContexts.first?.id
        } else if selectedContextID.map({ id in contexts.contains { $0.id == id } }) != true {
            selectedContextID = filteredContexts.first?.id ?? contexts.first?.id
        }
    }

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { contextPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { contextPendingDeletion = nil }
            }
        )
    }
}

private struct ContextMasterRow: View {
    let context: CallContext
    let isCurrent: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.title)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let attachmentCountText {
                        Label(attachmentCountText, systemImage: "paperclip")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if context.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AssistantTheme.accent)
                        .padding(.top, 2)
                        .help("Используется в звонке")
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(
                rowBackground,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(pressedOpacity: 0.75))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
        .contextMenu {
            Button("Редактировать", action: onOpen)
            Divider()
            Button("Удалить", role: .destructive, action: onDelete)
        }
        .accessibilityLabel(context.title)
        .accessibilityValue(context.isSelected ? "Используется в звонке" : "Не используется в звонке")
        .accessibilityHint("Выбирает контекст для просмотра; правый клик — редактировать или удалить")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .help("Показать «\(context.title)»")
    }

    private var rowBackground: Color {
        if isCurrent { return AssistantTheme.accentSoft }
        return isHovered ? AssistantTheme.rowHover : Color.clear
    }

    private var summary: String {
        let text = context.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Без описания" : text
    }

    private var attachmentCountText: String? {
        switch context.attachments.count {
        case 0: return nil
        case 1: return "1 файл"
        case 2...4: return "\(context.attachments.count) файла"
        default: return "\(context.attachments.count) файлов"
        }
    }
}

private struct ContextLibraryDetail: View {
    let context: CallContext
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(AssistantTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(AssistantTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                    Text(context.title)
                        .font(.system(size: 28, weight: .bold))
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)

                    Label(
                        context.isSelected ? "Используется в звонке" : "Не используется в звонке",
                        systemImage: context.isSelected ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(context.isSelected ? AssistantTheme.accent : AssistantTheme.secondaryText)
                    }
                }

                Spacer(minLength: 16)

                Button("Редактировать", action: onOpen)
                    .buttonStyle(.borderedProminent)

                Menu {
                    Button("Удалить", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Действия с контекстом \(context.title)")
            }
            .padding(.horizontal, 28)
            .frame(height: 94)
            .background(AssistantTheme.surface)

            Hairline(color: AssistantTheme.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    detailSection(title: "Описание") {
                        Text(bodyDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(context.body.isEmpty ? AssistantTheme.secondaryText : Color.primary)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    detailSection(title: "Файлы") {
                        if context.attachments.isEmpty {
                            Text("Нет прикреплённых файлов")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(context.attachments) { attachment in
                                    HStack(spacing: 9) {
                                        Image(systemName: "doc")
                                            .foregroundStyle(AssistantTheme.secondaryText)
                                            .frame(width: 16)

                                        Text(attachment.fileName)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        Spacer()

                                        Text(ByteCountFormatter.string(
                                            fromByteCount: Int64(attachment.byteCount),
                                            countStyle: .file
                                        ))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(height: 38)

                                    if attachment.id != context.attachments.last?.id {
                                        Hairline()
                                            .padding(.leading, 35)
                                    }
                                }
                            }
                            .background(
                                AssistantTheme.surface,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(AssistantTheme.canvas)
    }

    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            content()
        }
    }

    private var bodyDescription: String {
        context.body.isEmpty ? "Описание не добавлено." : context.body
    }
}
