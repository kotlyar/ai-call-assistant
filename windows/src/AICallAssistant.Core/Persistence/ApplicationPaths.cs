namespace AICallAssistant.Core.Persistence;

public sealed class ApplicationPaths
{
    // Stable legacy names: changing these would hide data created before the Callya rename.
    public const string ApplicationDirectoryName = "com.aicallassistant.desktop";
    public const string RecordingsDirectoryName = "AI Call Assistant";
    public const string ContextLibraryFileName = "contexts.json";
    public const string SettingsFileName = "settings.json";
    public const string SecretFileName = "openai-api-key.dpapi";

    public ApplicationPaths()
        : this(ResolveLocalApplicationData(), ResolveDocumentsDirectory())
    {
    }

    public ApplicationPaths(string localApplicationDataDirectory, string documentsDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(localApplicationDataDirectory);
        ArgumentException.ThrowIfNullOrWhiteSpace(documentsDirectory);

        LocalApplicationDataDirectory = Path.GetFullPath(localApplicationDataDirectory);
        DocumentsDirectory = Path.GetFullPath(documentsDirectory);
        LocalDataRoot = Path.Combine(LocalApplicationDataDirectory, ApplicationDirectoryName);
        RecordingsRoot = Path.Combine(DocumentsDirectory, RecordingsDirectoryName);
        ContextLibraryFilePath = Path.Combine(LocalDataRoot, ContextLibraryFileName);
        SettingsFilePath = Path.Combine(LocalDataRoot, SettingsFileName);
        SecretsRoot = Path.Combine(LocalDataRoot, "Secrets");
        SecretFilePath = Path.Combine(SecretsRoot, SecretFileName);
    }

    public string LocalApplicationDataDirectory { get; }

    public string DocumentsDirectory { get; }

    public string LocalDataRoot { get; }

    public string RecordingsRoot { get; }

    public string ContextLibraryFilePath { get; }

    public string SettingsFilePath { get; }

    public string SecretsRoot { get; }

    public string SecretFilePath { get; }

    public static ApplicationPaths ForCurrentUser() => new();

    private static string ResolveLocalApplicationData()
    {
        var path = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        if (string.IsNullOrWhiteSpace(path))
        {
            path = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        }

        return RequireKnownFolder(path, "%LOCALAPPDATA%");
    }

    private static string ResolveDocumentsDirectory()
    {
        var path = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        return RequireKnownFolder(path, "Documents");
    }

    private static string RequireKnownFolder(string? path, string displayName)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException(
                $"Не удалось определить пользовательскую папку {displayName}.");
        }

        return path;
    }
}
