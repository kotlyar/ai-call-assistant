using System.Text.Json;
using AICallAssistant.Core.Contracts;
using AICallAssistant.Core.Models;

namespace AICallAssistant.Core.Persistence;

public sealed class ContextLibraryStore : IContextLibraryStore
{
    public const int CurrentSchemaVersion = 1;
    public const string FileName = ApplicationPaths.ContextLibraryFileName;
    public const string RecoveryFilePrefix = "contexts.recovery.";

    private readonly AtomicJsonStore _jsonStore;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public ContextLibraryStore(ApplicationPaths paths, AtomicJsonStore? jsonStore = null)
        : this(GetLocalDataRoot(paths), jsonStore)
    {
    }

    public ContextLibraryStore(string rootPath, AtomicJsonStore? jsonStore = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rootPath);
        RootPath = Path.GetFullPath(rootPath);
        FilePath = Path.Combine(RootPath, FileName);
        _jsonStore = jsonStore ?? new AtomicJsonStore();
    }

    public string RootPath { get; }

    public string FilePath { get; }

    public async Task<IReadOnlyList<CallContext>> LoadAsync(
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!File.Exists(FilePath))
            {
                return Array.Empty<CallContext>();
            }

            try
            {
                var document = await _jsonStore.ReadAsync<ContextLibraryDocument>(
                    FilePath,
                    cancellationToken).ConfigureAwait(false);
                if (document is null)
                {
                    throw new InvalidDataException("Файл библиотеки контекстов пуст.");
                }

                if (document.SchemaVersion != CurrentSchemaVersion)
                {
                    throw new InvalidDataException(
                        $"Версия библиотеки контекстов {document.SchemaVersion} не поддерживается.");
                }

                if (document.Contexts is null)
                {
                    throw new InvalidDataException("В библиотеке отсутствует список контекстов.");
                }

                return document.Contexts.ToArray();
            }
            catch (Exception exception) when (
                exception is JsonException or NotSupportedException or InvalidDataException)
            {
                PreserveForRecovery();
                return Array.Empty<CallContext>();
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SaveAsync(
        IEnumerable<CallContext> contexts,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(contexts);
        var snapshot = contexts.ToList();
        if (snapshot.Any(static context => context is null))
        {
            throw new ArgumentException("Библиотека не может содержать пустой контекст.", nameof(contexts));
        }

        var document = new ContextLibraryDocument
        {
            SchemaVersion = CurrentSchemaVersion,
            Contexts = snapshot
        };

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await _jsonStore.WriteAsync(FilePath, document, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private void PreserveForRecovery()
    {
        Directory.CreateDirectory(RootPath);
        var recoveryPath = Path.Combine(
            RootPath,
            $"{RecoveryFilePrefix}{DateTimeOffset.UtcNow:yyyyMMddHHmmssfff}.{Guid.NewGuid():N}.json");
        File.Move(FilePath, recoveryPath);
    }

    private static string GetLocalDataRoot(ApplicationPaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        return paths.LocalDataRoot;
    }

    private sealed class ContextLibraryDocument
    {
        public int SchemaVersion { get; set; }
        public List<CallContext>? Contexts { get; set; }
    }
}
