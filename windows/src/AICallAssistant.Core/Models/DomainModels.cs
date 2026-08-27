using System.Text.Json.Serialization;

namespace AICallAssistant.Core.Models;

public enum AppSection
{
    Setup,
    Contexts,
    Recordings,
    Settings
}

public enum AudioSourceKind
{
    SystemAudio,
    Process,
    Microphone
}

public enum AudioTrack
{
    Incoming,
    Outgoing
}

public enum TranscriptSpeaker
{
    Participant,
    You
}

public enum ProcessingStatus
{
    LocalOnly,
    Processing,
    Ready,
    WaitingForCredential,
    Failed
}

public enum AnswerStyle
{
    Brief,
    Detailed
}

public enum AnswerLanguage
{
    Automatic,
    Russian,
    English
}

public sealed record AudioSourceOption(
    string Id,
    string Title,
    AudioSourceKind Kind,
    int? ProcessId = null,
    string? DeviceId = null)
{
    public static AudioSourceOption SystemAudio { get; } = new(
        "system-audio",
        "Весь системный звук",
        AudioSourceKind.SystemAudio);
}

public sealed class ContextFileAttachment
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string FileName { get; set; } = string.Empty;
    public string MediaType { get; set; } = "application/octet-stream";
    public long ByteCount { get; set; }
    public string ContentSha256 { get; set; } = string.Empty;
    public string ExtractedText { get; set; } = string.Empty;
}

public sealed class CallContext
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = string.Empty;
    public string Body { get; set; } = string.Empty;
    public bool IsSelected { get; set; }
    public List<ContextFileAttachment> Attachments { get; set; } = [];

    [JsonIgnore]
    public string AssistantBody
    {
        get
        {
            var sections = new List<string>();
            if (!string.IsNullOrWhiteSpace(Body))
            {
                sections.Add(Body.Trim());
            }

            sections.AddRange(Attachments.Select(attachment =>
                $"<<< BEGIN CONTEXT FILE: {SanitizeFileName(attachment.FileName)} >>>\n" +
                $"{attachment.ExtractedText}\n" +
                $"<<< END CONTEXT FILE: {SanitizeFileName(attachment.FileName)} >>>"));
            return string.Join("\n\n", sections);
        }
    }

    private static string SanitizeFileName(string value) =>
        value.Replace("\r", " ", StringComparison.Ordinal)
            .Replace("\n", " ", StringComparison.Ordinal);
}

public sealed class TranscriptTurn
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public TranscriptSpeaker Speaker { get; set; }
    public TimeSpan Offset { get; set; }
    public string Text { get; set; } = string.Empty;
    public bool IsFinal { get; set; } = true;
}

public sealed class GuidanceCard
{
    public string Question { get; set; } = string.Empty;
    public string Answer { get; set; } = string.Empty;
    public string Advice { get; set; } = string.Empty;
    public string Evidence { get; set; } = string.Empty;
    public bool IsLate { get; set; }
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class FinalAnalysis
{
    public string Summary { get; set; } = string.Empty;
    public List<GuidanceCard> QuestionAnswers { get; set; } = [];
}

public sealed class Recording
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = string.Empty;
    public DateTimeOffset StartedAt { get; set; }
    public TimeSpan Duration { get; set; }
    public string FolderName { get; set; } = string.Empty;
    public string IncomingAudioFileName { get; set; } = "incoming.m4a";
    public string OutgoingAudioFileName { get; set; } = "outgoing.m4a";
    public string? CombinedAudioFileName { get; set; } = "combined.m4a";
    public ProcessingStatus Status { get; set; } = ProcessingStatus.LocalOnly;
    public string? LastError { get; set; }
    public List<TranscriptTurn> Turns { get; set; } = [];
    public List<CallContext> FrozenContexts { get; set; } = [];
    public AppSettings FrozenSettings { get; set; } = new();
    public FinalAnalysis? Analysis { get; set; }
}

public sealed class AppSettings
{
    public string ResponsesModelId { get; set; } = "gpt-5.6-terra";
    public string RealtimeTranscriptionModelId { get; set; } = "gpt-live-transcribe";
    public string FileTranscriptionModelId { get; set; } = "gpt-transcribe";
    public List<string> TranscriptionLanguages { get; set; } = ["ru", "en"];
    public AnswerStyle AnswerStyle { get; set; } = AnswerStyle.Brief;
    public AnswerLanguage AnswerLanguage { get; set; } = AnswerLanguage.Automatic;
    public int BriefAnswerMaxWords { get; set; } = 60;
    public int DetailedAnswerMaxWords { get; set; } = 160;
    public int AdviceMaxWords { get; set; } = 30;
    public int MaxOutputTokens { get; set; } = 4096;
    public decimal PerCallSpendLimitUsd { get; set; } = 2m;

    [JsonIgnore]
    public int SelectedAnswerMaxWords => AnswerStyle == AnswerStyle.Brief
        ? BriefAnswerMaxWords
        : DetailedAnswerMaxWords;

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ResponsesModelId) ||
            string.IsNullOrWhiteSpace(RealtimeTranscriptionModelId) ||
            string.IsNullOrWhiteSpace(FileTranscriptionModelId))
        {
            throw new InvalidOperationException("Идентификаторы моделей не могут быть пустыми.");
        }

        if (TranscriptionLanguages.Count == 0 ||
            TranscriptionLanguages.Any(string.IsNullOrWhiteSpace))
        {
            throw new InvalidOperationException("Выберите хотя бы один язык распознавания.");
        }

        if (BriefAnswerMaxWords <= 0 || DetailedAnswerMaxWords <= 0 ||
            AdviceMaxWords <= 0 || MaxOutputTokens <= 0 || PerCallSpendLimitUsd <= 0)
        {
            throw new InvalidOperationException("Лимиты должны быть больше нуля.");
        }
    }
}
