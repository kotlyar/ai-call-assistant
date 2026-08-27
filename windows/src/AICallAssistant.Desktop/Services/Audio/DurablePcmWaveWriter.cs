using System.Buffers.Binary;
using System.IO;

namespace AICallAssistant.Desktop.Services.Audio;

/// <summary>
/// Writes a canonical PCM16 mono 24 kHz RIFF/WAVE file. The size fields are
/// patched after every append and the stream is forced to disk periodically,
/// leaving a directly playable recovery artifact after most abrupt exits.
/// </summary>
internal sealed class DurablePcmWaveWriter : IDisposable
{
    private const int HeaderSize = 44;
    private const int RiffSizeOffset = 4;
    private const int DataSizeOffset = 40;
    private const int FlushIntervalFrames = Pcm24KhzMonoConverter.OutputSampleRate;
    private const long MaximumDataBytes = uint.MaxValue - 36L;

    private readonly object sync = new();
    private readonly FileStream stream;
    private long dataByteCount;
    private long lastDurableFlushFrameCount;
    private bool disposed;

    public DurablePcmWaveWriter(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        Path = path;
        stream = new FileStream(
            path,
            FileMode.Create,
            FileAccess.ReadWrite,
            FileShare.Read,
            bufferSize: 64 * 1024,
            FileOptions.SequentialScan);
        WriteHeader();
        stream.Flush(flushToDisk: true);
    }

    public string Path { get; }

    public long FrameCount
    {
        get
        {
            lock (sync)
            {
                return dataByteCount / Pcm24KhzMonoConverter.OutputBytesPerFrame;
            }
        }
    }

    public void Write(ReadOnlySpan<byte> pcm16Mono24Khz)
    {
        if (pcm16Mono24Khz.Length == 0)
        {
            return;
        }

        if (pcm16Mono24Khz.Length % Pcm24KhzMonoConverter.OutputBytesPerFrame != 0)
        {
            throw new ArgumentException("PCM16 data must end on a complete sample boundary.");
        }

        lock (sync)
        {
            ThrowIfDisposed();
            if (dataByteCount > MaximumDataBytes - pcm16Mono24Khz.Length)
            {
                throw new IOException("WAV-дорожка превысила максимальный размер RIFF-файла.");
            }

            stream.Position = HeaderSize + dataByteCount;
            stream.Write(pcm16Mono24Khz);
            dataByteCount += pcm16Mono24Khz.Length;
            PatchHeader();

            var currentFrameCount = dataByteCount / Pcm24KhzMonoConverter.OutputBytesPerFrame;
            if (currentFrameCount - lastDurableFlushFrameCount >= FlushIntervalFrames)
            {
                stream.Flush(flushToDisk: true);
                lastDurableFlushFrameCount = currentFrameCount;
            }
        }
    }

    public void PadToFrameCount(long targetFrameCount)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(targetFrameCount);
        const int silenceChunkFrames = Pcm24KhzMonoConverter.OutputSampleRate / 10;
        var silence = new byte[
            silenceChunkFrames * Pcm24KhzMonoConverter.OutputBytesPerFrame];

        while (true)
        {
            long missingFrames;
            lock (sync)
            {
                ThrowIfDisposed();
                missingFrames = targetFrameCount -
                    (dataByteCount / Pcm24KhzMonoConverter.OutputBytesPerFrame);
            }

            if (missingFrames <= 0)
            {
                return;
            }

            var framesToWrite = (int)Math.Min(missingFrames, silenceChunkFrames);
            Write(silence.AsSpan(
                0,
                framesToWrite * Pcm24KhzMonoConverter.OutputBytesPerFrame));
        }
    }

    public void FlushDurably()
    {
        lock (sync)
        {
            ThrowIfDisposed();
            PatchHeader();
            stream.Flush(flushToDisk: true);
            lastDurableFlushFrameCount =
                dataByteCount / Pcm24KhzMonoConverter.OutputBytesPerFrame;
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }

            PatchHeader();
            stream.Flush(flushToDisk: true);
            disposed = true;
            stream.Dispose();
        }
    }

    private void WriteHeader()
    {
        Span<byte> header = stackalloc byte[HeaderSize];
        "RIFF"u8.CopyTo(header);
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(RiffSizeOffset, 4), 36);
        "WAVE"u8.CopyTo(header.Slice(8));
        "fmt "u8.CopyTo(header.Slice(12));
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(16, 4), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(20, 2), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(22, 2), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(
            header.Slice(24, 4),
            Pcm24KhzMonoConverter.OutputSampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(
            header.Slice(28, 4),
            Pcm24KhzMonoConverter.OutputSampleRate *
                Pcm24KhzMonoConverter.OutputBytesPerFrame);
        BinaryPrimitives.WriteUInt16LittleEndian(
            header.Slice(32, 2),
            Pcm24KhzMonoConverter.OutputBytesPerFrame);
        BinaryPrimitives.WriteUInt16LittleEndian(header.Slice(34, 2), 16);
        "data"u8.CopyTo(header.Slice(36));
        BinaryPrimitives.WriteUInt32LittleEndian(header.Slice(DataSizeOffset, 4), 0);
        stream.Write(header);
    }

    private void PatchHeader()
    {
        var endPosition = HeaderSize + dataByteCount;
        Span<byte> value = stackalloc byte[4];

        stream.Position = RiffSizeOffset;
        BinaryPrimitives.WriteUInt32LittleEndian(value, checked((uint)(36 + dataByteCount)));
        stream.Write(value);

        stream.Position = DataSizeOffset;
        BinaryPrimitives.WriteUInt32LittleEndian(value, checked((uint)dataByteCount));
        stream.Write(value);
        stream.Position = endPosition;
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
    }
}
