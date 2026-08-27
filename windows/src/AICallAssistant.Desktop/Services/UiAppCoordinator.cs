using System.Diagnostics;
using System.Text;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;
using AICallAssistant.Desktop.ViewModels;
using NAudio.Wave;

namespace AICallAssistant.Desktop.Services;

public sealed class UiAppCoordinator : IUiAppCoordinator, IAsyncDisposable
{
    private const string InterruptedProcessingMessage =
        "Обработка была прервана; нажмите повторить";

    private static readonly HashSet<string> AllowedAudioExtensions = new(
        [".m4a", ".wav", ".mp3", ".mp4"],
        StringComparer.OrdinalIgnoreCase);

    private readonly IContextLibraryStore _contexts;
    private readonly ISettingsStore _settings;
    private readonly IRecordingStore _recordings;
    private readonly ISecretStore _secrets;
    private readonly IOpenAIService _openAI;
    private readonly IAudioCaptureService _audio;
    private readonly CallSessionController _callSession;
    private readonly Action<Recording> _recordingCreatedHandler;
    private readonly SemaphoreSlim _playbackGate = new(1, 1);
    private WaveOut? _waveOut;
    private AudioFileReader? _audioReader;
    private Guid? _playingRecordingId;
    private int _disposed;

    public UiAppCoordinator(
        IContextLibraryStore contexts,
        ISettingsStore settings,
        IRecordingStore recordings,
        ISecretStore secrets,
        IOpenAIService openAI,
        IAudioCaptureService audio,
        CallSessionController callSession)
    {
        _contexts = contexts;
        _settings = settings;
        _recordings = recordings;
        _secrets = secrets;
        _openAI = openAI;
        _audio = audio;
        _callSession = callSession;
        _recordingCreatedHandler = OnRecordingCreated;
        _callSession.Changed += OnCallSessionChanged;
        _callSession.RecordingCreated += _recordingCreatedHandler;
    }

    public event Action<LiveSessionSnapshot>? LiveSnapshotChanged;
    public event Action<Recording>? RecordingChanged;

    public async Task<UiBootstrapState> LoadAsync(CancellationToken cancellationToken = default)
    {
        var contextsTask = _contexts.LoadAsync(cancellationToken);
        var recordingsTask = _recordings.LoadAllAsync(cancellationToken);
        var settingsTask = _settings.LoadAsync(cancellationToken);
        var credentialTask = _secrets.HasSecretAsync(cancellationToken);
        await Task.WhenAll(contextsTask, recordingsTask, settingsTask, credentialTask).ConfigureAwait(false);
        var recordings = await recordingsTask.ConfigureAwait(false);
        foreach (var recording in recordings.Where(
                     static recording => recording.Status == ProcessingStatus.Processing))
        {
            cancellationToken.ThrowIfCancellationRequested();
            recording.Status = ProcessingStatus.Failed;
            recording.LastError = InterruptedProcessingMessage;
            await _recordings.SaveAsync(recording, cancellationToken).ConfigureAwait(false);
        }

        return new UiBootstrapState(
            await contextsTask.ConfigureAwait(false),
            recordings,
            await settingsTask.ConfigureAwait(false),
            await credentialTask.ConfigureAwait(false));
    }

    public async Task<AudioSourceCatalogState> RefreshAudioSourcesAsync(
        CancellationToken cancellationToken = default)
    {
        var incomingTask = _audio.GetIncomingSourcesAsync(cancellationToken);
        var microphoneTask = _audio.GetMicrophonesAsync(cancellationToken);
        await Task.WhenAll(incomingTask, microphoneTask).ConfigureAwait(false);
        return new AudioSourceCatalogState(
            await incomingTask.ConfigureAwait(false),
            await microphoneTask.ConfigureAwait(false));
    }

    public Task SaveContextsAsync(
        IReadOnlyList<CallContext> contexts,
        CancellationToken cancellationToken = default) =>
        _contexts.SaveAsync(contexts, cancellationToken);

