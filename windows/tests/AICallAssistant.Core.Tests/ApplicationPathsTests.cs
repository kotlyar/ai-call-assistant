using AICallAssistant.Core.Persistence;

namespace AICallAssistant.Core.Tests;

public sealed class ApplicationPathsTests
{
    [Fact]
    public void ExplicitRootsSeparateLocalStateFromRecordings()
    {
        using var temporaryDirectory = new TestDirectory();
        var localAppData = Path.Combine(temporaryDirectory.RootPath, "LocalAppData");
        var documents = Path.Combine(temporaryDirectory.RootPath, "Documents");

        var paths = new ApplicationPaths(localAppData, documents);

        Assert.Equal(
            Path.Combine(localAppData, ApplicationPaths.ApplicationDirectoryName),
            paths.LocalDataRoot);
        Assert.Equal(
            Path.Combine(documents, ApplicationPaths.RecordingsDirectoryName),
            paths.RecordingsRoot);
        Assert.Equal(
            Path.Combine(paths.LocalDataRoot, "contexts.json"),
            paths.ContextLibraryFilePath);
        Assert.Equal(
            Path.Combine(paths.LocalDataRoot, "settings.json"),
            paths.SettingsFilePath);
        Assert.Equal(
            Path.Combine(paths.LocalDataRoot, "Secrets", "openai-api-key.dpapi"),
            paths.SecretFilePath);
    }
}
