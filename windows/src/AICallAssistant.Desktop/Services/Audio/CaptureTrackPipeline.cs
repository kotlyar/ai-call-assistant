using System.Diagnostics;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;
using NAudio.Wave;

namespace AICallAssistant.Desktop.Services.Audio;

internal sealed class CaptureTrackPipeline : IDisposable
{
    private const int MaximumPublishedFrameCount =
        Pcm24KhzMonoConverter.OutputSampleRate / 10;
    private const int GapToleranceFrameCount =
        Pcm24KhzMonoConverter.OutputSampleRate / 50;

    private static readonly byte[] SilenceFrame = new byte[
        MaximumPublishedFrameCount * Pcm24KhzMonoConverter.OutputBytesPerFrame];

    private readonly object sync = new();
    private readonly AudioTrack track;
    private readonly long captureStartTimestamp;
    private readonly Pcm24KhzMonoConverter converter;
    private readonly DurablePcmWaveWriter writer;
    private readonly Action<AudioFrame> publishFrame;
    private bool acceptingData = true;
    private bool disposed;

    public CaptureTrackPipeline(
        AudioTrack track,
        WaveFormat sourceFormat,
        string wavePath,
        long captureStartTimestamp,
        Action<AudioFrame> publishFrame)
    {
        this.track = track;
        this.captureStartTimestamp = captureStartTimestamp;
        this.publishFrame = publishFrame;
        converter = new Pcm24KhzMonoConverter(sourceFormat);
        writer = new DurablePcmWaveWriter(wavePath);
    }

    public string WavePath => writer.Path;

    public void Push(byte[] buffer, int offset, int count, long captureTimestamp)
    {
        List<AudioFrame> framesToPublish;
        lock (sync)
        {
            ThrowIfDisposed();
            if (!acceptingData)
            {
                return;
            }

            var converted = converter.Convert(buffer, offset, count);
            if (converted.Length == 0)
            {
                return;
            }

            var convertedFrameCount =
                converted.Length / Pcm24KhzMonoConverter.OutputBytesPerFrame;
            var elapsedTicks = Math.Max(0, captureTimestamp - captureStartTimestamp);
            var elapsedFrameCount = (long)Math.Round(
                elapsedTicks * (double)Pcm24KhzMonoConverter.OutputSampleRate /
                Stopwatch.Frequency);
            var desiredStartFrame = Math.Max(0, elapsedFrameCount - convertedFrameCount);
            var currentFrameCount = writer.FrameCount;
            var missingFrameCount = desiredStartFrame - currentFrameCount;

            framesToPublish = [];
            if (missingFrameCount > GapToleranceFrameCount)
            {
                AppendSilence(missingFrameCount, framesToPublish);
            }

            AppendAudio(converted, framesToPublish);
        }

        Publish(framesToPublish);
    }

    public void Complete(TimeSpan duration)
    {
        List<AudioFrame> framesToPublish;
        lock (sync)
        {
            ThrowIfDisposed();
            acceptingData = false;
            var targetFrameCount = Math.Max(
                0,
                (long)Math.Ceiling(
                    duration.TotalSeconds * Pcm24KhzMonoConverter.OutputSampleRate));
            var missingFrameCount = targetFrameCount - writer.FrameCount;
            framesToPublish = [];
            if (missingFrameCount > 0)
            {
                AppendSilence(missingFrameCount, framesToPublish);
            }

            writer.FlushDurably();
            writer.Dispose();
            disposed = true;
        }

        Publish(framesToPublish);
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }

            acceptingData = false;
            writer.Dispose();
            disposed = true;
        }
    }

    private void AppendSilence(long frameCount, List<AudioFrame> framesToPublish)
    {
        while (frameCount > 0)
        {
            var chunkFrameCount = (int)Math.Min(frameCount, MaximumPublishedFrameCount);
            var byteCount = checked(
                chunkFrameCount * Pcm24KhzMonoConverter.OutputBytesPerFrame);
            var offset = FrameOffset(writer.FrameCount);
            var silence = byteCount == SilenceFrame.Length
                ? SilenceFrame
                : SilenceFrame.AsSpan(0, byteCount).ToArray();
            writer.Write(silence.AsSpan(0, byteCount));
            framesToPublish.Add(new AudioFrame(track, silence, offset, 0));
            frameCount -= chunkFrameCount;
        }
    }

    private void AppendAudio(byte[] converted, List<AudioFrame> framesToPublish)
    {
        var byteOffset = 0;
        var maximumByteCount =
            MaximumPublishedFrameCount * Pcm24KhzMonoConverter.OutputBytesPerFrame;

        while (byteOffset < converted.Length)
        {
            var byteCount = Math.Min(maximumByteCount, converted.Length - byteOffset);
            var offset = FrameOffset(writer.FrameCount);
            var audio = converted.AsMemory(byteOffset, byteCount);
            writer.Write(audio.Span);
            framesToPublish.Add(new AudioFrame(
                track,
                audio,
                offset,
                Pcm24KhzMonoConverter.ComputeRms(audio.Span)));
            byteOffset += byteCount;
        }
    }

    private void Publish(IEnumerable<AudioFrame> frames)
    {
        foreach (var frame in frames)
        {
            publishFrame(frame);
        }
    }

    private static TimeSpan FrameOffset(long frameCount) =>
        TimeSpan.FromSeconds(
            frameCount / (double)Pcm24KhzMonoConverter.OutputSampleRate);

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
    }
}
