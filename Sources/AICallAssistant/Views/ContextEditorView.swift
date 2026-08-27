import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContextEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let isEditing: Bool
    private let onExtractFile: (URL) async throws -> ContextFileAttachment
    private let onSave: (String, String, [ContextFileAttachment]) -> Void

    @State private var title: String
    @State private var bodyText: String
    @State private var files: [ContextFileDraft]
    @State private var extractionTasks: [UUID: Task<Void, Never>] = [:]
    @State private var isFileImporterPresented = false
    @State private var fileImporterErrorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case body
    }

    init(
        context: CallContext? = nil,
        onExtractFile: @escaping (URL) async throws -> ContextFileAttachment,
        onSave: @escaping (String, String, [ContextFileAttachment]) -> Void
    ) {
        isEditing = context != nil
        self.onExtractFile = onExtractFile
        self.onSave = onSave
        _title = State(initialValue: context?.title ?? "")
        _bodyText = State(initialValue: context?.body ?? "")
        _files = State(
            initialValue: (context?.attachments ?? []).map(ContextFileDraft.init)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Hairline(color: AssistantTheme.contentHairline)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    editorFields

                    attachmentSection
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .top)
            }

            Hairline(color: AssistantTheme.contentHairline)

            editorFooter
        }
        .frame(
            minWidth: 620,
            idealWidth: 660,
            maxWidth: 680,
            minHeight: 560,
            idealHeight: 620,
            maxHeight: 650
        )
        .background(MainWindowTheme.canvas)
        .tint(MainWindowTheme.primaryAction)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: Self.supportedFileTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileSelection
        )
        .onAppear {
            focusedField = .title
        }
        .onDisappear {
            extractionTasks.values.forEach { $0.cancel() }
            extractionTasks.removeAll()
        }
    }

    private var editorHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text(isEditing ? "Редактировать контекст" : "Новый контекст")
                    .font(.system(size: 30, weight: .medium))
                    .tracking(-0.7)
                    .accessibilityAddTraits(.isHeader)

                Text("То, что ассистент должен учитывать во время звонка")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .background(MainWindowTheme.canvas)
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Название")

                TextField("Например, Вакансия Product Manager", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .regular))
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background(
                        MainWindowTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                focusedField == .title
                                    ? MainWindowTheme.primaryAction.opacity(0.34)
                                    : AssistantTheme.contentHairline,
                                lineWidth: 1
                            )
                    }
                    .focused($focusedField, equals: .title)
                    .accessibilityLabel("Название контекста")
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Содержимое")

                TextEditor(text: $bodyText)
                    .font(.system(size: 14, weight: .regular))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 145)
                    .background(
                        MainWindowTheme.controlSurface,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(
                                focusedField == .body
                                    ? MainWindowTheme.primaryAction.opacity(0.34)
                                    : AssistantTheme.contentHairline,
                                lineWidth: 1
                            )
                    }
                    .focused($focusedField, equals: .body)
                    .accessibilityLabel("Содержимое контекста")

                Text("Можно оставить пустым, если весь контекст находится в файлах.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Отмена") {
                dismiss()
            }
            .buttonStyle(ContextSecondaryButtonStyle())
            .keyboardShortcut(.cancelAction)

            Button("Сохранить") {
                onSave(trimmedTitle, trimmedBody, readyAttachments)
                dismiss()
            }
            .buttonStyle(ContextPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
            .accessibilityHint("Сохраняет контекст и закрывает форму")
        }
        .padding(.horizontal, 28)
        .frame(height: 72)
        .background(MainWindowTheme.canvas)
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("Файлы")

                if !files.isEmpty {
                    Text("\(files.count)")
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    fileImporterErrorMessage = nil
                    isFileImporterPresented = true
                } label: {
                    Label("Добавить файлы", systemImage: "paperclip")
                }
                .buttonStyle(ContextSecondaryButtonStyle(compact: true))
            }

            if files.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(AssistantTheme.contentHairline, in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Нет прикреплённых файлов")
                            .font(.system(size: 13, weight: .medium))
                        Text("PDF, документы, презентации, таблицы и текстовые файлы · до 50 МБ")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .background(
                    MainWindowTheme.controlSurface,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(AssistantTheme.contentHairline, lineWidth: 1)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files) { file in
                            attachmentRow(file)

                            if file.id != files.last?.id {
                                Hairline()
                                    .padding(.leading, 39)
                            }
                        }
                    }
                }
                .frame(maxHeight: 172)
                .background(
                    MainWindowTheme.controlSurface,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(AssistantTheme.contentHairline, lineWidth: 1)
                }
            }

            if let fileImporterErrorMessage {
                Label(fileImporterErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasUnresolvedFiles {
                Text("Дождитесь обработки файлов или удалите файл с ошибкой.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func attachmentRow(_ file: ContextFileDraft) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AssistantTheme.secondaryText)
                .frame(width: 32, height: 32)
                .background(AssistantTheme.contentHairline, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(file.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                attachmentStatus(file)
            }

            Spacer(minLength: 8)

            if case .failed = file.status, file.sourceURL != nil {
                Button {
                    startExtraction(for: file.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(ContextIconButtonStyle())
                .help("Повторить обработку")
                .accessibilityLabel("Повторить обработку файла \(file.fileName)")
            }

            Button {
                removeFile(file.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ContextIconButtonStyle())
            .help("Удалить файл")
            .accessibilityLabel("Удалить файл \(file.fileName)")
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 54)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary.opacity(0.86))
    }

    @ViewBuilder
    private func attachmentStatus(_ file: ContextFileDraft) -> some View {
        switch file.status {
        case .ready:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(MainWindowTheme.ready)
                Text(file.formattedSize)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10.5, weight: .regular))
        case .extracting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Извлекаем текст через OpenAI…")
            }
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            fileImporterErrorMessage = nil
            for url in urls where !containsPendingFile(at: url) {
                let draft = ContextFileDraft(url: url)
                files.append(draft)
                startExtraction(for: draft.id)
            }
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else { return }
            fileImporterErrorMessage = "Не удалось выбрать файлы: \(error.localizedDescription)"
        }
    }

    private func startExtraction(for id: UUID) {
        extractionTasks[id]?.cancel()
        guard let index = files.firstIndex(where: { $0.id == id }),
              let url = files[index].sourceURL else {
            return
        }
        files[index].status = .extracting

        extractionTasks[id] = Task { @MainActor in
            defer { extractionTasks[id] = nil }
            do {
                let attachment = try await onExtractFile(url)
                try Task.checkCancellation()
                guard let currentIndex = files.firstIndex(where: { $0.id == id }) else {
                    return
                }
                files[currentIndex].attachment = attachment
                files[currentIndex].status = .ready
            } catch is CancellationError {
                return
            } catch {
                guard let currentIndex = files.firstIndex(where: { $0.id == id }) else {
                    return
                }
                files[currentIndex].attachment = nil
                files[currentIndex].status = .failed(error.localizedDescription)
            }
        }
    }

    private func removeFile(_ id: UUID) {
        extractionTasks[id]?.cancel()
        extractionTasks[id] = nil
        files.removeAll { $0.id == id }
    }

    private func containsPendingFile(at url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        return files.contains { $0.sourceURL?.standardizedFileURL == candidate }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBody: String {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var readyAttachments: [ContextFileAttachment] {
        files.compactMap { file in
            guard case .ready = file.status else { return nil }
            return file.attachment
        }
    }

    private var hasUnresolvedFiles: Bool {
        files.contains { file in
            switch file.status {
            case .ready:
                return false
            case .extracting, .failed:
                return true
            }
        }
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
            && (!trimmedBody.isEmpty || !readyAttachments.isEmpty)
            && !hasUnresolvedFiles
    }

    private static let supportedFileTypes: [UTType] = [
        "pdf", "txt", "md", "json", "html", "htm", "xml",
        "doc", "docx", "rtf", "odt", "ppt", "pptx",
        "csv", "tsv", "xls", "xlsx",
        "c", "cpp", "css", "go", "java", "js", "jsx", "py",
        "rb", "sh", "sql", "swift", "ts", "tsx", "yaml", "yml"
    ].compactMap { UTType(filenameExtension: $0) }
}

private struct ContextPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? MainWindowTheme.canvas : Color.secondary)
            .padding(.horizontal, 20)
            .frame(minWidth: 110, minHeight: 42)
            .background(
                MainWindowTheme.primaryAction.opacity(
                    isEnabled ? (configuration.isPressed ? 0.76 : 1) : 0.12
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct ContextSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(.primary.opacity(0.88))
            .padding(.horizontal, compact ? 12 : 18)
            .frame(minHeight: compact ? 36 : 42)
            .background(
                configuration.isPressed
                    ? MainWindowTheme.selectedRow
                    : MainWindowTheme.controlSurface,
                in: RoundedRectangle(cornerRadius: compact ? 10 : 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 10 : 11, style: .continuous)
                    .strokeBorder(AssistantTheme.contentHairline, lineWidth: 1)
            }
            .contentShape(
                RoundedRectangle(cornerRadius: compact ? 10 : 11, style: .continuous)
            )
    }
}

private struct ContextIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(
                configuration.isPressed ? MainWindowTheme.selectedRow : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ContextFileDraft: Identifiable {
    enum Status {
        case ready
        case extracting
        case failed(String)
    }

    let id: UUID
    let sourceURL: URL?
    let fileName: String
    let byteCount: Int?
    var attachment: ContextFileAttachment?
    var status: Status

    init(_ attachment: ContextFileAttachment) {
        id = attachment.id
        sourceURL = nil
        fileName = attachment.fileName
        byteCount = attachment.byteCount
        self.attachment = attachment
        status = .ready
    }

    init(url: URL) {
        id = UUID()
        sourceURL = url
        fileName = url.lastPathComponent
        byteCount = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        attachment = nil
        status = .extracting
    }

    var formattedSize: String {
        guard let byteCount else { return "Текст извлечён" }
        return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
