import Foundation

enum RecordingProcessingLabel: String, Equatable, Sendable {
    case processing
    case ready
    case failed

    var title: String {
        switch self {
        case .processing: "Обработка"
        case .ready: "Готово"
        case .failed: "Ошибка"
        }
    }
}

struct RecordingArtifactStatus: Equatable, Sendable {
    let label: RecordingProcessingLabel
    let detail: String
}

struct RecordingPostCallPresentation: Equatable, Sendable {
    let transcription: RecordingArtifactStatus
    let finalAnalysis: RecordingArtifactStatus?
    let canRetryPostCallProcessing: Bool

    var overallLabel: RecordingProcessingLabel {
        if transcription.label == .failed || finalAnalysis?.label == .failed {
            return .failed
        }
        if transcription.label == .processing || finalAnalysis?.label == .processing {
            return .processing
        }
        return .ready
    }

    static func make(for recording: Recording) -> Self {
        guard let metadata = recording.transcription else {
            return Self(
                transcription: RecordingArtifactStatus(
                    label: .ready,
                    detail: "Сохранённая транскрибация"
                ),
                finalAnalysis: nil,
                canRetryPostCallProcessing: false
            )
        }

        let canRetryReconciliation = Self.retryable(metadata.reconciliationStatus)
        let transcription = Self.transcriptionStatus(metadata.reconciliationStatus)
        let finalAnalysis: RecordingArtifactStatus

        guard metadata.reconciliationStatus == .complete else {
            finalAnalysis = RecordingArtifactStatus(
                label: transcription.label,
                detail: transcription.label == .processing
                    ? "Ожидает готовой транскрибации"
                    : "Ожидает повторной обработки транскрибации"
            )
            return Self(
                transcription: transcription,
                finalAnalysis: finalAnalysis,
                canRetryPostCallProcessing: canRetryReconciliation
            )
        }

        switch metadata.finalAnalysisStatus {
        case .waitingForReconciliation, .pending, .running:
            finalAnalysis = RecordingArtifactStatus(
                label: .processing,
                detail: "Анализируем вопросы собеседника"
            )
        case .complete:
            finalAnalysis = RecordingArtifactStatus(
                label: .ready,
                detail: "Итоговые ответы готовы"
            )
        case .blockedByCredential:
            finalAnalysis = RecordingArtifactStatus(
                label: .failed,
                detail: "Для анализа нужен API key"
            )
        case .blockedBySpendLimit:
            finalAnalysis = RecordingArtifactStatus(
                label: .failed,
                detail: "Анализ остановлен лимитом расходов"
            )
        case .contextLimitExceeded:
            finalAnalysis = RecordingArtifactStatus(
                label: .failed,
                detail: "Диалог превышает контекст модели"
            )
        case .failed:
            finalAnalysis = RecordingArtifactStatus(
                label: .failed,
                detail: "Не удалось завершить итоговый анализ"
            )
        }

        return Self(
            transcription: transcription,
            finalAnalysis: finalAnalysis,
            canRetryPostCallProcessing: Self.retryable(metadata.finalAnalysisStatus)
        )
    }

    private static func transcriptionStatus(
        _ status: ReconciliationStatus
    ) -> RecordingArtifactStatus {
        switch status {
        case .pending, .running:
            return RecordingArtifactStatus(
                label: .processing,
                detail: "Готовим точную транскрибацию"
            )
        case .complete:
            return RecordingArtifactStatus(
                label: .ready,
                detail: "Транскрибация завершена"
            )
        case .blockedByCredential:
            return RecordingArtifactStatus(
                label: .failed,
                detail: "Для обработки нужен API key"
            )
        case .blockedBySpendLimit:
            return RecordingArtifactStatus(
                label: .failed,
                detail: "Обработка остановлена лимитом расходов"
            )
        case .incomplete:
            return RecordingArtifactStatus(
                label: .failed,
                detail: "Транскрибация неполная"
            )
        case .failed:
            return RecordingArtifactStatus(
                label: .failed,
                detail: "Не удалось завершить транскрибацию"
            )
        }
    }

    private static func retryable(_ status: ReconciliationStatus) -> Bool {
        switch status {
        case .blockedByCredential, .blockedBySpendLimit, .failed:
            return true
        case .pending, .running, .complete, .incomplete:
            return false
        }
    }

    private static func retryable(_ status: FinalAnalysisStatus) -> Bool {
        switch status {
        case .blockedByCredential, .blockedBySpendLimit, .failed:
            return true
        case .waitingForReconciliation, .pending, .running,
             .contextLimitExceeded, .complete:
            return false
        }
    }
}
