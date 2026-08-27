using System.Text.Json;
using AICallAssistant.Core.Models;
using AICallAssistant.Core.Persistence;

namespace AICallAssistant.Core.Tests;

public sealed class AtomicJsonStoreTests
{
    [Fact]
    public async Task RoundTripUsesCamelCasePropertiesAndStringEnums()
    {
        using var temporaryDirectory = new TestDirectory();
        var filePath = Path.Combine(temporaryDirectory.RootPath, "settings.json");
        var store = new AtomicJsonStore();
        var settings = new AppSettings
        {
            AnswerStyle = AnswerStyle.Detailed,
            AnswerLanguage = AnswerLanguage.Russian
        };

        await store.WriteAsync(filePath, settings);

        var json = await File.ReadAllTextAsync(filePath);
        using var document = JsonDocument.Parse(json);
        Assert.Equal(
            "detailed",
            document.RootElement.GetProperty("answerStyle").GetString());
        Assert.Equal(
            "russian",
            document.RootElement.GetProperty("answerLanguage").GetString());
        Assert.True(document.RootElement.TryGetProperty("responsesModelId", out _));
        Assert.False(document.RootElement.TryGetProperty("ResponsesModelId", out _));

        var reloaded = await store.ReadAsync<AppSettings>(filePath);
        Assert.NotNull(reloaded);
        Assert.Equal(AnswerStyle.Detailed, reloaded.AnswerStyle);
        Assert.Equal(AnswerLanguage.Russian, reloaded.AnswerLanguage);
    }

    [Fact]
    public async Task SerializationFailureKeepsPreviousFileAndRemovesTemporaryFile()
    {
        using var temporaryDirectory = new TestDirectory();
        var filePath = Path.Combine(temporaryDirectory.RootPath, "atomic.json");
        var store = new AtomicJsonStore();
        await store.WriteAsync(filePath, new { value = "known-good" });
        var originalBytes = await File.ReadAllBytesAsync(filePath);
        var cyclic = new CyclicValue();
        cyclic.Self = cyclic;

        await Assert.ThrowsAsync<JsonException>(() => store.WriteAsync(filePath, cyclic));

        Assert.Equal(originalBytes, await File.ReadAllBytesAsync(filePath));
        Assert.DoesNotContain(
            Directory.EnumerateFiles(temporaryDirectory.RootPath),
            static path => path.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase));
    }

    private sealed class CyclicValue
    {
        public CyclicValue? Self { get; set; }
    }
}
