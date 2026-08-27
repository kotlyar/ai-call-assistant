using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;
using AICallAssistant.Core.OpenAI;

namespace AICallAssistant.Desktop.Services;

public enum CallRunState
{
    Idle,
    Preparing,
    Running,
    Finalizing,
    Failed
}

public sealed record CallSessionSnapshot(
    CallRunState State,
    TimeSpan Elapsed,
    IReadOnlyList<TranscriptTurn> Turns,
    IReadOnlyList<GuidanceCard> Guidance,
    string IncomingStatus,
    string OutgoingStatus,
    string GuidanceStatus,
    string? Error,
    int SelectedContextCount);

public sealed class CallSessionController : IAsyncDisposable
{
    private const double SpeechRmsThreshold = 0.008;
    private static readonly TimeSpan MinimumVoicedDuration = TimeSpan.FromMilliseconds(160);
    private static readonly TimeSpan TurnSilenceDuration = TimeSpan.FromMilliseconds(650);

    private readonly IAudioCaptureService _audioCapture;
    private readonly ISecretStore _secretStore;
    private readonly IOpenAIService _openAI;
    private readonly IRecordingStore _recordings;
    private readonly Func<AudioTrack, IRealtimeTranscriptionSession> _realtimeFactory;
    private readonly object _gate = new();
    private readonly Stopwatch _clock = new();
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly SemaphoreSlim _guidanceSlots = new(2, 2);
    private readonly ConcurrentDictionary<Guid, Task> _guidanceTasks = new();
    private readonly ConcurrentDictionary<Guid, Task> _postProcessingTasks = new();
    private readonly ConcurrentDictionary<Guid, SemaphoreSlim> _postProcessingGates = new();
    private readonly List<TranscriptTurn> _turns = [];
    private readonly List<GuidanceCard> _guidance = [];
    private readonly List<string> _warnings = [];

    private CallRunState _state = CallRunState.Idle;
    private string _incomingStatus = "Не подключено";
    private string _outgoingStatus = "Не подключено";
    private string _guidanceStatus = "Неактивно";
    private string? _error;
    private Recording? _activeRecording;
    private IReadOnlyList<CallContext> _frozenContexts = [];
    private AppSettings _frozenSettings = new();
    private string? _activeApiKey;
    private IRealtimeTranscriptionSession? _incomingRealtime;
    private IRealtimeTranscriptionSession? _outgoingRealtime;
    private Channel<AudioFrame>? _incomingFrames;
    private Channel<AudioFrame>? _outgoingFrames;
    private Task? _incomingFrameWorker;
    private Task? _outgoingFrameWorker;
    private CancellationTokenSource? _callLifetime;
    private int _selectedContextCount;
    private long _callGeneration;
    private int _captureFailureStopStarted;
    private int _closing;
    private int _disposed;

    public CallSessionController(
        IAudioCaptureService audioCapture,
        ISecretStore secretStore,
        IOpenAIService openAI,
        IRecordingStore recordings,
        Func<AudioTrack, IRealtimeTranscriptionSession> realtimeFactory)
    {
        _audioCapture = audioCapture;
        _secretStore = secretStore;
        _openAI = openAI;
        _recordings = recordings;
        _realtimeFactory = realtimeFactory;
    }

    public event Action<CallSessionSnapshot>? Changed;
    public event Action<Recording>? RecordingCreated;

    public CallSessionSnapshot Snapshot
    {
        get
        {
            lock (_gate)
            {
                return CreateSnapshotLocked();
            }
        }
    }

