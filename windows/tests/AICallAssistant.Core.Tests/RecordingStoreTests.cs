using System.Text.Json;
using AICallAssistant.Core.Models;
using AICallAssistant.Core.Persistence;

namespace AICallAssistant.Core.Tests;

public sealed class RecordingStoreTests
{
    [Fact]
    public async Task SavesMetadataAndLoadsNewestFirstWhileSkippingDamagedFolders()
    {
        using var temporaryDirectory = new TestDirectory();
        var store = new RecordingStore(temporaryDirectory.RootPath);
        var older = MakeRecording(
            Guid.Parse("00000000-0000-0000-0000-000000000001"),
            "older",
            DateTimeOffset.Parse("2026-08-18T10:00:00Z"));
        var newer = MakeRecording(
            Guid.Parse("00000000-0000-0000-0000-000000000002"),
            "newer",
            DateTimeOffset.Parse("2026-08-18T11:00:00Z"));

        await store.SaveAsync(older);
        await store.SaveAsync(newer);
        var damagedFolder = Path.Combine(temporaryDirectory.RootPath, "damaged");
        Directory.CreateDirectory(damagedFolder);
        await File.WriteAllTextAsync(
            Path.Combine(damagedFolder, RecordingStore.MetadataFileName),
            "{broken");

        var recordings = await store.LoadAllAsync();

        Assert.Equal(new[] { newer.Id, older.Id }, recordings.Select(static item => item.Id));
        var metadataPath = Path.Combine(
            store.GetFolderPath(newer),
            RecordingStore.MetadataFileName);
        Assert.True(File.Exists(metadataPath));
        using var metadata = JsonDocument.Parse(await File.ReadAllTextAsync(metadataPath));
        Assert.Equal(
            "ready",
            metadata.RootElement.GetProperty("status").GetString());
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData(".")]
    [InlineData("..")]
    [InlineData("../outside")]
    [InlineData("folder\\outside")]
    [InlineData("bad:name")]
    [InlineData("bad|name")]
    [InlineData("name.")]
    [InlineData("name ")]
    [InlineData("CON")]
    [InlineData("nul.txt")]
    [InlineData("COM1")]
    [InlineData("lpt9.log")]
    public void RejectsUnsafeWindowsFolderNames(string folderName)
    {
        Assert.Throws<ArgumentException>(() => RecordingStore.ValidateFolderName(folderName));
    }

    [Fact]
    public void RejectsFolderNameLongerThanNtfsComponentLimit()
    {
        Assert.Throws<ArgumentException>(
            () => RecordingStore.ValidateFolderName(new string('a', 256)));
    }

    [Theory]
    [InlineData("2026-08-19_call")]
    [InlineData("Встреча с командой")]
    [InlineData("COM10")]
    public void AcceptsSafeWindowsFolderNames(string folderName)
    {
        RecordingStore.ValidateFolderName(folderName);
    }

    private static Recording MakeRecording(
        Guid id,
        string folderName,
        DateTimeOffset startedAt) => new()
    {
        Id = id,
        Title = "Test call",
        FolderName = folderName,
        StartedAt = startedAt,
        Duration = TimeSpan.FromSeconds(42),
        Status = ProcessingStatus.Ready,
        Turns =
        [
            new TranscriptTurn
            {
                Speaker = TranscriptSpeaker.Participant,
                Offset = TimeSpan.FromSeconds(3.5),
                Text = "Здравствуйте"
            }
        ]
    };
}
