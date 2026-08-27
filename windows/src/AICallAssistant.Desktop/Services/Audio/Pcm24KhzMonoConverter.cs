using System.Buffers.Binary;
using NAudio.Wave;

namespace AICallAssistant.Desktop.Services.Audio;

/// <summary>
/// Stateful streaming converter for the PCM and IEEE-float formats returned by
/// shared-mode WASAPI. It downmixes channels before linearly resampling so both
/// capture tracks expose the exact Realtime API format.
/// </summary>
internal sealed class Pcm24KhzMonoConverter
{
    public const int OutputSampleRate = 24_000;
    public const int OutputBytesPerFrame = 2;

    private readonly int sourceSampleRate;
    private readonly int sourceChannels;
    private readonly int sourceBitsPerSample;
    private readonly int sourceBlockAlign;
    private readonly WaveFormatEncoding sourceEncoding;
    private readonly double sourceFramesPerOutputFrame;

    private byte[] remainder = [];
    private long sourceFrameOffset;
    private double nextOutputSourcePosition;
    private float previousSample;
    private bool hasPreviousSample;

    public Pcm24KhzMonoConverter(WaveFormat sourceFormat)
    {
        ArgumentNullException.ThrowIfNull(sourceFormat);
        sourceSampleRate = sourceFormat.SampleRate;
        sourceChannels = sourceFormat.Channels;
        sourceBitsPerSample = sourceFormat.BitsPerSample;
        sourceBlockAlign = sourceFormat.BlockAlign;
        sourceEncoding = ResolveEncoding(sourceFormat);

        if (sourceSampleRate <= 0 || sourceChannels <= 0 || sourceBlockAlign <= 0)
        {
            throw new NotSupportedException($"Некорректный формат WASAPI: {sourceFormat}.");
        }

        var supported = sourceEncoding switch
        {
            WaveFormatEncoding.Pcm => sourceBitsPerSample is 8 or 16 or 24 or 32,
            WaveFormatEncoding.IeeeFloat => sourceBitsPerSample is 32 or 64,
            _ => false
        };
        if (!supported)
        {
            throw new NotSupportedException(
                $"Формат WASAPI {sourceFormat} не поддерживается конвертером PCM.");
        }

        var expectedBlockAlign = checked(sourceChannels * (sourceBitsPerSample / 8));
        if (expectedBlockAlign != sourceBlockAlign)
        {
            throw new NotSupportedException(
                $"Формат WASAPI содержит неподдерживаемое выравнивание: {sourceFormat}.");
        }

        sourceFramesPerOutputFrame = (double)sourceSampleRate / OutputSampleRate;
    }

    public byte[] Convert(byte[] buffer, int offset, int count)
    {
        ArgumentNullException.ThrowIfNull(buffer);
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        ArgumentOutOfRangeException.ThrowIfNegative(count);
        if (offset > buffer.Length - count)
        {
            throw new ArgumentException("Audio buffer range is outside the source array.");
        }

        if (count == 0)
        {
            return [];
        }

        var combined = new byte[checked(remainder.Length + count)];
        remainder.CopyTo(combined, 0);
        Buffer.BlockCopy(buffer, offset, combined, remainder.Length, count);

        var completeByteCount = combined.Length - (combined.Length % sourceBlockAlign);
        var frameCount = completeByteCount / sourceBlockAlign;
        var remainderCount = combined.Length - completeByteCount;
        remainder = remainderCount == 0
            ? []
            : combined.AsSpan(completeByteCount, remainderCount).ToArray();

        if (frameCount == 0)
        {
            return [];
        }

        var monoSamples = new float[frameCount];
        var completeFrames = combined.AsSpan(0, completeByteCount);
        for (var frame = 0; frame < frameCount; frame++)
        {
            double sum = 0;
            var frameOffset = frame * sourceBlockAlign;
            var bytesPerSample = sourceBitsPerSample / 8;
            for (var channel = 0; channel < sourceChannels; channel++)
            {
                var sampleOffset = frameOffset + (channel * bytesPerSample);
                sum += ReadSample(completeFrames.Slice(sampleOffset, bytesPerSample));
            }

            monoSamples[frame] = (float)(sum / sourceChannels);
        }

        var estimatedOutputCount = checked(
            (int)Math.Ceiling((frameCount + 1) / sourceFramesPerOutputFrame) + 1);
        var outputSamples = new List<short>(Math.Max(estimatedOutputCount, 1));
        var firstSourceIndex = sourceFrameOffset;
        var lastSourceIndex = checked(firstSourceIndex + frameCount - 1);
        const double integerTolerance = 1e-9;

        while (nextOutputSourcePosition <= lastSourceIndex + integerTolerance)
        {
            var lowerIndex = (long)Math.Floor(nextOutputSourcePosition);
            var fraction = nextOutputSourcePosition - lowerIndex;
            if (fraction < integerTolerance)
            {
                fraction = 0;
            }

            var upperIndex = fraction == 0 ? lowerIndex : lowerIndex + 1;
            if (upperIndex > lastSourceIndex)
            {
                break;
            }

            if (lowerIndex < firstSourceIndex - 1 ||
                (lowerIndex == firstSourceIndex - 1 && !hasPreviousSample))
            {
                break;
            }

            var lower = SampleAt(lowerIndex, firstSourceIndex, monoSamples);
            var upper = SampleAt(upperIndex, firstSourceIndex, monoSamples);
            var interpolated = lower + ((upper - lower) * fraction);
            outputSamples.Add(ToPcm16(interpolated));
            nextOutputSourcePosition += sourceFramesPerOutputFrame;
        }

        sourceFrameOffset = checked(sourceFrameOffset + frameCount);
        previousSample = monoSamples[^1];
        hasPreviousSample = true;

        var output = new byte[checked(outputSamples.Count * OutputBytesPerFrame)];
        for (var index = 0; index < outputSamples.Count; index++)
        {
            BinaryPrimitives.WriteInt16LittleEndian(
                output.AsSpan(index * OutputBytesPerFrame, OutputBytesPerFrame),
                outputSamples[index]);
        }

        return output;
    }

