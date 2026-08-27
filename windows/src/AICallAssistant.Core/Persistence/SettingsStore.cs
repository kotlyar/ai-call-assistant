using System.Text.Json;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;

namespace AICallAssistant.Core.Persistence;

public sealed class SettingsStore : ISettingsStore
{
    public const string FileName = ApplicationPaths.SettingsFileName;

    private readonly AtomicJsonStore _jsonStore;

    public SettingsStore(ApplicationPaths paths, AtomicJsonStore? jsonStore = null)
        : this(GetLocalDataRoot(paths), jsonStore)
    {
    }

    public SettingsStore(string rootPath, AtomicJsonStore? jsonStore = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        RootPath = Path.GetFullPath(rootPath);
        FilePath = Path.Combine(RootPath, FileName);
        _jsonStore = jsonStore ?? new AtomicJsonStore();
    }

    public string RootPath { get; }

    public string FilePath { get; }

    public async Task<AppSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var settings = await _jsonStore.ReadAsync<AppSettings>(
                FilePath,
                cancellationToken).ConfigureAwait(false);
            if (settings is null || settings.TranscriptionLanguages is null)
            {
                return new AppSettings();
            }

            settings.Validate();
            return settings;
        }
        catch (Exception exception) when (
            exception is JsonException or NotSupportedException or InvalidOperationException)
        {
            return new AppSettings();
        }
    }

    public async Task SaveAsync(
        AppSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        settings.Validate();
        await _jsonStore.WriteAsync(FilePath, settings, cancellationToken).ConfigureAwait(false);
    }

    private static string GetLocalDataRoot(ApplicationPaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        return paths.LocalDataRoot;
    }
}