    public async Task<bool> StartAsync(
        AudioSourceOption incomingSource,
        AudioSourceOption microphone,
        IReadOnlyList<CallContext> contexts,
        AppSettings settings,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(
                Volatile.Read(ref _closing) != 0 || Volatile.Read(ref _disposed) != 0,
                this);
            if (_state is not CallRunState.Idle and not CallRunState.Failed)
            {
                return false;
            }

            settings.Validate();
            lock (_gate)
            {
                _state = CallRunState.Preparing;
                _error = null;
                _turns.Clear();
                _guidance.Clear();
                _warnings.Clear();
                _incomingStatus = "Подключение…";
                _outgoingStatus = "Подключение…";
                _guidanceStatus = "Подготовка…";
                _frozenContexts = CloneContexts(contexts.Where(context => context.IsSelected));
                _frozenSettings = CloneSettings(settings);
                _selectedContextCount = _frozenContexts.Count;
                _callGeneration++;
            }
            Interlocked.Exchange(ref _captureFailureStopStarted, 0);
            Publish();

            var startedAt = DateTimeOffset.Now;
            var folderName = $"{startedAt:yyyyMMdd_HHmmss}_{Guid.NewGuid():N}";
            var folderPath = Path.Combine(_recordings.RootPath, folderName);
            Directory.CreateDirectory(folderPath);
            var recording = new Recording
            {
                Title = $"Звонок {startedAt:dd.MM.yyyy HH:mm}",
                StartedAt = startedAt,
                FolderName = folderName,
                Status = ProcessingStatus.LocalOnly,
                FrozenContexts = CloneContexts(_frozenContexts).ToList(),
                FrozenSettings = CloneSettings(_frozenSettings)
            };
            _activeRecording = recording;
            await _recordings.SaveAsync(recording, cancellationToken).ConfigureAwait(false);

            _activeApiKey = await _secretStore.ReadSecretAsync(cancellationToken).ConfigureAwait(false);
            _callLifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            if (!string.IsNullOrWhiteSpace(_activeApiKey))
            {
                try
                {
                    await StartRealtimeAsync(_activeApiKey, _frozenSettings, _callLifetime.Token)
                        .ConfigureAwait(false);
                }
                catch (Exception realtimeError)
                {
                    await StopRealtimeAsync(CancellationToken.None).ConfigureAwait(false);
                    lock (_gate)
                    {
                        _warnings.Add(realtimeError.Message);
                        _incomingStatus = "Недоступно — запись продолжается";
                        _outgoingStatus = "Недоступно — запись продолжается";
                        _guidanceStatus = "Live-подсказки недоступны";
                    }
                }
            }
            else
            {
                lock (_gate)
                {
                    _incomingStatus = "Локальная запись";
                    _outgoingStatus = "Локальная запись";
                    _guidanceStatus = "Добавьте API key после звонка";
                }
            }

            _audioCapture.FrameCaptured += OnFrameCaptured;
            _audioCapture.CaptureFailed += OnCaptureFailed;
            await _audioCapture.StartAsync(
                new AudioCaptureRequest(incomingSource, microphone, folderPath),
                cancellationToken).ConfigureAwait(false);
            _clock.Restart();
            lock (_gate)
            {
                _state = CallRunState.Running;
                if (_incomingRealtime is not null)
                {
                    _incomingStatus = "Собеседник: распознавание включено";
                    _outgoingStatus = "Вы: распознавание включено";
                    _guidanceStatus = "Слушаю вопросы";
                }
            }
            Publish();
            return true;
        }
        catch (Exception error)
        {
            _audioCapture.FrameCaptured -= OnFrameCaptured;
            _audioCapture.CaptureFailed -= OnCaptureFailed;
            await SafeStopAfterFailedStartAsync().ConfigureAwait(false);
            var failedRecording = _activeRecording;
            if (failedRecording is not null)
            {
                failedRecording.Duration = _clock.Elapsed;
                failedRecording.Status = ProcessingStatus.Failed;
                failedRecording.LastError = error.Message;
                ApplyRecoveryFileNames(failedRecording);
                try
                {
                    await _recordings.SaveAsync(failedRecording, CancellationToken.None)
                        .ConfigureAwait(false);
                    SafeNotifyRecording(failedRecording);
                }
                catch
                {
                    // Preserve the startup error shown to the user. The call
                    // folder and any partial WAV files remain recoverable.
                }
            }
            lock (_gate)
            {
                _state = CallRunState.Failed;
                _error = error.Message;
                _activeRecording = null;
            }
            _activeApiKey = null;
            Publish();
            return false;
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task<Recording?> StopAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Cancellation is honored while waiting for ownership. Once local
            // finalization begins it must run independently of the UI token.
            return await StopCoreAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task RetryPostProcessingAsync(
        Recording recording,
        CancellationToken cancellationToken = default)
    {
        var key = await _secretStore.ReadSecretAsync(cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(key))
        {
            recording.Status = ProcessingStatus.WaitingForCredential;
            recording.LastError = "Добавьте OpenAI API key в настройках.";
            await _recordings.SaveAsync(recording, cancellationToken).ConfigureAwait(false);
            return;
        }

        await ProcessRecordingAsync(recording, key, cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _closing, 1) != 0)
        {
            return;
        }

        Exception? shutdownError = null;
        await _lifecycleGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
        try
        {
            if (_activeRecording is not null)
            {
                await StopCoreAsync().ConfigureAwait(false);
            }
        }
        catch (Exception error)
        {
            shutdownError = error;
        }
        finally
        {
            _lifecycleGate.Release();
        }

        try
        {
            await StopRealtimeAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            shutdownError ??= error;
        }
        finally
        {
            try
            {
                await _audioCapture.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception error)
            {
                shutdownError ??= error;
            }
            finally
            {
                Interlocked.Exchange(ref _disposed, 1);
                _callLifetime?.Dispose();
                _callLifetime = null;
            }
        }

        if (shutdownError is not null)
        {
            throw shutdownError;
        }
    }