    public async Task<ContextFileAttachment> ExtractContextFileAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        var key = await RequireApiKeyAsync(cancellationToken).ConfigureAwait(false);
        var settings = await _settings.LoadAsync(cancellationToken).ConfigureAwait(false);
        return await _openAI.ExtractContextFileAsync(
            key,
            path,
            settings,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task StartCallAsync(
        CallStartOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        var started = await _callSession.StartAsync(
            options.IncomingSource,
            options.Microphone,
            options.SelectedContexts,
            options.Settings,
            cancellationToken).ConfigureAwait(false);
        if (!started)
        {
            var snapshot = _callSession.Snapshot;
            throw new InvalidOperationException(snapshot.Error ?? "Не удалось начать звонок.");
        }
    }

    public Task<Recording?> EndCallAsync(CancellationToken cancellationToken = default) =>
        _callSession.StopAsync(cancellationToken);

    public Task SaveSettingsAsync(
        AppSettings settings,
        CancellationToken cancellationToken = default)
    {
        settings.Validate();
        return _settings.SaveAsync(settings, cancellationToken);
    }

    public Task SaveApiKeyAsync(string apiKey, CancellationToken cancellationToken = default) =>
        _secrets.WriteSecretAsync(apiKey.Trim(), cancellationToken);

    public Task DeleteApiKeyAsync(CancellationToken cancellationToken = default) =>
        _secrets.DeleteSecretAsync(cancellationToken);

    public async Task TestApiKeyAsync(
        string? apiKey,
        CancellationToken cancellationToken = default)
    {
        var effective = string.IsNullOrWhiteSpace(apiKey)
            ? await RequireApiKeyAsync(cancellationToken).ConfigureAwait(false)
            : apiKey.Trim();
        await _openAI.TestConnectionAsync(effective, cancellationToken).ConfigureAwait(false);
    }

    public async Task<PlaybackUiState> TogglePlaybackAsync(
        Recording recording,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(recording);
        ThrowIfDisposed();
        await _playbackGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_playingRecordingId == recording.Id && _waveOut is not null && _audioReader is not null)
            {
                if (_waveOut.PlaybackState == PlaybackState.Playing)
                {
                    _waveOut.Pause();
                }
                else
                {
                    _waveOut.Play();
                }
                return PlaybackStateFor(recording.Id);
            }

            DisposePlaybackLocked();
            var path = ResolvePlayableAudioPath(recording);
            AudioFileReader? reader = null;
            WaveOut? output = null;
            var published = false;
            try
            {
                reader = new AudioFileReader(path);
                output = new WaveOut();
                output.Init(reader);
                output.PlaybackStopped += OnPlaybackStopped;

                _audioReader = reader;
                _waveOut = output;
                _playingRecordingId = recording.Id;
                published = true;

                output.Play();
                return PlaybackStateFor(recording.Id);
            }
            catch
            {
                if (published)
                {
                    DisposePlaybackLocked();
                }
                else
                {
                    try
                    {
                        if (output is not null)
                        {
                            output.PlaybackStopped -= OnPlaybackStopped;
                            output.Dispose();
                        }
                    }
                    finally
                    {
                        reader?.Dispose();
                    }
                }
                throw;
            }
        }
        finally
        {
            _playbackGate.Release();
        }
    }

    public async Task<PlaybackUiState> SeekPlaybackAsync(
        Recording recording,
        double progress,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(recording);
        ThrowIfDisposed();
        await _playbackGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (_playingRecordingId != recording.Id || _audioReader is null)
            {
                return new PlaybackUiState(recording.Id, false, TimeSpan.Zero, recording.Duration, 0);
            }

            var clamped = Math.Clamp(progress, 0, 1);
            _audioReader.CurrentTime = TimeSpan.FromTicks((long)(_audioReader.TotalTime.Ticks * clamped));
            return PlaybackStateFor(recording.Id);
        }
        finally
        {
            _playbackGate.Release();
        }
    }

    public Task ExportAudioAsync(
        Recording recording,
        AudioExportKind kind,
        string destinationPath,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var sourcePath = ResolveAudioPath(recording, kind);
        var fullDestination = Path.GetFullPath(destinationPath);
        var directory = Path.GetDirectoryName(fullDestination)
            ?? throw new InvalidOperationException("Не удалось определить папку назначения.");
        Directory.CreateDirectory(directory);
        File.Copy(sourcePath, fullDestination, true);
        return Task.CompletedTask;
    }

    public async Task OpenTranscriptAsync(
        Recording recording,
        CancellationToken cancellationToken = default)
    {
        var folder = _recordings.GetFolderPath(recording);
        var transcriptPath = Path.Combine(folder, "transcript.txt");
        if (!File.Exists(transcriptPath))
        {
            var builder = new StringBuilder();
            foreach (var turn in recording.Turns.OrderBy(turn => turn.Offset))
            {
                var speaker = turn.Speaker == TranscriptSpeaker.Participant ? "Собеседник" : "Вы";
                builder.Append('[').Append(turn.Offset.ToString(@"hh\:mm\:ss")).Append("] ")
                    .Append(speaker).Append(": ").AppendLine(turn.Text);
            }
            await File.WriteAllTextAsync(
                transcriptPath,
                builder.ToString(),
                new UTF8Encoding(false),
                cancellationToken).ConfigureAwait(false);
        }

        StartShellProcess(transcriptPath);
    }

    public Task RevealRecordingAsync(
        Recording recording,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var folder = _recordings.GetFolderPath(recording);
        var metadata = Path.Combine(folder, "metadata.json");
        var arguments = File.Exists(metadata)
            ? $"/select,\"{metadata}\""
            : $"\"{folder}\"";
        Process.Start(new ProcessStartInfo("explorer.exe", arguments)
        {
            UseShellExecute = true
        });
        return Task.CompletedTask;
    }

    public Task RetryPostCallProcessingAsync(
        Recording recording,
        CancellationToken cancellationToken = default) =>
        _callSession.RetryPostProcessingAsync(recording, cancellationToken);

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _callSession.Changed -= OnCallSessionChanged;
        _callSession.RecordingCreated -= _recordingCreatedHandler;
        try
        {
            await _playbackGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            try
            {
                DisposePlaybackLocked();
            }
            finally
            {
                _playbackGate.Release();
            }
        }
        finally
        {
            await _callSession.DisposeAsync().ConfigureAwait(false);
        }
    }

    private void OnCallSessionChanged(CallSessionSnapshot snapshot)
    {
        LiveSnapshotChanged?.Invoke(new LiveSessionSnapshot(
            snapshot.Elapsed,
            snapshot.State is CallRunState.Preparing or CallRunState.Running or CallRunState.Finalizing,
            snapshot.Error,
            snapshot.IncomingStatus,
            snapshot.OutgoingStatus,
            snapshot.GuidanceStatus,
            snapshot.Guidance.LastOrDefault(),
            snapshot.Turns,
            snapshot.Guidance));
    }

    private void OnRecordingCreated(Recording recording) => RecordingChanged?.Invoke(recording);

    private async Task<string> RequireApiKeyAsync(CancellationToken cancellationToken)
    {
        var key = await _secrets.ReadSecretAsync(cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(key))
        {
            throw new InvalidOperationException("Добавьте OpenAI API key в настройках.");
        }
        return key;
    }

    private string ResolvePlayableAudioPath(Recording recording)
    {
        var candidates = new[]
        {
            recording.CombinedAudioFileName,
            recording.IncomingAudioFileName,
            recording.OutgoingAudioFileName
        };
        var folder = _recordings.GetFolderPath(recording);
        foreach (var fileName in candidates.Where(name => !string.IsNullOrWhiteSpace(name)))
        {
            var path = ResolveMetadataAudioPath(folder, fileName!);
            if (File.Exists(path))
            {
                return path;
            }
        }
        throw new FileNotFoundException("У записи нет доступного аудиофайла.");
    }

    private string ResolveAudioPath(Recording recording, AudioExportKind kind)
    {
        var fileName = kind switch
        {
            AudioExportKind.Combined => recording.CombinedAudioFileName
                ?? throw new FileNotFoundException("Общая дорожка недоступна."),
            AudioExportKind.Incoming => recording.IncomingAudioFileName,
            AudioExportKind.Outgoing => recording.OutgoingAudioFileName,
            _ => throw new ArgumentOutOfRangeException(nameof(kind))
        };
        var path = ResolveMetadataAudioPath(_recordings.GetFolderPath(recording), fileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException("Аудиофайл не найден.", path);
        }
        return path;
    }

    private static string ResolveMetadataAudioPath(string recordingFolder, string? fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName) ||
            fileName is "." or ".." ||
            Path.IsPathRooted(fileName) ||
            fileName.IndexOfAny(['/', '\\', ':']) >= 0 ||
            !string.Equals(Path.GetFileName(fileName), fileName, StringComparison.Ordinal) ||
            !AllowedAudioExtensions.Contains(Path.GetExtension(fileName)))
        {
            throw new InvalidDataException("Недопустимое имя аудиофайла в метаданных записи.");
        }

        var fullFolder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(recordingFolder));
        var fullPath = Path.GetFullPath(Path.Combine(fullFolder, fileName));
        var folderPrefix = fullFolder + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(folderPrefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Аудиофайл находится вне папки записи.");
        }

        return fullPath;
    }

    private PlaybackUiState PlaybackStateFor(Guid recordingId)
    {
        var reader = _audioReader;
        var output = _waveOut;
        if (reader is null || output is null)
        {
            return new PlaybackUiState(recordingId, false, TimeSpan.Zero, TimeSpan.Zero, 0);
        }
        var duration = reader.TotalTime;
        var elapsed = reader.CurrentTime;
        var progress = duration > TimeSpan.Zero
            ? Math.Clamp(elapsed.TotalSeconds / duration.TotalSeconds, 0, 1)
            : 0;
        return new PlaybackUiState(
            recordingId,
            output.PlaybackState == PlaybackState.Playing,
            elapsed,
            duration,
            progress);
    }

    private void OnPlaybackStopped(object? sender, StoppedEventArgs eventArgs)
    {
        _ = eventArgs;
        _ = CleanupPlaybackAfterStopAsync(sender);
    }

    private async Task CleanupPlaybackAfterStopAsync(object? sender)
    {
        try
        {
            await _playbackGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
            try
            {
                if (ReferenceEquals(sender, _waveOut))
                {
                    DisposePlaybackLocked();
                }
            }
            finally
            {
                _playbackGate.Release();
            }
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Не удалось освободить ресурсы воспроизведения: {error}");
        }
    }

    private void DisposePlaybackLocked()
    {
        var output = _waveOut;
        var reader = _audioReader;
        _waveOut = null;
        _audioReader = null;
        _playingRecordingId = null;

        if (output is not null)
        {
            output.PlaybackStopped -= OnPlaybackStopped;
        }

        try
        {
            output?.Dispose();
        }
        finally
        {
            reader?.Dispose();
        }
    }

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);

    private static void StartShellProcess(string path)
    {
        Process.Start(new ProcessStartInfo(path)
        {
            UseShellExecute = true
        });
    }
}
