using System.Buffers.Binary;
using System.IO;
using NAudio.Wave;

namespace AICallAssistant.Desktop.Services.Audio;

internal sealed record AudioFileFinalizationResult(
    string IncomingPath,
    string OutgoingPath,
    string? CombinedPath,
    IReadOnlyList<string> Warnings);

internal static class AudioFileFinalizer
{
    private const int AacBitRate = 96_000;
    private const int MixBufferByteCount =
        Pcm24KhzMonoConverter.OutputSampleRate *
        Pcm24KhzMonoConverter.OutputBytesPerFrame /
        10;

    private static readonly string[] KnownArtifactNames =
    [
        "incoming.partial.wav",
        "outgoing.partial.wav",
        "combined.partial.wav",
        "incoming.partial.m4a",
        "outgoing.partial.m4a",
        "combined.partial.m4a",
        "incoming.partial.mp4",
        "outgoing.partial.mp4",
        "combined.partial.mp4",
        "incoming.wav",
        "outgoing.wav",
        "combined.wav",
        "incoming.m4a",
        "outgoing.m4a",
        "combined.m4a"
    ];

    public static void PrepareFolder(string folderPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        Directory.CreateDirectory(folderPath);
        foreach (var artifactName in KnownArtifactNames)
        {
            var path = Path.Combine(folderPath, artifactName);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    public static Task<AudioFileFinalizationResult> FinalizeAsync(
        string folderPath,
        string incomingWavePath,
        string outgoingWavePath)
    {
        return Task.Run(() => Finalize(folderPath, incomingWavePath, outgoingWavePath));
    }

    private static AudioFileFinalizationResult Finalize(
        string folderPath,
        string incomingWavePath,
        string outgoingWavePath)
    {
        var warnings = new List<string>();
        var incomingM4aPath = Path.Combine(folderPath, "incoming.m4a");
        var outgoingM4aPath = Path.Combine(folderPath, "outgoing.m4a");
        var combinedM4aPath = Path.Combine(folderPath, "combined.m4a");

        var incomingEncoded = TryEncodeM4a(
            incomingWavePath,
            incomingM4aPath,
            "входящую дорожку",
            warnings);
        var outgoingEncoded = TryEncodeM4a(
            outgoingWavePath,
            outgoingM4aPath,
            "дорожку микрофона",
            warnings);

        string? combinedPath = null;
        var combinedWavePath = Path.Combine(folderPath, "combined.partial.wav");
        try
        {
            CreateCombinedWave(incomingWavePath, outgoingWavePath, combinedWavePath);
            var combinedEncoded = TryEncodeM4a(
                combinedWavePath,
                combinedM4aPath,
                "объединённую дорожку",
                warnings);
            combinedPath = combinedEncoded
                ? combinedM4aPath
                : PromoteRecoveryWave(combinedWavePath, folderPath, "combined.wav");
        }
        catch (Exception exception) when (
            exception is IOException or InvalidDataException or UnauthorizedAccessException or
            ArgumentException or NotSupportedException)
        {
            warnings.Add($"Не удалось создать combined: {exception.Message}");
            TryDelete(combinedWavePath);
        }

        var incomingPath = incomingEncoded
            ? incomingM4aPath
            : PromoteRecoveryWave(incomingWavePath, folderPath, "incoming.wav");
        var outgoingPath = outgoingEncoded
            ? outgoingM4aPath
            : PromoteRecoveryWave(outgoingWavePath, folderPath, "outgoing.wav");

        if (incomingEncoded)
        {
            TryDelete(incomingWavePath, warnings, "временную входящую WAV-дорожку");
        }

        if (outgoingEncoded)
        {
            TryDelete(outgoingWavePath, warnings, "временную WAV-дорожку микрофона");
        }

        if (string.Equals(combinedPath, combinedM4aPath, StringComparison.Ordinal))
        {
            TryDelete(combinedWavePath, warnings, "временную объединённую WAV-дорожку");
        }

        return new AudioFileFinalizationResult(
            incomingPath,
            outgoingPath,
            combinedPath,
            warnings);
    }

    private static bool TryEncodeM4a(
        string sourceWavePath,
        string finalM4aPath,
        string description,
        List<string> warnings)
    {
        // Media Foundation reliably selects its MPEG-4 sink from the .mp4
        // extension. The finalized MPEG-4/AAC file is then promoted to .m4a.
        var partialM4aPath = Path.Combine(
            Path.GetDirectoryName(finalM4aPath) ?? string.Empty,
            $"{Path.GetFileNameWithoutExtension(finalM4aPath)}.partial.mp4");
        TryDelete(partialM4aPath);

        try
        {
            using var reader = new WaveFileReader(sourceWavePath);
            ValidateCanonicalWaveFormat(reader.WaveFormat);
            MediaFoundationEncoder.EncodeToAac(reader, partialM4aPath, AacBitRate);
            File.Move(partialM4aPath, finalM4aPath, overwrite: true);
            return true;
        }
        catch (Exception exception) when (
            exception is IOException or InvalidDataException or InvalidOperationException or
            NotSupportedException or ArgumentException or UnauthorizedAccessException or
            System.Runtime.InteropServices.COMException)
        {
            TryDelete(partialM4aPath);
            warnings.Add(
                $"Media Foundation не смогла финализировать {description} в M4A; " +
                $"сохранён WAV: {exception.Message}");
            return false;
        }
    }

    private static void CreateCombinedWave(
        string incomingWavePath,
        string outgoingWavePath,
        string combinedWavePath)
    {
        TryDelete(combinedWavePath);
        using var incoming = new WaveFileReader(incomingWavePath);
        using var outgoing = new WaveFileReader(outgoingWavePath);
        ValidateCanonicalWaveFormat(incoming.WaveFormat);
        ValidateCanonicalWaveFormat(outgoing.WaveFormat);
        using var combined = new DurablePcmWaveWriter(combinedWavePath);

        var incomingBuffer = new byte[MixBufferByteCount];
        var outgoingBuffer = new byte[MixBufferByteCount];
        var mixedBuffer = new byte[MixBufferByteCount];

        while (true)
        {
            var incomingCount = ReadUpTo(incoming, incomingBuffer);
            var outgoingCount = ReadUpTo(outgoing, outgoingBuffer);
            var byteCount = Math.Max(incomingCount, outgoingCount);
            if (byteCount == 0)
            {
                break;
            }

            byteCount -= byteCount % Pcm24KhzMonoConverter.OutputBytesPerFrame;
            for (var offset = 0; offset < byteCount; offset += 2)
            {
                var incomingSample = offset < incomingCount
                    ? BinaryPrimitives.ReadInt16LittleEndian(incomingBuffer.AsSpan(offset, 2))
                    : (short)0;
                var outgoingSample = offset < outgoingCount
                    ? BinaryPrimitives.ReadInt16LittleEndian(outgoingBuffer.AsSpan(offset, 2))
                    : (short)0;
                var mixedSample = Math.Clamp(
                    incomingSample + outgoingSample,
                    short.MinValue,
                    short.MaxValue);
                BinaryPrimitives.WriteInt16LittleEndian(
                    mixedBuffer.AsSpan(offset, 2),
                    (short)mixedSample);
            }

            combined.Write(mixedBuffer.AsSpan(0, byteCount));
        }

        combined.FlushDurably();
    }

    private static int ReadUpTo(WaveFileReader reader, byte[] buffer)
    {
        var totalRead = 0;
        while (totalRead < buffer.Length)
        {
            var read = reader.Read(buffer, totalRead, buffer.Length - totalRead);
            if (read == 0)
            {
                break;
            }

            totalRead += read;
        }

        return totalRead;
    }

    private static void ValidateCanonicalWaveFormat(WaveFormat format)
    {
        if (format.Encoding != WaveFormatEncoding.Pcm ||
            format.SampleRate != Pcm24KhzMonoConverter.OutputSampleRate ||
            format.Channels != 1 ||
            format.BitsPerSample != 16)
        {
            throw new InvalidDataException($"Некорректный временный WAV-формат: {format}.");
        }
    }

    private static string PromoteRecoveryWave(
        string sourcePath,
        string folderPath,
        string fileName)
    {
        var destinationPath = Path.Combine(folderPath, fileName);
        File.Move(sourcePath, destinationPath, overwrite: true);
        return destinationPath;
    }

    private static void TryDelete(
        string path,
        List<string>? warnings = null,
        string? description = null)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException exception) when (warnings is not null)
        {
            warnings.Add($"Не удалось удалить {description ?? "временный файл"}: {exception.Message}");
        }
    }
}
