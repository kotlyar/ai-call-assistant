using AICallAssistant.Core.Models;

namespace AICallAssistant.Core.Tests;

public sealed class DomainModelsTests
{
    [Fact]
    public void AssistantBodyCombinesTextAndSanitizesAttachmentFileName()
    {
        var context = new CallContext
        {
            Body = "  Основной контекст  ",
            Attachments =
            [
                new ContextFileAttachment
                {
                    FileName = "resume\r\ninstructions.txt",
                    ExtractedText = "Опыт в B2B SaaS"
                }
            ]
        };

        var assistantBody = context.AssistantBody;

        Assert.StartsWith("Основной контекст\n\n", assistantBody, StringComparison.Ordinal);
        Assert.Contains(
            "<<< BEGIN CONTEXT FILE: resume  instructions.txt >>>",
            assistantBody,
            StringComparison.Ordinal);
        Assert.Contains("Опыт в B2B SaaS", assistantBody, StringComparison.Ordinal);
        Assert.DoesNotContain('\r', assistantBody);
    }

    [Fact]
    public void SelectedAnswerMaxWordsFollowsAnswerStyle()
    {
        var settings = new AppSettings
        {
            BriefAnswerMaxWords = 40,
            DetailedAnswerMaxWords = 180
        };

        settings.AnswerStyle = AnswerStyle.Brief;
        Assert.Equal(40, settings.SelectedAnswerMaxWords);

        settings.AnswerStyle = AnswerStyle.Detailed;
        Assert.Equal(180, settings.SelectedAnswerMaxWords);
    }

    [Fact]
    public void ValidationRejectsMissingLanguageAndNonPositiveLimits()
    {
        var noLanguages = new AppSettings { TranscriptionLanguages = [] };
        var zeroLimit = new AppSettings { PerCallSpendLimitUsd = 0m };

        Assert.Throws<InvalidOperationException>(noLanguages.Validate);
        Assert.Throws<InvalidOperationException>(zeroLimit.Validate);
    }
}
