using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;

namespace AICallAssistant.Desktop.Services.Audio;

public sealed class WindowsAudioCaptureService : IAudioCaptureService
{
    private readonly SemaphoreSlim lifecycleGate = new(1, 1);
    private WindowsAudioCaptureSession? activeSession;
    private int disposed;

    public bool IsCapturing => Volatile.Read(ref activeSession) is not null;

    public event Action<AudioFrame>? FrameCaptured;

    public event Action<Exception>? CaptureFailed;

    public Task<IReadOnlyList<AudioSourceOption>> GetIncomingSourcesAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return Task.FromResult(
            AudioDeviceDiscovery.GetIncomingSources(cancellationToken));
    }

    public Task<IReadOnlyList<AudioSourceOption>> GetMicrophonesAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        return Task.FromResult(
            AudioDeviceDiscovery.GetMicrophones(cancellationToken));
    }

    public async Task StartAsync(
        AudioCaptureRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ThrowIfDisposed();
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        WindowsAudioCaptureSession? pendingSession = null;
        try
        {
            ThrowIfDisposed();
            if (activeSession is not null)
            {
                throw new InvalidOperationException("Захват аудио уже выполняется.");
            }

            if (!OperatingSystem.IsWindows())
            {
                throw new PlatformNotSupportedException(
                    "WASAPI-захват доступен только в Windows.");
            }

            ValidateRequest(request);
            AudioFileFinalizer.PrepareFolder(request.FolderPath);
            pendingSession = await WindowsAudioCaptureSession.CreateAsync(
                    request,
                    PublishFrame,
                    PublishFailure,
                    cancellationToken)
                .ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            pendingSession.Start();
            Volatile.Write(ref activeSession, pendingSession);
            pendingSession = null;
        }
        finally
        {
            if (pendingSession is not null)
            {
                await pendingSession.DisposeAsync().ConfigureAwait(false);
            }

            lifecycleGate.Release();
        }
    }

    public async Task<AudioCaptureResult> StopAsync(
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        await lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        WindowsAudioCaptureSession? session = null;
        try
        {
            ThrowIfDisposed();
            session = Interlocked.Exchange(ref activeSession, null);
            if (session is null)
            {
                throw new InvalidOperationException("Захват аудио не запущен.");
            }

            return await session.StopAndFinalizeAsync().ConfigureAwait(false);
        }
        finally
        {
            if (session is not null)
            {
                await session.DisposeAsync().ConfigureAwait(false);
            }

            lifecycleGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        await lifecycleGate.WaitAsync().ConfigureAwait(false);
        try
        {
            var session = Interlocked.Exchange(ref activeSession, null);
            if (session is null)
            {
                return;
            }

            try
            {
                await session.StopAndFinalizeAsync().ConfigureAwait(false);
            }
            finally
            {
                await session.DisposeAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            lifecycleGate.Release();
            lifecycleGate.Dispose();
        }
    }

    private static void ValidateRequest(AudioCaptureRequest request)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(request.FolderPath);
        if (request.IncomingSource.Kind is not (
                AudioSourceKind.SystemAudio or AudioSourceKind.Process))
        {
            throw new ArgumentException(
                "Не выбран корректный источник входящего аудио.",
                nameof(request));
        }

        if (request.IncomingSource.Kind == AudioSourceKind.Process)
        {
            if (!ProcessLoopbackCapture.IsSupported)
            {
                throw new PlatformNotSupportedException(
                    "Process loopback недоступен в этой версии Windows. " +
                    "Выберите «Весь системный звук».");
            }

            if (request.IncomingSource.ProcessId is not > 0)
            {
                throw new ArgumentException(
                    "Для выбранного приложения отсутствует process ID.",
                    nameof(request));
            }
        }

        if (request.Microphone.Kind != AudioSourceKind.Microphone ||
            string.IsNullOrWhiteSpace(request.Microphone.DeviceId))
        {
            throw new ArgumentException(
                "Не выбран корректный микрофон.",
                nameof(request));
        }
    }

    private void PublishFrame(AudioFrame frame)
    {
        var handlers = FrameCaptured;
        if (handlers is null)
        {
            return;
        }

        foreach (Action<AudioFrame> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(frame);
            }
            catch
            {
                // A consumer must not be able to terminate the realtime capture thread.
            }
        }
    }

    private void PublishFailure(Exception exception)
    {
        var handlers = CaptureFailed;
        if (handlers is null)
        {
            return;
        }

        foreach (Action<Exception> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(exception);
            }
            catch
            {
                // Error reporting must not throw back into a WASAPI callback.
            }
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
    }
}
