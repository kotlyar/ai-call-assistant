using System.Diagnostics;
using AICallAssistant.Core.Models;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace AICallAssistant.Desktop.Services.Audio;

internal sealed class WasapiCaptureEndpoint : IAsyncDisposable
{
    private static readonly TimeSpan StopTimeout = TimeSpan.FromSeconds(10);

    private readonly WasapiRecorder capture;
    private readonly TaskCompletionSource<Exception?> stoppedCompletion = new(
        TaskCreationOptions.RunContinuationsAsynchronously);
    private int started;
    private int stopRequested;
    private int disposed;

    private WasapiCaptureEndpoint(WasapiRecorder capture)
    {
        this.capture = capture;
        capture.DataAvailable += HandleDataAvailable;
        capture.RecordingStopped += HandleRecordingStopped;
    }

    public WaveFormat WaveFormat => capture.WaveFormat;

    public event Action<byte[], int, int, long>? DataAvailable;

    public event Action<Exception?>? Stopped;

    public static async Task<WasapiCaptureEndpoint> CreateIncomingAsync(
        AudioSourceOption source)
    {
        ArgumentNullException.ThrowIfNull(source);
        var recorder = source.Kind switch
        {
            AudioSourceKind.SystemAudio => CreateSystemLoopback(),
            AudioSourceKind.Process => await ProcessLoopbackCapture.CreateAsync(
                    source.ProcessId ?? 0)
                .ConfigureAwait(false),
            _ => throw new ArgumentException(
                "Входящий источник должен быть системным звуком или приложением.",
                nameof(source))
        };
        return new WasapiCaptureEndpoint(recorder);
    }

    public static WasapiCaptureEndpoint CreateMicrophone(AudioSourceOption source)
    {
        ArgumentNullException.ThrowIfNull(source);
        if (source.Kind != AudioSourceKind.Microphone ||
            string.IsNullOrWhiteSpace(source.DeviceId))
        {
            throw new ArgumentException("Не выбран корректный микрофон.", nameof(source));
        }

        using var enumerator = new MMDeviceEnumerator();
        using var device = enumerator.GetDevice(source.DeviceId);
        var recorder = new WasapiRecorderBuilder()
            .WithDevice(device)
            .WithSharedMode()
            .WithEventSync()
            .WithBufferLength(50)
            .WithMmcssThreadPriority("Audio")
            .Build();
        return new WasapiCaptureEndpoint(recorder);
    }

    public void Start()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        if (Interlocked.CompareExchange(ref started, 1, 0) != 0)
        {
            throw new InvalidOperationException("WASAPI endpoint уже запущен.");
        }

        try
        {
            capture.StartRecording();
        }
        catch
        {
            Interlocked.Exchange(ref started, 0);
            throw;
        }
    }

    public void RequestStop()
    {
        if (Volatile.Read(ref started) == 0 ||
            Interlocked.Exchange(ref stopRequested, 1) != 0)
        {
            return;
        }

        capture.StopRecording();
    }

    public async Task<Exception?> StopAsync()
    {
        if (Volatile.Read(ref started) == 0)
        {
            return null;
        }

        RequestStop();
        return await stoppedCompletion.Task
            .WaitAsync(StopTimeout)
            .ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        try
        {
            RequestStop();
            await capture.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            capture.DataAvailable -= HandleDataAvailable;
            capture.RecordingStopped -= HandleRecordingStopped;
            stoppedCompletion.TrySetResult(null);
        }
    }

    private static WasapiRecorder CreateSystemLoopback()
    {
        using var enumerator = new MMDeviceEnumerator();
        using var renderDevice = enumerator.GetDefaultAudioEndpoint(
            DataFlow.Render,
            Role.Multimedia);
        return new WasapiRecorderBuilder()
            .WithDevice(renderDevice)
            .WithSharedMode()
            .WithLoopbackCapture()
            .WithEventSync()
            .WithBufferLength(50)
            .WithMmcssThreadPriority("Audio")
            .Build();
    }

    private void HandleDataAvailable(
        ReadOnlySpan<byte> buffer,
        AudioClientBufferFlags flags,
        long devicePosition,
        long qpcPosition)
    {
        _ = flags;
        _ = devicePosition;
        _ = qpcPosition;
        if (buffer.IsEmpty || Volatile.Read(ref stopRequested) != 0)
        {
            return;
        }

        var ownedBuffer = buffer.ToArray();
        DataAvailable?.Invoke(
            ownedBuffer,
            0,
            ownedBuffer.Length,
            Stopwatch.GetTimestamp());
    }

    private void HandleRecordingStopped(object? sender, StoppedEventArgs eventArgs)
    {
        var exception = eventArgs.Exception;
        stoppedCompletion.TrySetResult(exception);
        Stopped?.Invoke(exception);
    }
}
