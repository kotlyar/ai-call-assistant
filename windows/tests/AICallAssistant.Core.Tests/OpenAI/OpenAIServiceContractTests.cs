using System.Net;
using System.Text;
using System.Text.Json;
using AICallAssistant.Core.Models;
using AICallAssistant.Core.OpenAI;

namespace AICallAssistant.Core.Tests.OpenAI;

public sealed class OpenAIServiceContractTests
{
    [Fact]
    public async Task TestConnectionSendsTrimmedBearerAuthorizationWithoutExposingIt()
    {
        const string apiKey = "sk-contract-test-only";
        using var handler = new CapturingHttpMessageHandler(
            apiKey,
            static () => JsonResponse(HttpStatusCode.OK, "{}"));
        using var httpClient = new HttpClient(handler);
        var service = new OpenAIService(
            httpClient,
            new Uri("https://openai.invalid/v1/"));

        await service.TestConnectionAsync($"  {apiKey}  ");

        Assert.Equal(HttpMethod.Get, handler.Method);
        Assert.Equal("/v1/models", handler.RequestUri?.AbsolutePath);
        Assert.True(handler.AuthorizationMatched, "Expected a trimmed Bearer credential.");
        Assert.Null(handler.Body);
    }

    [Fact]
    public async Task GuidanceRequestContainsFullSnapshotAndParsesStructuredOutputText()
    {
        const string apiKey = "sk-guidance-contract-only";
        const string firstTurnText = "Полная ранняя реплика — не сокращать: alpha beta gamma.";
        const string triggerText = "Какой полный ответ вы рекомендуете по этому контексту?";
        using var handler = new CapturingHttpMessageHandler(
            apiKey,
            static () => JsonResponse(
                HttpStatusCode.OK,
                """
                {
                  "status": "completed",
                  "output": [
                    {
                      "type": "message",
                      "content": [
                        {
                          "type": "output_text",
                          "text": "{\"hasQuestion\":true,\"question\":\"  Какой ответ?  \",\"answer\":\"  Используйте полный контекст.  \",\"advice\":\"  Ответьте конкретно.  \",\"evidence\":\"  Вопрос задан явно.  \"}"
                        }
                      ]
                    }
                  ]
                }
                """));
        using var httpClient = new HttpClient(handler);
        var service = new OpenAIService(
            httpClient,
            new Uri("https://openai.invalid/v1/"));
        var earlyTurn = new TranscriptTurn
        {
            Id = Guid.Parse("10000000-0000-0000-0000-000000000001"),
            Speaker = TranscriptSpeaker.You,
            Offset = TimeSpan.FromSeconds(2),
            Text = firstTurnText
        };
        var trigger = new TranscriptTurn
        {
            Id = Guid.Parse("10000000-0000-0000-0000-000000000002"),
            Speaker = TranscriptSpeaker.Participant,
            Offset = TimeSpan.FromSeconds(5),
            Text = triggerText
        };
        var selectedContext = new CallContext
        {
            Id = Guid.Parse("20000000-0000-0000-0000-000000000001"),
            Title = "Полный контекст вакансии",
            Body = "Первая строка контекста\nВторая строка без сокращений.",
            IsSelected = true,
            Attachments =
            [
                new ContextFileAttachment
                {
                    FileName = "requirements.txt",
                    ExtractedText = "Вложение целиком: опыт, метрики, ограничения."
                }
            ]
        };
        var unselectedContext = new CallContext
        {
            Id = Guid.Parse("20000000-0000-0000-0000-000000000002"),
            Title = "Не выбран",
            Body = "Не должен попадать в запрос.",
            IsSelected = false
        };
        var settings = new AppSettings
        {
            AnswerStyle = AnswerStyle.Detailed,
            AnswerLanguage = AnswerLanguage.Russian,
            DetailedAnswerMaxWords = 175,
            AdviceMaxWords = 28
        };

        var guidance = await service.CreateGuidanceAsync(
            apiKey,
            [trigger, earlyTurn],
            [unselectedContext, selectedContext],
            trigger,
            settings);

        Assert.Equal(HttpMethod.Post, handler.Method);
        Assert.Equal("/v1/responses", handler.RequestUri?.AbsolutePath);
        Assert.Equal("application/json", handler.ContentType);
        Assert.True(handler.AuthorizationMatched, "Expected a Bearer credential.");
        Assert.True(handler.CacheControlNoStore);

        using var request = JsonDocument.Parse(Assert.IsType<string>(handler.Body));
        var root = request.RootElement;
        Assert.False(root.GetProperty("store").GetBoolean());
        Assert.Equal(settings.ResponsesModelId, root.GetProperty("model").GetString());

        var format = root.GetProperty("text").GetProperty("format");
        Assert.Equal("json_schema", format.GetProperty("type").GetString());
        Assert.Equal("call_guidance_v1", format.GetProperty("name").GetString());
        Assert.True(format.GetProperty("strict").GetBoolean());
        Assert.True(
            format.GetProperty("schema")
                .GetProperty("properties")
                .TryGetProperty("hasQuestion", out _));

        var input = root.GetProperty("input");
        Assert.Equal("developer", input[0].GetProperty("role").GetString());
        Assert.Equal("user", input[1].GetProperty("role").GetString());
        using var payload = JsonDocument.Parse(
            Assert.IsType<string>(input[1].GetProperty("content").GetString()));
        var payloadRoot = payload.RootElement;
        Assert.Equal(trigger.Id, payloadRoot.GetProperty("triggerTurnId").GetGuid());
        Assert.Equal(
            new[] { firstTurnText, triggerText },
            payloadRoot.GetProperty("turns")
                .EnumerateArray()
                .Select(static turn => turn.GetProperty("text").GetString()));

        var context = Assert.Single(payloadRoot.GetProperty("contexts").EnumerateArray());
        Assert.Equal(selectedContext.Id, context.GetProperty("contextId").GetGuid());
        Assert.Equal(selectedContext.Title, context.GetProperty("title").GetString());
        Assert.Equal(selectedContext.AssistantBody, context.GetProperty("body").GetString());

        Assert.NotNull(guidance);
        Assert.Equal("Какой ответ?", guidance.Question);
        Assert.Equal("Используйте полный контекст.", guidance.Answer);
        Assert.Equal("Ответьте конкретно.", guidance.Advice);
        Assert.Equal("Вопрос задан явно.", guidance.Evidence);
    }

