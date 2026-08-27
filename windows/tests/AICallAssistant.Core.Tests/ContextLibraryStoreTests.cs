using AICallAssistant.Core.Models;
using AICallAssistant.Core.Persistence;

namespace AICallAssistant.Core.Tests;

public sealed class ContextLibraryStoreTests
{
    [Fact]
    public async Task MissingLibraryLoadsAsEmpty()
    {
        using var temporaryDirectory = new TestDirectory();
        var store = new ContextLibraryStore(temporaryDirectory.RootPath);

        var contexts = await store.LoadAsync();

        Assert.Empty(contexts);
    }

    [Fact]
    public async Task CompleteLibraryRoundTripsInOrder()
    {
        using var temporaryDirectory = new TestDirectory();
        var store = new ContextLibraryStore(temporaryDirectory.RootPath);
        var firstId = Guid.Parse("10000000-0000-0000-0000-000000000001");
        var attachmentId = Guid.Parse("20000000-0000-0000-0000-000000000001");
        var contexts = new[]
        {
            new CallContext
            {
                Id = firstId,
                Title = "Резюме 👩🏽‍💻",
                Body = "Первая строка\nВторая строка",
                IsSelected = true,
                Attachments =
                [
                    new ContextFileAttachment
                    {
                        Id = attachmentId,
                        FileName = "CV Андрея 📄.pdf",
                        MediaType = "application/pdf",
                        ByteCount = 12_345,
                        ContentSha256 = new string('a', 64),
                        ExtractedText = "Unicode: 你好, مرحبا, 🙂"
                    }
                ]
            },
            new CallContext
            {
                Title = "Вакансия",
                Body = "Head of Product"
            }
        };

        await store.SaveAsync(contexts);
        var reloaded = await store.LoadAsync();

        Assert.Equal(2, reloaded.Count);
        Assert.Equal(firstId, reloaded[0].Id);
        Assert.Equal("Резюме 👩🏽‍💻", reloaded[0].Title);
        Assert.True(reloaded[0].IsSelected);
        var attachment = Assert.Single(reloaded[0].Attachments);
        Assert.Equal(attachmentId, attachment.Id);
        Assert.Equal("Unicode: 你好, مرحبا, 🙂", attachment.ExtractedText);
        Assert.Equal("Вакансия", reloaded[1].Title);
    }

    [Fact]
    public async Task CorruptLibraryIsMovedToRecoveryBeforeStartingEmpty()
    {
        using var temporaryDirectory = new TestDirectory();
        var store = new ContextLibraryStore(temporaryDirectory.RootPath);
        var corruptBytes = "future-or-corrupt-library"u8.ToArray();
        await File.WriteAllBytesAsync(store.FilePath, corruptBytes);

        var contexts = await store.LoadAsync();

        Assert.Empty(contexts);
        Assert.False(File.Exists(store.FilePath));
        var recoveryPath = Assert.Single(
            Directory.EnumerateFiles(temporaryDirectory.RootPath),
            path => Path.GetFileName(path).StartsWith(
                    ContextLibraryStore.RecoveryFilePrefix,
                    StringComparison.Ordinal));
        Assert.Equal(corruptBytes, await File.ReadAllBytesAsync(recoveryPath));

        await store.SaveAsync([new CallContext { Title = "Recovered edit" }]);
        Assert.Equal("Recovered edit", Assert.Single(await store.LoadAsync()).Title);
    }
}
