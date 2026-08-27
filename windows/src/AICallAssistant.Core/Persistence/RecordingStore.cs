using System.Text.Json;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;

namespace AICallAssistant.Core.Persistence;

public sealed class RecordingStore : IRecordingStore
{
    public const string MetadataFileName = "metadata.json";

    private static readonly char[] WindowsInvalidFileNameCharacters =
        ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];

    private static readonly HashSet<string> WindowsReservedNames = new(
        [
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        ],
        StringComparer.OrdinalIgnoreCase);

    private readonly AtomicJsonStore _jsonStore;

    public RecordingStore(ApplicationPaths paths, AtomicJsonStore? jsonStore = null)
        : this(GetRecordingsRoot(paths), jsonStore)
    {
    }

    public RecordingStore(string rootPath, AtomicJsonStore? jsonStore = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        RootPath = Path.GetFullPath(rootPath);
        _jsonStore = jsonStore ?? new AtomicJsonStore();
    }

    public string RootPath { get; }

    public async Task<IReadOnlyList<Recording>> LoadAllAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(RootPath))
        {
            return Array.Empty<Recording>();
        }

        var recordings = new List<Recording>();
        foreach (var folderPath in Directory.EnumerateDirectories(RootPath))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                if (File.GetAttributes(folderPath).HasFlag(FileAttributes.ReparsePoint))
                {
                    continue;
                }

                var folderName = Path.GetFileName(folderPath);
                ValidateFolderName(folderName);
                var recording = await ReadFromFolderAsync(
                    folderPath,
                    folderName,
                    cancellationToken).ConfigureAwait(false);
                if (recording is not null)
                {
                    recordings.Add(recording);
                }
            }
            catch (Exception exception) when (
                exception is JsonException or NotSupportedException or InvalidDataException or
                    IOException or UnauthorizedAccessException or ArgumentException)
            {
                // One damaged recording must not hide the rest of the local library.
            }
        }

        return recordings
            .OrderByDescending(static recording => recording.StartedAt)
            .ThenBy(static recording => recording.Id)
            .ToArray();
    }

    public async Task<Recording> LoadAsync(
        string folderName,
        CancellationToken cancellationToken = default)
    {
        ValidateFolderName(folderName);
        var folderPath = Path.Combine(RootPath, folderName);
        var recording = await ReadFromFolderAsync(
            folderPath,
            folderName,
            cancellationToken).ConfigureAwait(false);
        return recording ?? throw new FileNotFoundException(
            "Метаданные записи не найдены.",
            Path.Combine(folderPath, MetadataFileName));
    }

    public async Task SaveAsync(
        Recording recording,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(recording);
        var folderPath = GetFolderPath(recording);
        if (Directory.Exists(folderPath) &&
            File.GetAttributes(folderPath).HasFlag(FileAttributes.ReparsePoint))
        {
            throw new IOException("Папка записи не может быть ссылкой или reparse point.");
        }

        Directory.CreateDirectory(folderPath);
        var metadataPath = Path.Combine(folderPath, MetadataFileName);
        await _jsonStore.WriteAsync(metadataPath, recording, cancellationToken).ConfigureAwait(false);
    }

    public string GetFolderPath(Recording recording)
    {
        ArgumentNullException.ThrowIfNull(recording);
        ValidateFolderName(recording.FolderName);
        return Path.Combine(RootPath, recording.FolderName);
    }

    public static void ValidateFolderName(string folderName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(folderName);

        if (folderName is "." or ".." ||
            folderName.Length > 255 ||
            folderName.EndsWith(' ') ||
            folderName.EndsWith('.') ||
            folderName.IndexOfAny(WindowsInvalidFileNameCharacters) >= 0 ||
            folderName.Any(static character => char.IsControl(character)))
        {
            throw new ArgumentException("Недопустимое имя папки записи.", nameof(folderName));
        }

        var deviceName = folderName.Split('.', 2)[0];
        if (WindowsReservedNames.Contains(deviceName))
        {
            throw new ArgumentException("Имя папки записи зарезервировано Windows.", nameof(folderName));
        }
    }

    private async Task<Recording?> ReadFromFolderAsync(
        string folderPath,
        string expectedFolderName,
        CancellationToken cancellationToken)
    {
        var metadataPath = Path.Combine(folderPath, MetadataFileName);
        var recording = await _jsonStore.ReadAsync<Recording>(
            metadataPath,
            cancellationToken).ConfigureAwait(false);
        if (recording is null)
        {
            return null;
        }

        if (!string.Equals(
            recording.FolderName,
            expectedFolderName,
            StringComparison.Ordinal))
        {
            throw new InvalidDataException(
                $"Папка метаданных '{recording.FolderName}' не совпадает с '{expectedFolderName}'.");
        }

        return recording;
    }

    private static string GetRecordingsRoot(ApplicationPaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        return paths.RecordingsRoot;
    }
}