    public static double ComputeRms(ReadOnlySpan<byte> pcm16LittleEndian)
    {
        var sampleCount = pcm16LittleEndian.Length / OutputBytesPerFrame;
        if (sampleCount == 0)
        {
            return 0;
        }

        double sumSquares = 0;
        for (var offset = 0; offset < sampleCount * OutputBytesPerFrame; offset += 2)
        {
            var sample = BinaryPrimitives.ReadInt16LittleEndian(
                pcm16LittleEndian.Slice(offset, OutputBytesPerFrame));
            var normalized = sample / 32768d;
            sumSquares += normalized * normalized;
        }

        return Math.Sqrt(sumSquares / sampleCount);
    }

    private static WaveFormatEncoding ResolveEncoding(WaveFormat sourceFormat)
    {
        if (sourceFormat.Encoding != WaveFormatEncoding.Extensible)
        {
            return sourceFormat.Encoding;
        }

        if (sourceFormat is not WaveFormatExtensible extensible)
        {
            throw new NotSupportedException(
                $"WASAPI вернул WAVE_FORMAT_EXTENSIBLE без описания subformat: {sourceFormat}.");
        }

        if (extensible.SubFormat == AudioMediaSubtypes.MEDIASUBTYPE_PCM)
        {
            return WaveFormatEncoding.Pcm;
        }

        if (extensible.SubFormat == AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT)
        {
            return WaveFormatEncoding.IeeeFloat;
        }

        throw new NotSupportedException(
            $"WASAPI subformat {extensible.SubFormat} не поддерживается конвертером PCM.");
    }

    private float ReadSample(ReadOnlySpan<byte> sampleBytes) => sourceEncoding switch
    {
        WaveFormatEncoding.Pcm => sourceBitsPerSample switch
        {
            8 => (sampleBytes[0] - 128) / 128f,
            16 => BinaryPrimitives.ReadInt16LittleEndian(sampleBytes) / 32768f,
            24 => ReadPcm24(sampleBytes) / 8_388_608f,
            32 => (float)(BinaryPrimitives.ReadInt32LittleEndian(sampleBytes) / 2_147_483_648d),
            _ => 0
        },
        WaveFormatEncoding.IeeeFloat => sourceBitsPerSample switch
        {
            32 => ReadFloat32(sampleBytes),
            64 => ReadFloat64(sampleBytes),
            _ => 0
        },
        _ => 0
    };

    private static int ReadPcm24(ReadOnlySpan<byte> bytes)
    {
        var value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
        return (value & 0x0080_0000) == 0 ? value : value | unchecked((int)0xFF00_0000);
    }

    private static float ReadFloat32(ReadOnlySpan<byte> bytes)
    {
        var value = BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes));
        return float.IsFinite(value) ? value : 0;
    }

    private static float ReadFloat64(ReadOnlySpan<byte> bytes)
    {
        var value = BitConverter.Int64BitsToDouble(BinaryPrimitives.ReadInt64LittleEndian(bytes));
        return double.IsFinite(value) ? (float)value : 0;
    }

    private float SampleAt(long absoluteIndex, long firstIndex, float[] currentSamples)
    {
        if (absoluteIndex == firstIndex - 1)
        {
            return previousSample;
        }

        return currentSamples[checked((int)(absoluteIndex - firstIndex))];
    }

    private static short ToPcm16(double sample)
    {
        var clamped = Math.Clamp(sample, -1d, 1d);
        return clamped < 0
            ? (short)Math.Round(clamped * 32768d)
            : (short)Math.Round(clamped * 32767d);
    }
}