    private async Task<Recording?> StopCoreAsync()
    {
        var recording = _activeRecording;
        if (recording is null)
        {
            return null;
        }

        lock (_gate)
        {
            _state = CallRunState.Finalizing;
            _guidanceStatus = "Сохраняю запись…";
        }
        Publish();
        _clock.Stop();
        _audioCapture.FrameCaptured -= OnFrameCaptured;
        _audioCapture.CaptureFailed -= OnCaptureFailed;

        AudioCaptureResult? captureResult = null;
        if (_audioCapture.IsCapturing)
        {
            try
            {
                captureResult = await _audioCapture.StopAsync(CancellationToken.None)
                    .ConfigureAwait(false);
            }
            catch (Exception error)
            {
                lock (_gate)
                {
                    _warnings.Add($"Не удалось штатно финализировать аудио: {error.Message}");
                }
            }
        }

        CompleteFrameChannels();
        try
        {
            await AwaitFrameWorkersAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                _warnings.Add($"Не удалось завершить live-аудиопоток: {error.Message}");
            }
        }

        try
        {
            await CommitAndStopRealtimeAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                _warnings.Add($"Не удалось завершить live-транскрипцию: {error.Message}");
            }
        }

        _callLifetime?.Cancel();
        await AwaitGuidanceTasksAsync().ConfigureAwait(false);
        _callLifetime?.Dispose();
        _callLifetime = null;

        var apiKey = _activeApiKey;
        lock (_gate)
        {
            if (captureResult is not null)
            {
                recording.Duration = captureResult.Duration;
                recording.IncomingAudioFileName = Path.GetFileName(captureResult.IncomingPath);
                recording.OutgoingAudioFileName = Path.GetFileName(captureResult.OutgoingPath);
                recording.CombinedAudioFileName = captureResult.CombinedPath is null
                    ? null
                    : Path.GetFileName(captureResult.CombinedPath);
                _warnings.AddRange(captureResult.Warnings);
            }
            else
            {
                recording.Duration = _clock.Elapsed;
                ApplyRecoveryFileNames(recording);
            }

            recording.Turns = _turns.OrderBy(turn => turn.Offset).ToList();
            recording.LastError = _warnings.Count == 0
                ? null
                : string.Join(" ", _warnings.Distinct(StringComparer.Ordinal));
            recording.Status = string.IsNullOrWhiteSpace(apiKey)
                ? ProcessingStatus.WaitingForCredential
                : ProcessingStatus.Processing;
        }

        try
        {
            await _recordings.SaveAsync(recording, CancellationToken.None).ConfigureAwait(false);
            try
            {
                await WriteLiveTranscriptAsync(recording, CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception transcriptError)
            {
                recording.LastError = JoinError(recording.LastError, transcriptError.Message);
                await _recordings.SaveAsync(recording, CancellationToken.None).ConfigureAwait(false);
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                _state = CallRunState.Failed;
                _error = error.Message;
            }
            Publish();
            throw;
        }

        SafeNotifyRecording(recording);
        lock (_gate)
        {
            _state = CallRunState.Idle;
            _activeRecording = null;
            _incomingStatus = "Не подключено";
            _outgoingStatus = "Не подключено";
            _guidanceStatus = recording.Status == ProcessingStatus.Processing
                ? "Фоновая обработка"
                : "Ожидает API key";
        }
        _activeApiKey = null;
        Publish();

        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            TrackPostProcessing(recording, apiKey);
        }

        return recording;
    }

    private async Task StartRealtimeAsync(
        string apiKey,
        AppSettings settings,
        CancellationToken cancellationToken)
    {
        _incomingRealtime = _realtimeFactory(AudioTrack.Incoming);
        _outgoingRealtime = _realtimeFactory(AudioTrack.Outgoing);
        SubscribeRealtime(_incomingRealtime);
        SubscribeRealtime(_outgoingRealtime);
        await Task.WhenAll(
            _incomingRealtime.ConnectAsync(apiKey, settings, cancellationToken),
            _outgoingRealtime.ConnectAsync(apiKey, settings, cancellationToken)).ConfigureAwait(false);

        _incomingFrames = CreateFrameChannel();
        _outgoingFrames = CreateFrameChannel();
        _incomingFrameWorker = PumpFramesAsync(
            _incomingFrames.Reader,
            _incomingRealtime,
            cancellationToken);
        _outgoingFrameWorker = PumpFramesAsync(
            _outgoingFrames.Reader,
            _outgoingRealtime,
            cancellationToken);
    }

    private static Channel<AudioFrame> CreateFrameChannel() =>
        Channel.CreateBounded<AudioFrame>(new BoundedChannelOptions(256)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false
        });

    private async Task PumpFramesAsync(
        ChannelReader<AudioFrame> reader,
        IRealtimeTranscriptionSession session,
        CancellationToken cancellationToken)
    {
        var voicedDuration = TimeSpan.Zero;
        var silenceDuration = TimeSpan.Zero;
        try
        {
            await foreach (var frame in reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                await session.AppendAudioAsync(frame.Pcm16Mono24Khz, cancellationToken).ConfigureAwait(false);
                var frameDuration = TimeSpan.FromSeconds(
                    frame.Pcm16Mono24Khz.Length / (24_000d * sizeof(short)));
                if (frame.Rms >= SpeechRmsThreshold)
                {
                    voicedDuration += frameDuration;
                    silenceDuration = TimeSpan.Zero;
                    continue;
                }

                if (voicedDuration <= TimeSpan.Zero)
                {
                    continue;
                }

                silenceDuration += frameDuration;
                if (voicedDuration >= MinimumVoicedDuration &&
                    silenceDuration >= TurnSilenceDuration)
                {
                    await session.CommitAsync(cancellationToken).ConfigureAwait(false);
                    voicedDuration = TimeSpan.Zero;
                    silenceDuration = TimeSpan.Zero;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal shutdown.
        }
        catch (Exception error)
        {
            OnRealtimeFailed(session.Track, error);
        }
    }

    private void OnFrameCaptured(AudioFrame frame)
    {
        var channel = frame.Track == AudioTrack.Incoming ? _incomingFrames : _outgoingFrames;
        if (channel is not null && !channel.Writer.TryWrite(frame))
        {
            lock (_gate)
            {
                _warnings.Add($"Потерян live-аудиобуфер дорожки {frame.Track}.");
            }
        }
    }

    private void OnCaptureFailed(Exception error)
    {
        lock (_gate)
        {
            _error = error.Message;
            _warnings.Add(error.Message);
        }
        Publish();

        if (Interlocked.Exchange(ref _captureFailureStopStarted, 1) == 0)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await StopAsync(CancellationToken.None).ConfigureAwait(false);
                }
                catch (Exception finalizationError)
                {
                    lock (_gate)
                    {
                        _error = finalizationError.Message;
                        _warnings.Add(finalizationError.Message);
                    }
                    Publish();
                }
            });
        }
    }

    private void SubscribeRealtime(IRealtimeTranscriptionSession session)
    {
        session.TurnCompleted += OnTurnCompleted;
        session.Failed += error => OnRealtimeFailed(session.Track, error);
    }

    private void OnTurnCompleted(TranscriptTurn turn)
    {
        IReadOnlyList<TranscriptTurn> snapshot;
        string? apiKey;
        IReadOnlyList<CallContext> contexts;
        AppSettings settings;
        long generation;
        lock (_gate)
        {
            _turns.Add(turn);
            _turns.Sort((left, right) => left.Offset.CompareTo(right.Offset));
            snapshot = _turns.ToArray();
            apiKey = _activeApiKey;
            contexts = _frozenContexts;
            settings = _frozenSettings;
            generation = _callGeneration;
        }
        Publish();

        if (turn.Speaker == TranscriptSpeaker.Participant &&
            !string.IsNullOrWhiteSpace(apiKey))
        {
            var id = Guid.NewGuid();
            var task = CreateGuidanceAsync(
                id,
                generation,
                apiKey,
                contexts,
                settings,
                turn,
                snapshot,
                _callLifetime?.Token ?? CancellationToken.None);
            _guidanceTasks[id] = task;
            _ = task.ContinueWith(
                completedTask =>
                {
                    _ = completedTask.Exception;
                    _guidanceTasks.TryRemove(id, out var _);
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }
    }

    private async Task CreateGuidanceAsync(
        Guid taskId,
        long generation,
        string apiKey,
        IReadOnlyList<CallContext> contexts,
        AppSettings settings,
        TranscriptTurn trigger,
        IReadOnlyList<TranscriptTurn> turns,
        CancellationToken cancellationToken)
    {
        _ = taskId;
        try
        {
            await _guidanceSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                lock (_gate)
                {
                    if (generation == _callGeneration)
                    {
                        _guidanceStatus = "Готовлю ответ…";
                    }
                }
                Publish();
                var card = await _openAI.CreateGuidanceAsync(
                    apiKey,
                    turns,
                    contexts,
                    trigger,
                    settings,
                    cancellationToken).ConfigureAwait(false);
                if (card is not null)
                {
                    lock (_gate)
                    {
                        if (generation == _callGeneration &&
                            _state is CallRunState.Running or CallRunState.Finalizing)
                        {
                            _guidance.Add(card);
                        }
                    }
                }
            }
            finally
            {
                _guidanceSlots.Release();
            }

            lock (_gate)
            {
                if (generation == _callGeneration && _state == CallRunState.Running)
                {
                    _guidanceStatus = "Слушаю вопросы";
                }
            }
            Publish();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Call ended.
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (generation == _callGeneration)
                {
                    _guidanceStatus = "Ошибка подсказки";
                    _warnings.Add(error.Message);
                }
            }
            Publish();
        }
    }

    private void OnRealtimeFailed(AudioTrack track, Exception error)
    {
        lock (_gate)
        {
            if (track == AudioTrack.Incoming)
            {
                _incomingStatus = "Ошибка распознавания";
            }
            else
            {
                _outgoingStatus = "Ошибка распознавания";
            }
            _warnings.Add(error.Message);
        }
        Publish();
    }

    private async Task CommitAndStopRealtimeAsync(CancellationToken cancellationToken)
    {
        var sessions = new[] { _incomingRealtime, _outgoingRealtime }
            .Where(session => session is not null)
            .Cast<IRealtimeTranscriptionSession>()
            .ToArray();
        foreach (var session in sessions)
        {
            try
            {
                await session.CommitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                lock (_gate)
                {
                    _warnings.Add(error.Message);
                }
            }
        }

        if (sessions.Length > 0)
        {
            await Task.Delay(TimeSpan.FromMilliseconds(800), cancellationToken).ConfigureAwait(false);
        }
        await StopRealtimeAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task StopRealtimeAsync(CancellationToken cancellationToken)
    {
        var incoming = Interlocked.Exchange(ref _incomingRealtime, null);
        var outgoing = Interlocked.Exchange(ref _outgoingRealtime, null);
        var errors = new List<Exception>();
        foreach (var session in new[] { incoming, outgoing })
        {
            if (session is null)
            {
                continue;
            }

            try
            {
                await session.DisconnectAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                errors.Add(error);
            }
            finally
            {
                try
                {
                    await session.DisposeAsync().ConfigureAwait(false);
                }
                catch (Exception error)
                {
                    errors.Add(error);
                }
            }
        }

        if (errors.Count > 0)
        {
            throw new AggregateException("Не удалось закрыть одну или несколько Realtime-сессий.", errors);
        }
    }

    private void CompleteFrameChannels()
    {
        _incomingFrames?.Writer.TryComplete();
        _outgoingFrames?.Writer.TryComplete();
        _incomingFrames = null;
        _outgoingFrames = null;
    }

    private async Task AwaitFrameWorkersAsync()
    {
        var workers = new[] { _incomingFrameWorker, _outgoingFrameWorker }
            .Where(worker => worker is not null)
            .Cast<Task>()
            .ToArray();
        _incomingFrameWorker = null;
        _outgoingFrameWorker = null;
        if (workers.Length > 0)
        {
            await Task.WhenAll(workers).ConfigureAwait(false);
        }
    }

    private async Task SafeStopAfterFailedStartAsync()
    {
        CompleteFrameChannels();
        _callLifetime?.Cancel();
        try
        {
            if (_audioCapture.IsCapturing)
            {
                await _audioCapture.StopAsync(CancellationToken.None).ConfigureAwait(false);
            }
        }
        catch
        {
            // Preserve the original startup error.
        }

        try
        {
            await AwaitFrameWorkersAsync().ConfigureAwait(false);
        }
        catch
        {
            // Preserve the original startup error.
        }

        try
        {
            await StopRealtimeAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch
        {
            // Preserve the original startup error.
        }
        _callLifetime?.Dispose();
        _callLifetime = null;
    }

    private async Task AwaitGuidanceTasksAsync()
    {
        var tasks = _guidanceTasks.Values.ToArray();
        if (tasks.Length == 0)
        {
            return;
        }

        try
        {
            await Task.WhenAll(tasks).ConfigureAwait(false);
        }
        catch
        {
            // Each guidance task translates its own error into call status.
        }
    }

    private void TrackPostProcessing(Recording recording, string apiKey)
    {
        var task = ProcessRecordingAsync(recording, apiKey, CancellationToken.None);
        _postProcessingTasks[recording.Id] = task;
        _ = task.ContinueWith(
            completedTask =>
            {
                _ = completedTask.Exception;
                _postProcessingTasks.TryRemove(recording.Id, out var _);
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private void ApplyRecoveryFileNames(Recording recording)
    {
        var folder = _recordings.GetFolderPath(recording);
        recording.IncomingAudioFileName = FirstExistingFileName(
            folder,
            "incoming.m4a",
            "incoming.wav",
            "incoming.partial.wav") ?? recording.IncomingAudioFileName;
        recording.OutgoingAudioFileName = FirstExistingFileName(
            folder,
            "outgoing.m4a",
            "outgoing.wav",
            "outgoing.partial.wav") ?? recording.OutgoingAudioFileName;
        recording.CombinedAudioFileName = FirstExistingFileName(
            folder,
            "combined.m4a",
            "combined.wav",
            "combined.partial.wav");
    }

    private static string? FirstExistingFileName(string folder, params string[] fileNames) =>
        fileNames.FirstOrDefault(fileName => File.Exists(Path.Combine(folder, fileName)));

    private string ResolveRecordingAudioPath(Recording recording, string fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName) ||
            Path.IsPathRooted(fileName) ||
            !string.Equals(Path.GetFileName(fileName), fileName, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Метаданные записи содержат небезопасное имя аудиофайла.");
        }

        var extension = Path.GetExtension(fileName).ToLowerInvariant();
        if (extension is not (".m4a" or ".mp4" or ".wav" or ".mp3" or ".webm"))
        {
            throw new InvalidDataException("Метаданные записи содержат неподдерживаемый аудиофайл.");
        }

        var folder = Path.GetFullPath(_recordings.GetFolderPath(recording));
        var resolved = Path.GetFullPath(Path.Combine(folder, fileName));
        var prefix = Path.TrimEndingDirectorySeparator(folder) + Path.DirectorySeparatorChar;
        if (!resolved.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException("Аудиофайл находится вне папки записи.");
        }
        return resolved;
    }

    private static string JoinError(string? existing, string next) =>
        string.IsNullOrWhiteSpace(existing) ? next : $"{existing} {next}";

    private void SafeNotifyRecording(Recording recording)
    {
        var handlers = RecordingCreated;
        if (handlers is null)
        {
            return;
        }

        foreach (Action<Recording> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(recording);
            }
            catch
            {
                // A presentation subscriber cannot invalidate durable metadata.
            }
        }
    }

    private async Task ProcessRecordingAsync(
        Recording recording,
        string apiKey,
        CancellationToken cancellationToken)
    {
        var processingGate = _postProcessingGates.GetOrAdd(
            recording.Id,
            static _ => new SemaphoreSlim(1, 1));
        await processingGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            recording.Status = ProcessingStatus.Processing;
            recording.LastError = null;
            await _recordings.SaveAsync(recording, cancellationToken).ConfigureAwait(false);
            var incoming = ResolveRecordingAudioPath(recording, recording.IncomingAudioFileName);
            var outgoing = ResolveRecordingAudioPath(recording, recording.OutgoingAudioFileName);
            if (recording.Turns.Count == 0)
            {
                var canonical = await _openAI.TranscribeRecordingAsync(
                    apiKey,
                    incoming,
                    outgoing,
                    recording.FrozenSettings,
                    cancellationToken).ConfigureAwait(false);
                if (canonical.Count > 0)
                {
                    recording.Turns = canonical.ToList();
                }
            }

            await WriteCanonicalTranscriptAsync(recording, cancellationToken).ConfigureAwait(false);
            recording.Analysis = await _openAI.CreateFinalAnalysisAsync(
                apiKey,
                recording.Turns,
                recording.FrozenContexts,
                recording.FrozenSettings,
                cancellationToken).ConfigureAwait(false);
            recording.Status = ProcessingStatus.Ready;
            recording.LastError = null;
            await WriteAnalysisAsync(recording, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            recording.Status = ProcessingStatus.Failed;
            recording.LastError = "Фоновая обработка была прервана; её можно запустить повторно.";
        }
        catch (OpenAIProtocolException error) when (error.StatusCode == 401)
        {
            recording.Status = ProcessingStatus.WaitingForCredential;
            recording.LastError = "OpenAI отклонил API key. Обновите ключ и повторите обработку.";
        }
        catch (Exception error)
        {
            recording.Status = ProcessingStatus.Failed;
            recording.LastError = error.Message;
        }
        finally
        {
            try
            {
                await _recordings.SaveAsync(recording, CancellationToken.None).ConfigureAwait(false);
                SafeNotifyRecording(recording);
            }
            finally
            {
                processingGate.Release();
            }
        }
    }

    private async Task WriteLiveTranscriptAsync(Recording recording, CancellationToken cancellationToken)
    {
        var folder = _recordings.GetFolderPath(recording);
        var path = Path.Combine(folder, "transcript.live.json");
        var json = JsonSerializer.Serialize(recording.Turns, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true
        });
        await AtomicWriteTextAsync(path, json, cancellationToken).ConfigureAwait(false);
    }

    private async Task WriteCanonicalTranscriptAsync(Recording recording, CancellationToken cancellationToken)
    {
        var text = new StringBuilder();
        foreach (var turn in recording.Turns.OrderBy(turn => turn.Offset))
        {
            var speaker = turn.Speaker == TranscriptSpeaker.Participant ? "Собеседник" : "Вы";
            text.Append('[').Append(turn.Offset.ToString(@"hh\:mm\:ss")).Append("] ")
                .Append(speaker).Append(": ").AppendLine(turn.Text);
        }

        var folder = _recordings.GetFolderPath(recording);
        var primary = Path.Combine(folder, "transcript.txt");
        var destination = File.Exists(primary)
            ? Path.Combine(folder, $"transcript.generated.{DateTimeOffset.Now:yyyyMMdd_HHmmss}.txt")
            : primary;
        await AtomicWriteTextAsync(destination, text.ToString(), cancellationToken).ConfigureAwait(false);
    }

    private async Task WriteAnalysisAsync(Recording recording, CancellationToken cancellationToken)
    {
        if (recording.Analysis is null)
        {
            return;
        }

        var path = Path.Combine(_recordings.GetFolderPath(recording), "analysis.json");
        var json = JsonSerializer.Serialize(recording.Analysis, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true
        });
        await AtomicWriteTextAsync(path, json, cancellationToken).ConfigureAwait(false);
    }

    private static async Task AtomicWriteTextAsync(
        string path,
        string content,
        CancellationToken cancellationToken)
    {
        var tempPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            var bytes = new UTF8Encoding(false).GetBytes(content);
            await using (var stream = new FileStream(
                tempPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                16 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            cancellationToken.ThrowIfCancellationRequested();
            File.Move(tempPath, path, true);
            tempPath = string.Empty;
        }
        finally
        {
            if (tempPath.Length > 0)
            {
                try
                {
                    File.Delete(tempPath);
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }
    }

    private void Publish()
    {
        CallSessionSnapshot snapshot;
        lock (_gate)
        {
            snapshot = CreateSnapshotLocked();
        }
        var handlers = Changed;
        if (handlers is null)
        {
            return;
        }

        foreach (Action<CallSessionSnapshot> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(snapshot);
            }
            catch
            {
                // UI/event consumers must never break capture finalization.
            }
        }
    }

    private CallSessionSnapshot CreateSnapshotLocked() => new(
        _state,
        _clock.Elapsed,
        _turns.ToArray(),
        _guidance.ToArray(),
        _incomingStatus,
        _outgoingStatus,
        _guidanceStatus,
        _error,
        _selectedContextCount);

    private static IReadOnlyList<CallContext> CloneContexts(IEnumerable<CallContext> contexts) =>
        contexts.Select(context => new CallContext
        {
            Id = context.Id,
            Title = context.Title,
            Body = context.Body,
            IsSelected = context.IsSelected,
            Attachments = context.Attachments.Select(attachment => new ContextFileAttachment
            {
                Id = attachment.Id,
                FileName = attachment.FileName,
                MediaType = attachment.MediaType,
                ByteCount = attachment.ByteCount,
                ContentSha256 = attachment.ContentSha256,
                ExtractedText = attachment.ExtractedText
            }).ToList()
        }).ToArray();

    private static AppSettings CloneSettings(AppSettings settings) => new()
    {
        ResponsesModelId = settings.ResponsesModelId,
        RealtimeTranscriptionModelId = settings.RealtimeTranscriptionModelId,
        FileTranscriptionModelId = settings.FileTranscriptionModelId,
        TranscriptionLanguages = settings.TranscriptionLanguages.ToList(),
        AnswerStyle = settings.AnswerStyle,
        AnswerLanguage = settings.AnswerLanguage,
        BriefAnswerMaxWords = settings.BriefAnswerMaxWords,
        DetailedAnswerMaxWords = settings.DetailedAnswerMaxWords,
        AdviceMaxWords = settings.AdviceMaxWords,
        MaxOutputTokens = settings.MaxOutputTokens,
        PerCallSpendLimitUsd = settings.PerCallSpendLimitUsd
    };
}
