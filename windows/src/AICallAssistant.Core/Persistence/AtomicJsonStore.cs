using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AICallAssistant.Core.Persistence;

public sealed class AtomicJsonStore
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> FileGates =
        new(StringComparer.OrdinalIgnoreCase);

    private readonly JsonSerializerOptions _serializerOptions;

    public AtomicJsonStore()
    {
        _serializerOptions = CreateSerializerOptions();
    }

    public static JsonSerializerOptions CreateSerializerOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DictionaryKeyPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            WriteIndented = true
        };
        options.Converters.Add(
            new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false));
        return options;
    }

    public async Task<T?> ReadAsync<T>(
        string filePath,
        CancellationToken cancellationToken = default)
    {
        var normalizedPath = NormalizeFilePath(filePath);
        if (!File.Exists(normalizedPath))
        {
            return default;
        }

        await using var stream = new FileStream(
            normalizedPath,
            new FileStreamOptions
            {
                Mode = FileMode.Open,
                Access = FileAccess.Read,
                Share = FileShare.Read | FileShare.Delete,
                Options = FileOptions.Asynchronous | FileOptions.SequentialScan
            });
        return await JsonSerializer.DeserializeAsync<T>(
            stream,
            _serializerOptions,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task WriteAsync<T>(
        string filePath,
        T value,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(value);

        var normalizedPath = NormalizeFilePath(filePath);
        var gate = FileGates.GetOrAdd(normalizedPath, static _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);

        string? temporaryPath = null;
        try
        {
            var directoryPath = Path.GetDirectoryName(normalizedPath)
                ?? throw new ArgumentException("Путь к JSON-файлу не содержит папку.", nameof(filePath));
            Directory.CreateDirectory(directoryPath);

            temporaryPath = Path.Combine(
                directoryPath,
                $".{Path.GetFileName(normalizedPath)}.{Guid.NewGuid():N}.tmp");

            await using (var stream = new FileStream(
                temporaryPath,
                new FileStreamOptions
                {
                    Mode = FileMode.CreateNew,
                    Access = FileAccess.Write,
                    Share = FileShare.None,
                    BufferSize = 16 * 1024,
                    Options = FileOptions.Asynchronous | FileOptions.WriteThrough
                }))
            {
                await JsonSerializer.SerializeAsync(
                    stream,
                    value,
                    _serializerOptions,
                    cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryPath, normalizedPath, overwrite: true);
            temporaryPath = null;
        }
        finally
        {
            if (temporaryPath is not null)
            {
                try
                {
                    File.Delete(temporaryPath);
                }
                catch (IOException)
                {
                    // A failed cleanup must not hide the original persistence error.
                }
                catch (UnauthorizedAccessException)
                {
                    // A failed cleanup must not hide the original persistence error.
                }
            }

            gate.Release();
        }
    }

    private static string NormalizeFilePath(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        return Path.GetFullPath(filePath);
    }
}
