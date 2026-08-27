using AICallAssistant.Core.Models;

namespace AICallAssistant.Core.Contracts;

public sealed record AudioCaptureRequest(
    AudioSourceOption IncomingSource,
    AudioSourceOption Microphone,
    string FolderPath);

public sealed record AudioFrame(
    AudioTrack Track,
    ReadOnlyMemory<byte> Pcm16Mono24Khz,
    TimeSpan Offset,
    double Rms);

public sealed record AudioCaptureResult(
    string IncomingPath,
    string OutgoingPath,
    string? CombinedPath,
    TimeSpan Duration,
    IReadOnlyList<string> Warnings);

public interface IAudioCaptureService : IAsyncDisposable
{
    bool IsCapturing { get; }
    event Action<AudioFrame>? FrameCaptured;
    event Action<Exception>? CaptureFailed;

    Task<IReadOnlyList<AudioSourceOption>> GetIncomingSourcesAsync(
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<AudioSourceOption>> GetMicrophonesAsync(
        CancellationToken cancellationToken = default);

    Task StartAsync(
        AudioCaptureRequest request,
        CancellationToken cancellationToken = default);

    Task<AudioCaptureResult> StopAsync(CancellationToken cancellationToken = default);
}

public interface ISecretStore
{
    Task<bool> HasSecretAsync(CancellationToken cancellationToken = default);
    Task<string?> ReadSecretAsync(CancellationToken cancellationToken = default);
    Task WriteSecretAsync(string value, CancellationToken cancellationToken = default);
    Task DeleteSecretAsync(CancellationToken cancellationToken = default);
}

public interface IContextLibraryStore
{
    Task<IReadOnlyList<CallContext>> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(IEnumerable<CallContext> contexts, CancellationToken cancellationToken = default);
}

public interface ISettingsStore
{
    Task<AppSettings> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(AppSettings settings, CancellationToken cancellationToken = default);
}

public interface IRecordingStore
{
    string RootPath { get; }
    Task<IReadOnlyList<Recording>> LoadAllAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(Recording recording, CancellationToken cancellationToken = default);
    string GetFolderPath(Recording recording);
}

public interface IOpenAIService
{
    Task TestConnectionAsync(string apiKey, CancellationToken cancellationToken = default);

    Task<ContextFileAttachment> ExtractContextFileAsync(
        string apiKey,
        string path,
        AppSettings settings,
        CancellationToken cancellationToken = default);

    Task<GuidanceCard?> CreateGuidanceAsync(
        string apiKey,
        IReadOnlyList<TranscriptTurn> turns,
        IReadOnlyList<CallContext> contexts,
        TranscriptTurn trigger,
        AppSettings settings,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<TranscriptTurn>> TranscribeRecordingAsync(
        string apiKey,
        string incomingPath,
        string outgoingPath,
        AppSettings settings,
        CancellationToken cancellationToken = default);

    Task<FinalAnalysis> CreateFinalAnalysisAsync(
        string apiKey,
        IReadOnlyList<TranscriptTurn> turns,
        IReadOnlyList<CallContext> contexts,
        AppSettings settings,
        CancellationToken cancellationToken = default);
}

public interface IRealtimeTranscriptionSession : IAsyncDisposable
{
    AudioTrack Track { get; }
    event Action<TranscriptTurn>? TurnCompleted;
    event Action<string>? PartialTranscriptChanged;
    event Action<Exception>? Failed;

    Task ConnectAsync(
        string apiKey,
        AppSettings settings,
        CancellationToken cancellationToken = default);

    ValueTask AppendAudioAsync(
        ReadOnlyMemory<byte> pcm16Mono24Khz,
        CancellationToken cancellationToken = default);

    Task CommitAsync(CancellationToken cancellationToken = default);

    Task DisconnectAsync(CancellationToken cancellationToken = default);
}
