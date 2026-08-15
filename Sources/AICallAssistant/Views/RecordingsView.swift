import SwiftUI

struct RecordingsView: View {
    let recordings: [Recording]
    @Binding var selectedRecordingID: UUID?
    let storagePath: String
    let playingRecordingID: UUID?

    let onTogglePlayback: (Recording) -> Void
    let onDownload: (Recording, RecordingAudioExport) -> Void
    let onOpenTranscript: (Recording) -> Void
    let onRevealTranscript: (Recording) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if recordings.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    recordingList
                    Divider()
                    recordingDetail
                }
                .assistantCard()
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AssistantTheme.windowBackground)
        .navigationTitle("Записи")
        .onAppear {
            if selectedRecordingID == nil {
                selectedRecordingID = recordings.first?.id
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Записи")
                    .font(.system(size: 24, weight: .semibold))

                Text("Записи звонков и готовые файлы транскрибации.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(storagePath, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AssistantTheme.subtleSurface, in: Capsule())
                .help(storagePath)
                .accessibilityLabel("Папка записей: \(storagePath)")
        }
    }

    private var recordingList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ВСЕ ЗВОНКИ")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.top, 12)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(recordings) { recording in
                        Button {
                            selectedRecordingID = recording.id
                        } label: {
                            RecordingListRow(
                                recording: recording,
                                isSelected: selectedRecording?.id == recording.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Показывает файлы этой записи")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 200, idealWidth: 228, maxWidth: 260)
        .background(AssistantTheme.subtleSurface)
    }

    @ViewBuilder
    private var recordingDetail: some View {
        if let recording = selectedRecording {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recording.title)
                            .font(.title3.weight(.semibold))

                        Text(recording.startedAt, format: .dateTime.day().month(.wide).year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    RecordingAudioRow(
                        duration: recording.duration,
                        isPlaying: playingRecordingID == recording.id,
                        onTogglePlayback: { onTogglePlayback(recording) },
                        onDownload: { onDownload(recording, $0) }
                    )

                    Label {
                        Text("\(storagePath)/\(recording.folderName)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help("\(storagePath)/\(recording.folderName)")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Транскрибация")
                            .font(.headline)

                        TranscriptFileRow(
                            participantCount: participantCount(for: recording),
                            onOpen: { onOpenTranscript(recording) },
                            onRevealInFinder: { onRevealTranscript(recording) }
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            Text("Выберите запись")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Записей пока нет")
                .font(.headline)

            Text("После завершения звонка здесь появятся аудиофайлы и transcript.txt.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var selectedRecording: Recording? {
        recordings.first(where: { $0.id == selectedRecordingID }) ?? recordings.first
    }

    private func participantCount(for recording: Recording) -> Int {
        recording.turns.isEmpty ? 0 : 2
    }
}
