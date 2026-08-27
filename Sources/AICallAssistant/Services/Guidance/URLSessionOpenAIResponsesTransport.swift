import Foundation

enum OpenAIHTTPTransportError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OpenAI API вернул некорректный HTTP-ответ."
        case .responseTooLarge:
            return "Ответ OpenAI API превысил допустимый размер."
        }
    }
}

actor URLSessionOpenAIResponsesTransport: OpenAIResponsesGuidanceTransport {
    private let apiKey: String
    private let session: URLSession
    private let endpoint: URL
    private let maximumResponseBytes: Int

    init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        maximumResponseBytes: Int = 2_000_000
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
        self.maximumResponseBytes = maximumResponseBytes
    }

    func send(requestBody: Data) async throws -> OpenAIResponsesTransportResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIHTTPTransportError.invalidResponse
        }
        guard body.count <= maximumResponseBytes else {
            throw OpenAIHTTPTransportError.responseTooLarge
        }
        return OpenAIResponsesTransportResponse(statusCode: http.statusCode, body: body)
    }
}

struct OpenAIResponsesLiveGuidanceProvider: LiveGuidanceProvider {
    private let client: OpenAIResponsesGuidanceClient

    init(apiKey: String) {
        client = OpenAIResponsesGuidanceClient(
            transport: URLSessionOpenAIResponsesTransport(apiKey: apiKey)
        )
    }

    init(client: OpenAIResponsesGuidanceClient) {
        self.client = client
    }

    func analyze(snapshot: ConversationSnapshot) async throws -> LiveGuidanceProviderResult {
        let page = try await client.analyze(snapshot: snapshot)
        return LiveGuidanceProviderResult(questionAnswers: page.questionAnswers)
    }
}

struct OpenAIConnectionTester: Sendable {
    private let session: URLSession
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/models")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    func test(apiKey: String) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIHTTPTransportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAIResponsesGuidanceClientError.providerError(
                statusCode: http.statusCode,
                code: nil
            )
        }
    }
}
