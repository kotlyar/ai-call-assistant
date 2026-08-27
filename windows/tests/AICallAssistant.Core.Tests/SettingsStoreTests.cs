using System.Text.Json;
using AICallAssistant.Core.Models;
using AICallAssistant.Core.Persistence;

namespace AICallAssistant.Core.Tests;

public sealed class SettingsStoreTests
{
    [Fact]
    public async Task MissingAndCorruptFilesLoadDefaults()
    {
        using var temporaryDirectory = new TestDirectory();
        var store = new SettingsStore(temporaryDirectory.RootPath);

        var missing = await store.LoadAsync();
        Assert.Equal("gpt-5.6-terra", missing.ResponsesModelId);
        Assert.Equal(AnswerStyle.Brief, missing.AnswerStyle);

        Directory.CreateDirectory(temporaryDirectory.RootPath);
        await File.WriteAllTextAsync(store.FilePath, "{not-json");
        var corrupt = await store.LoadAsync();
        Assert.Equal("gpt-5.6-terra", corrupt.ResponsesModelId);
        Assert.Equal(AnswerLanguage.Automatic, corrupt.AnswerLanguage);
    }

    [Fact]
    public async Task ValidSettingsRoundTripAndUseStringEnum()
    {
        using var temporaryDirectory = new TestDirectory();
        var store = new SettingsStore(temporaryDirectory.RootPath);
        var settings = new AppSettings
        {
            AnswerStyle = AnswerStyle.Detailed,
            DetailedAnswerMaxWords = 240,
            PerCallSpendLimitUsd = 3.25m
        };

        await store.SaveAsync(settings);
        var reloaded = await store.LoadAsync();

        Assert.Equal(AnswerStyle.Detailed, reloaded.AnswerStyle);
        Assert.Equal(240, reloaded.DetailedAnswerMaxWords);
        Assert.Equal(3.25m, reloaded.PerCallSpendLimitUsd);
        using var json = JsonDocument.Parse(await File.ReadAllTextAsync(store.FilePath));
        Assert.Equal("detailed", json.RootElement.GetProperty("answerStyle").GetString());
    }

    [Fact]
    public async Task InvalidSettingsAreRejectedBeforeFileIsWritten()
    {
        using var temporaryDirectory = new TestDirectory();
        var store = new SettingsStore(temporaryDirectory.RootPath);
        var settings = new AppSettings { MaxOutputTokens = 0 };

        await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync(settings));

        Assert.False(File.Exists(store.FilePath));
    }
}
