namespace AICallAssistant.Core.Tests;

internal sealed class TestDirectory : IDisposable
{
    public TestDirectory()
    {
        RootPath = Path.Combine(
            Path.GetTempPath(),
            "AICallAssistant.Core.Tests",
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(RootPath);
    }

    public string RootPath { get; }

    public void Dispose()
    {
        if (Directory.Exists(RootPath))
        {
            Directory.Delete(RootPath, recursive: true);
        }
    }
}
