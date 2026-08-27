using System.Diagnostics;
using System.IO;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;

namespace AICallAssistant.Desktop.Services.Audio;

internal sealed class WindowsAudioCaptureSession : IAsyncDisposable
{
    private readonly WasapiCaptureEndpoint incomingEndpoint;
    private readonly WasapiCaptureEndpoint outgoingEndpoint;
    private readonly CaptureTrackPipeline incomingPipeline;
    private readonly CaptureTrackPipeline outgoingPipeline;
    private readonly Action<Exception> publishFailure;
    private readonly string folderPath;
    private readonly object stateSync = new();
    private readonly List<string> captureWarnings = [];

    private readonly long captureStartTimestamp;
    private long captureEndTimestamp;
    private int stopRequested;
    private int stopCompleted;
    private int disposed;

    private WindowsAudioCaptureSession(
        WasapiCaptureEndpoint incomingEndpoint,
        WasapiCaptureEndpoint outgoingEndpoint,
        string folderPath,
        Action<AudioFrame> publishFrame,
        Action<Exception> publishFailure)
    {
        this.incomingEndpoint = incomingEndpoint;
        this.outgoingEndpoint = outgoingEndpoint;
        this.folderPath = folderPath;
        this.publishFailure = publishFailure;

        var startTimestamp = Stopwatch.GetTimestamp();
        CaptureTrackPipeline? pendingIncomingPipeline = null;
        try
        {
            pendingIncomingPipeline = new CaptureTrackPipeline(
                AudioTrack.Incoming,
                incomingEndpoint.WaveFormat,
                Path.Combine(folderPath, "incoming.partial.wav"),
                startTimestamp,
                publishFrame);
            outgoingPipeline = new CaptureTrackPipeline(
                AudioTrack.Outgoing,
                outgoingEndpoint.WaveFormat,
                Path.Combine(folderPath, "outgoing.partial.wav"),
                startTimestamp,
                publishFrame);
            incomingPipeline = pendingIncomingPipeline;
            pendingIncomingPipeline = null;
        }
        finally
        {
            pendingIncomingPipeline?.Dispose();
        }
        captureStartTimestamp = startTimestamp;

        incomingEndpoint.DataAvailable += HandleIncomingData;
        outgoingEndpoint.DataAvailable += HandleOutgoingData;
        incomingEndpoint.Stopped += error => HandleUnexpectedStop("системного звука", error);
        outgoingEndpoint.Stopped += error => HandleUnexpectedStop("микрофона", error);
    }

    public static async Task<WindowsAudioCaptureSession> CreateAsync(
        AudioCaptureRequest request,
        Action<AudioFrame> publishFrame,
        Action<Exception> publishFailure,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(publishFrame);
        ArgumentNullException.ThrowIfNull(publishFailure);
        cancellationToken.ThrowIfCancellationRequested();

        WasapiCaptureEndpoint? incoming = null;
        WasapiCaptureEndpoint? outgoing = null;
        try
        {
            incoming = await WasapiCaptureEndpoint
                .CreateIncomingAsync(request.IncomingSource)
                .ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            outgoing = WasapiCaptureEndpoint.CreateMicrophone(request.Microphone);
            cancellationToken.ThrowIfCancellationRequested();

            return new WindowsAudioCaptureSession(
                incoming,
                outgoing,
                request.FolderPath,
                publishFrame,
                publishFailure);
        }
        catch
        {
            if (outgoing is not null)
            {
                await DisposeIgnoringErrorsAsync(outgoing).ConfigureAwait(false);
            }

            if (incoming is not null)
            {
                await DisposeIgnoringErrorsAsync(incoming).ConfigureAwait(false);
            }

            throw;
        }
    }

