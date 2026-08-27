using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;

namespace AICallAssistant.Core.OpenAI;

public sealed class RealtimeTranscriptionSession : IRealtimeTranscriptionSession
{
    private readonly Uri _endpoint;
    private readonly Func<ClientWebSocket> _socketFactory;
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly Stopwatch _clock = new();
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _lifetime;
    private Task? _receiveTask;
    private TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int _disposed;

    public RealtimeTranscriptionSession(
        AudioTrack track,
        Func<ClientWebSocket>? socketFactory = null,
        Uri? endpoint = null)
    {
        Track = track;
        _socketFactory = socketFactory ?? (() => new ClientWebSocket());
        _endpoint = endpoint ?? new Uri("wss://api.openai.com/v1/realtime?intent=transcription");
    }

    public AudioTrack Track { get; }
    public event Action<TranscriptTurn>? TurnCompleted;
    public event Action<string>? PartialTranscriptChanged;
    public event Action<Exception>? Failed;

    public async Task ConnectAsync(
        string apiKey,
        AppSettings settings,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            throw new InvalidOperationException("Добавьте OpenAI API key в настройках.");
        }

        await DisconnectAsync(cancellationToken).ConfigureAwait(false);
        var socket = _socketFactory();
        socket.Options.SetRequestHeader("Authorization", $"Bearer {apiKey.Trim()}");
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _socket = socket;
        _lifetime = lifetime;
        _ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        try
        {
            await socket.ConnectAsync(_endpoint, cancellationToken).ConfigureAwait(false);
            _clock.Restart();
            _receiveTask = ReceiveLoopAsync(socket, lifetime.Token);
            var sessionUpdate = new
            {
                type = "session.update",
                session = new
                {
                    type = "transcription",
                    audio = new
                    {
                        input = new
                        {
                            format = new { type = "audio/pcm", rate = 24000 },
                            transcription = new
                            {
                                model = settings.RealtimeTranscriptionModelId,
                                languages = settings.TranscriptionLanguages,
                                delay = "low"
                            },
                            // gpt-live-transcribe currently requires explicit
                            // commits. CallSessionController performs a small
                            // client-side VAD over the canonical PCM stream.
                            turn_detection = (object?)null
                        }
                    }
                }
            };
            await SendJsonAsync(sessionUpdate, cancellationToken).ConfigureAwait(false);
            await _ready.Task.WaitAsync(TimeSpan.FromSeconds(10), cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            await DisconnectAsync(CancellationToken.None).ConfigureAwait(false);
            throw;
        }
    }

    public ValueTask AppendAudioAsync(
        ReadOnlyMemory<byte> pcm16Mono24Khz,
        CancellationToken cancellationToken = default)
    {
        if (pcm16Mono24Khz.IsEmpty)
        {
            return ValueTask.CompletedTask;
        }

        return new ValueTask(SendJsonAsync(
            new
            {
                type = "input_audio_buffer.append",
                audio = Convert.ToBase64String(pcm16Mono24Khz.Span)
            },
            cancellationToken));
    }

    public Task CommitAsync(CancellationToken cancellationToken = default) =>
        SendJsonAsync(
            new
            {
                type = "input_audio_buffer.commit",
                event_id = $"commit-{Track.ToString().ToLowerInvariant()}-{Guid.NewGuid():N}"
            },
            cancellationToken);

    public async Task DisconnectAsync(CancellationToken cancellationToken = default)
    {
        var lifetime = Interlocked.Exchange(ref _lifetime, null);
        var socket = Interlocked.Exchange(ref _socket, null);
        var receiveTask = Interlocked.Exchange(ref _receiveTask, null);
        lifetime?.Cancel();

        if (socket is not null)
        {
            try
            {
                if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                {
                    await socket.CloseOutputAsync(
                        WebSocketCloseStatus.NormalClosure,
                        "call finished",
                        cancellationToken).ConfigureAwait(false);
                }
            }
            catch (Exception) when (cancellationToken.IsCancellationRequested || lifetime?.IsCancellationRequested == true)
            {
                // Expected during shutdown.
            }
            finally
            {
                socket.Dispose();
            }
        }

        if (receiveTask is not null)
        {
            try
            {
                await receiveTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Expected during shutdown.
            }
        }

        lifetime?.Dispose();
        _clock.Stop();
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        await DisconnectAsync(CancellationToken.None).ConfigureAwait(false);
        _sendGate.Dispose();
    }

    private async Task SendJsonAsync(object payload, CancellationToken cancellationToken)
    {
        var socket = _socket;
        if (socket is null || socket.State != WebSocketState.Open)
        {
            throw new InvalidOperationException("Realtime-сессия не подключена.");
        }

        var bytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonDefaults.Options);
        await _sendGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await socket.SendAsync(
                bytes,
                WebSocketMessageType.Text,
                true,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _sendGate.Release();
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (!cancellationToken.IsCancellationRequested && socket.State == WebSocketState.Open)
            {
                using var message = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        return;
                    }

                    if (message.Length + result.Count > 2 * 1024 * 1024)
                    {
                        throw new OpenAIProtocolException("Realtime API вернул слишком большое событие.");
                    }

                    await message.WriteAsync(buffer.AsMemory(0, result.Count), cancellationToken).ConfigureAwait(false);
                }
                while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text)
                {
                    continue;
                }

                HandleMessage(message.GetBuffer().AsSpan(0, checked((int)message.Length)));
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal disconnect.
        }
        catch (Exception error)
        {
            _ready.TrySetException(error);
            Failed?.Invoke(error);
        }
    }

    private void HandleMessage(ReadOnlySpan<byte> utf8)
    {
        using var document = JsonDocument.Parse(utf8.ToArray());
        var root = document.RootElement;
        var type = root.TryGetProperty("type", out var typeElement)
            ? typeElement.GetString()
            : null;
        switch (type)
        {
            case "session.updated":
                _ready.TrySetResult();
                break;
            case "conversation.item.input_audio_transcription.delta":
                if (root.TryGetProperty("delta", out var deltaElement) && deltaElement.GetString() is { } delta)
                {
                    PartialTranscriptChanged?.Invoke(delta);
                }
                break;
            case "conversation.item.input_audio_transcription.completed":
                if (root.TryGetProperty("transcript", out var transcriptElement) &&
                    transcriptElement.GetString()?.Trim() is { Length: > 0 } transcript)
                {
                    TurnCompleted?.Invoke(new TranscriptTurn
                    {
                        Speaker = Track == AudioTrack.Incoming
                            ? TranscriptSpeaker.Participant
                            : TranscriptSpeaker.You,
                        Offset = _clock.Elapsed,
                        Text = transcript,
                        IsFinal = true
                    });
                }
                break;
            case "error":
                var code = root.TryGetProperty("error", out var errorElement) &&
                           errorElement.TryGetProperty("code", out var codeElement)
                    ? codeElement.GetString()
                    : null;
                var error = new OpenAIProtocolException("Realtime API отклонил запрос.", code: code);
                _ready.TrySetException(error);
                Failed?.Invoke(error);
                break;
        }
    }
}
