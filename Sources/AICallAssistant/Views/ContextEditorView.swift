import SwiftUI

struct ContextEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let isEditing: Bool
    private let onSave: (String, String) -> Void

    @State private var title: String
    @State private var bodyText: String
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case body
    }

    init(context: CallContext? = nil, onSave: @escaping (String, String) -> Void) {
        isEditing = context != nil
        self.onSave = onSave
        _title = State(initialValue: context?.title ?? "")
        _bodyText = State(initialValue: context?.body ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isEditing ? "Контекст" : "Новый контекст")
                    .font(.title2.weight(.semibold))

                Text("Добавьте факты и материалы, которые ассистент должен учитывать во время звонка.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Название")
                    .font(.subheadline.weight(.medium))

                TextField("Например, Вакансия Product Manager", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)
                    .accessibilityLabel("Название контекста")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Содержимое")
                    .font(.subheadline.weight(.medium))

                TextEditor(text: $bodyText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 180)
                    .background(AssistantTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(AssistantTheme.separator)
                    }
                    .focused($focusedField, equals: .body)
                    .accessibilityLabel("Содержимое контекста")
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Отмена") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Сохранить") {
                    onSave(trimmedTitle, trimmedBody)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityHint("Сохраняет контекст и закрывает форму")
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            focusedField = .title
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBody: String {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && !trimmedBody.isEmpty
    }
}