    public void Start()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        try
        {
            incomingEndpoint.Start();
            outgoingEndpoint.Start();
        }
        catch (Exception exception)
        {
            StopAfterFailure(exception);
            throw;
        }
    }

    public async Task<AudioCaptureResult> StopAndFinalizeAsync()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
        if (Interlocked.Exchange(ref stopRequested, 1) == 0)
        {
            Volatile.Write(ref captureEndTimestamp, Stopwatch.GetTimestamp());
        }

        incomingEndpoint.RequestStop();
        outgoingEndpoint.RequestStop();

        var warnings = new List<string>();
        lock (stateSync)
        {
            warnings.AddRange(captureWarnings);
        }

        await StopEndpointAsync(incomingEndpoint, "системного звука", warnings)
            .ConfigureAwait(false);
        await StopEndpointAsync(outgoingEndpoint, "микрофона", warnings)
            .ConfigureAwait(false);

        await DisposeEndpointAsync(incomingEndpoint, "системного звука", warnings)
            .ConfigureAwait(false);
        await DisposeEndpointAsync(outgoingEndpoint, "микрофона", warnings)
            .ConfigureAwait(false);

        var duration = GetDuration();
        CompletePipeline(incomingPipeline, duration, "входящую дорожку", warnings);
        CompletePipeline(outgoingPipeline, duration, "дорожку микрофона", warnings);

        AudioFileFinalizationResult files;
        try
        {
            files = await AudioFileFinalizer.FinalizeAsync(
                    folderPath,
                    incomingPipeline.WavePath,
                    outgoingPipeline.WavePath)
                .ConfigureAwait(false);
        }
        catch (Exception exception) when (
            exception is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            warnings.Add($"Не удалось финализировать аудиофайлы: {exception.Message}");
            files = new AudioFileFinalizationResult(
                incomingPipeline.WavePath,
                outgoingPipeline.WavePath,
                CombinedPath: null,
                Warnings: []);
        }

        warnings.AddRange(files.Warnings);
        Interlocked.Exchange(ref stopCompleted, 1);
        return new AudioCaptureResult(
            files.IncomingPath,
            files.OutgoingPath,
            files.CombinedPath,
            duration,
            warnings.Distinct(StringComparer.Ordinal).ToArray());
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        if (Volatile.Read(ref stopCompleted) == 0)
        {
            Interlocked.Exchange(ref stopRequested, 1);
            if (Volatile.Read(ref captureEndTimestamp) == 0)
            {
                Volatile.Write(ref captureEndTimestamp, Stopwatch.GetTimestamp());
            }

            incomingEndpoint.RequestStop();
            outgoingEndpoint.RequestStop();
            await DisposeIgnoringErrorsAsync(incomingEndpoint).ConfigureAwait(false);
            await DisposeIgnoringErrorsAsync(outgoingEndpoint).ConfigureAwait(false);
            incomingPipeline.Dispose();
            outgoingPipeline.Dispose();
        }
    }

    private void HandleIncomingData(byte[] buffer, int offset, int count, long timestamp)
    {
        if (Volatile.Read(ref stopRequested) != 0)
        {
            return;
        }

        try
        {
            incomingPipeline.Push(buffer, offset, count, timestamp);
        }
        catch (Exception exception)
        {
            StopAfterFailure(new IOException(
                "Не удалось сохранить входящий аудиопоток.",
                exception));
        }
    }

    private void HandleOutgoingData(byte[] buffer, int offset, int count, long timestamp)
    {
        if (Volatile.Read(ref stopRequested) != 0)
        {
            return;
        }

        try
        {
            outgoingPipeline.Push(buffer, offset, count, timestamp);
        }
        catch (Exception exception)
        {
            StopAfterFailure(new IOException(
                "Не удалось сохранить аудиопоток микрофона.",
                exception));
        }
    }

    private void HandleUnexpectedStop(string sourceDescription, Exception? exception)
    {
        if (Volatile.Read(ref stopRequested) != 0)
        {
            return;
        }

        StopAfterFailure(exception ?? new IOException(
            $"WASAPI-захват {sourceDescription} неожиданно остановился."));
    }

    private void StopAfterFailure(Exception exception)
    {
        if (Interlocked.Exchange(ref stopRequested, 1) != 0)
        {
            return;
        }

        Volatile.Write(ref captureEndTimestamp, Stopwatch.GetTimestamp());
        lock (stateSync)
        {
            captureWarnings.Add(exception.Message);
        }

        incomingEndpoint.RequestStop();
        outgoingEndpoint.RequestStop();
        try
        {
            publishFailure(exception);
        }
        catch
        {
            // Event subscribers must not tear down the WASAPI callback thread.
        }
    }

    private TimeSpan GetDuration()
    {
        var endTimestamp = Volatile.Read(ref captureEndTimestamp);
        if (endTimestamp == 0)
        {
            endTimestamp = Stopwatch.GetTimestamp();
        }

        return Stopwatch.GetElapsedTime(captureStartTimestamp, endTimestamp);
    }

    private static async Task StopEndpointAsync(
        WasapiCaptureEndpoint endpoint,
        string description,
        List<string> warnings)
    {
        try
        {
            var error = await endpoint.StopAsync().ConfigureAwait(false);
            if (error is not null)
            {
                warnings.Add($"WASAPI-захват {description} завершился с ошибкой: {error.Message}");
            }
        }
        catch (TimeoutException exception)
        {
            warnings.Add($"Истекло время остановки WASAPI-захвата {description}: {exception.Message}");
        }
        catch (Exception exception)
        {
            warnings.Add($"Не удалось остановить WASAPI-захват {description}: {exception.Message}");
        }
    }

    private static async Task DisposeEndpointAsync(
        WasapiCaptureEndpoint endpoint,
        string description,
        List<string> warnings)
    {
        try
        {
            await endpoint.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            warnings.Add($"Не удалось освободить WASAPI-захват {description}: {exception.Message}");
        }
    }

    private static async Task DisposeIgnoringErrorsAsync(WasapiCaptureEndpoint endpoint)
    {
        try
        {
            await endpoint.DisposeAsync().ConfigureAwait(false);
        }
        catch
        {
            // Dispose is the last-chance recovery path; WAV writers are closed below.
        }
    }

    private static void CompletePipeline(
        CaptureTrackPipeline pipeline,
        TimeSpan duration,
        string description,
        List<string> warnings)
    {
        try
        {
            pipeline.Complete(duration);
        }
        catch (Exception exception)
        {
            warnings.Add($"Не удалось завершить {description}: {exception.Message}");
            pipeline.Dispose();
        }
    }
}
