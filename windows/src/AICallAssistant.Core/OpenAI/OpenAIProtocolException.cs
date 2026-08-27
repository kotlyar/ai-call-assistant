namespace AICallAssistant.Core.OpenAI;

public sealed class OpenAIProtocolException : Exception
{
    public OpenAIProtocolException(string message, int? statusCode = null, string? code = null)
        : base(message)
    {
        StatusCode = statusCode;
        Code = code;
    }

    public int? StatusCode { get; }
    public string? Code { get; }
}
