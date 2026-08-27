using AICallAssistant.Core.Models;

namespace AICallAssistant.Desktop.ViewModels;

public enum AudioExportKind
{
    Combined,
    Incoming,
    Outgoing
}

public sealed record UiBootstrapState(
    IReadOnlyList<CallContext> Contexts,
    IReadOnlyList<Recording> Recordings,
    AppSettings Settings,
    bool HasApiKey);

public sealed record AudioSourceCatalogState(
    IReadOnlyList<AudioSourceOption> IncomingSources,
    IReadOnlyList<AudioSourceOption> Microphones);

public sealed record CallStartOptions(
    AudioSourceOption IncomingSource,
    AudioSourceOption Microphone,
    IReadOnlyList<CallContext> SelectedContexts,
    AppSettings Settings);

public sealed record PlaybackUiState(
    Guid? RecordingId,
    bool IsPlaying,
    TimeSpan Elapsed,
    TimeSpan Duration,
    double Progress);

public sealed record LiveSessionSnapshot(
    TimeSpan Elapsed,
    bool IsCallActive,
    string? Error,
    string IncomingStatus,
    string OutgoingStatus,
    string GuidanceStatus,
    GuidanceCard? CurrentGuidance,
    IReadOnlyList<TranscriptTurn> Transcript,
    IReadOnlyList<GuidanceCard> History);

public interface IUiAppCoordinator
{
    event Action<LiveSessionSnapshot>? LiveSnapshotChanged;
    event Action<Recording>? RecordingChanged;

    Task<UiBootstrapState> LoadAsync(CancellationToken cancellationToken = default);
    Task<AudioSourceCatalogState> RefreshAudioSourcesAsync(CancellationToken cancellationToken = default);
    Task SaveContextsAsync(IReadOnlyList<CallContext> contexts, CancellationToken cancellationToken = default);
    Task<ContextFileAttachment> ExtractContextFileAsync(string path, CancellationToken cancellationToken = default);
    Task StartCallAsync(CallStartOptions options, CancellationToken cancellationToken = default);
    Task<Recording?> EndCallAsync(CancellationToken cancellationToken = default);
    Task SaveSettingsAsync(AppSettings settings, CancellationToken cancellationToken = default);
    Task SaveApiKeyAsync(string apiKey, CancellationToken cancellationToken = default);
    Task DeleteApiKeyAsync(CancellationToken cancellationToken = default);
    Task TestApiKeyAsync(string? apiKey, CancellationToken cancellationToken = default);
    Task<PlaybackUiState> TogglePlaybackAsync(Recording recording, CancellationToken cancellationToken = default);
    Task<PlaybackUiState> SeekPlaybackAsync(Recording recording, double progress, CancellationToken cancellationToken = default);
    Task ExportAudioAsync(Recording recording, AudioExportKind kind, string destinationPath, CancellationToken cancellationToken = default);
    Task OpenTranscriptAsync(Recording recording, CancellationToken cancellationToken = default);
    Task RevealRecordingAsync(Recording recording, CancellationToken cancellationToken = default);
    Task RetryPostCallProcessingAsync(Recording recording, CancellationToken cancellationToken = default);
}

public sealed class AudioExportRequestedEventArgs : EventArgs
{
    public AudioExportRequestedEventArgs(Recording recording, AudioExportKind kind, string suggestedFileName)
    {
        Recording = recording;
        Kind = kind;
        SuggestedFileName = suggestedFileName;
    }

    public Recording Recording { get; }
    public AudioExportKind Kind { get; }
    public string SuggestedFileName { get; }
}