    [Fact]
    public async Task UnauthorizedResponseIsClassifiedWithoutProviderBodyOrCredentialInException()
    {
        const string apiKey = "sk-must-not-appear-in-exception";
        const string providerMarker = "provider-private-diagnostic-marker";
        using var handler = new CapturingHttpMessageHandler(
            apiKey,
            static () => JsonResponse(
                HttpStatusCode.Unauthorized,
                $$"""
                {
                  "error": {
                    "code": "invalid_api_key",
                    "message": "{{providerMarker}}: {{apiKey}}"
                  }
                }
                """));
        using var httpClient = new HttpClient(handler);
        var service = new OpenAIService(
            httpClient,
            new Uri("https://openai.invalid/v1/"));

        var exception = await Assert.ThrowsAsync<OpenAIProtocolException>(
            () => service.TestConnectionAsync(apiKey));

        Assert.True(handler.AuthorizationMatched, "Expected a Bearer credential.");
        Assert.Equal(401, exception.StatusCode);
        Assert.Equal("invalid_api_key", exception.Code);
        Assert.Contains("HTTP 401", exception.Message, StringComparison.Ordinal);
        var diagnosticText = exception.ToString();
        Assert.DoesNotContain(apiKey, diagnosticText, StringComparison.Ordinal);
        Assert.DoesNotContain(providerMarker, diagnosticText, StringComparison.Ordinal);
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode statusCode, string body) => new(statusCode)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json")
    };

    private sealed class CapturingHttpMessageHandler : HttpMessageHandler
    {
        private readonly string _expectedApiKey;
        private readonly Func<HttpResponseMessage> _responseFactory;

        public CapturingHttpMessageHandler(
            string expectedApiKey,
            Func<HttpResponseMessage> responseFactory)
        {
            _expectedApiKey = expectedApiKey;
            _responseFactory = responseFactory;
        }

        public HttpMethod? Method { get; private set; }

        public Uri? RequestUri { get; private set; }

        public string? ContentType { get; private set; }

        public string? Body { get; private set; }

        public bool AuthorizationMatched { get; private set; }

        public bool CacheControlNoStore { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Method = request.Method;
            RequestUri = request.RequestUri;
            ContentType = request.Content?.Headers.ContentType?.MediaType;
            Body = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            AuthorizationMatched =
                string.Equals(request.Headers.Authorization?.Scheme, "Bearer", StringComparison.Ordinal) &&
                string.Equals(
                    request.Headers.Authorization?.Parameter,
                    _expectedApiKey,
                    StringComparison.Ordinal);
            CacheControlNoStore = request.Headers.CacheControl?.NoStore == true;
            return _responseFactory();
        }
    }
}
