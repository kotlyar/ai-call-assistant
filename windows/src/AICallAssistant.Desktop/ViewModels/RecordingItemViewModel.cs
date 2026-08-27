using AICallAssistant.Core.Models;

namespace AICallAssistant.Desktop.ViewModels;

public sealed class RecordingItemViewModel : ObservableObject
{
    public RecordingItemViewModel(Recording model)
    {
        Model = model;
    }

    public Recording Model { get; private set; }
    public Guid Id => Model.Id;
    public string Title => Model.Title;
    public string DateText => Model.StartedAt.ToLocalTime().ToString("d MMM, HH:mm");
    public string MetadataText => $"{Model.StartedAt.ToLocalTime():d MMMM yyyy, HH:mm} · {DurationText}";
    public string DurationText => FormatDuration(Model.Duration);
    public string FolderName => Model.FolderName;
    public IReadOnlyList<TranscriptTurn> Turns => Model.Turns;
    public IReadOnlyList<GuidanceCard> AnalysisCards => Model.Analysis?.QuestionAnswers ?? [];
    public string AnalysisSummary => Model.Analysis?.Summary ?? string.Empty;
    public string ErrorText => Model.LastError ?? string.Empty;
    public bool HasTranscript => Model.Turns.Count > 0;
    public bool HasAnalysis => Model.Analysis is not null;

    public string StatusText => Model.Status switch
    {
        ProcessingStatus.LocalOnly => "Локально",
        ProcessingStatus.Processing => "Обработка",
        ProcessingStatus.Ready => "Готово",
        ProcessingStatus.WaitingForCredential => "Нужен API key",
        ProcessingStatus.Failed => "Ошибка",
        _ => "Неизвестно"
    };

    public string StatusTone => Model.Status switch
    {
        ProcessingStatus.Ready => "Success",
        ProcessingStatus.Failed => "Danger",
        ProcessingStatus.WaitingForCredential => "Warning",
        ProcessingStatus.Processing => "Warning",
        _ => "Neutral"
    };

    public bool CanRetry => Model.Status is ProcessingStatus.Failed or ProcessingStatus.WaitingForCredential;

    public void Replace(Recording model)
    {
        Model = model;
        OnPropertyChanged(nameof(Model));
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(DateText));
        OnPropertyChanged(nameof(MetadataText));
        OnPropertyChanged(nameof(DurationText));
        OnPropertyChanged(nameof(FolderName));
        OnPropertyChanged(nameof(Turns));
        OnPropertyChanged(nameof(AnalysisCards));
        OnPropertyChanged(nameof(AnalysisSummary));
        OnPropertyChanged(nameof(ErrorText));
        OnPropertyChanged(nameof(HasTranscript));
        OnPropertyChanged(nameof(HasAnalysis));
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(StatusTone));
        OnPropertyChanged(nameof(CanRetry));
    }

    public static string FormatDuration(TimeSpan duration) => duration.TotalHours >= 1
        ? $"{(int)duration.TotalHours}:{duration.Minutes:00}:{duration.Seconds:00}"
        : $"{(int)duration.TotalMinutes:00}:{duration.Seconds:00}";
}
