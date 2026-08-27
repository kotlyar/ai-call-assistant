import Foundation

protocol FinalAnalysisCredentialProvider: Sendable {
    func currentAPIKey() async throws -> String?
}

struct SecretStoreFinalAnalysisCredentialProvider: FinalAnalysisCredentialProvider {
    let secretStore: any SecretStore

    func currentAPIKey() async throws -> String? {
        try await secretStore.readSecretAsync(for: .openAIAPIKey)
    }
}

protocol FinalAnalysisSpendReserver: Sendable {
    func reserveResponses(
        id: String,
        modelID: String,
        estimatedInputTokens: Int,
        maximumOutputTokens: Int
    ) async throws
}

extension CallSpendLedger: FinalAnalysisSpendReserver {}

enum FinalAnalysisHTTPTransportError: Error, Equatable, Sendable {
    case invalidResponse
    case responseTooLarge
}

protocol FinalAnalysisNetworking: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: FinalAnalysisNetworking {}

struct URLSessionOpenAIFinalAnalysisTransport: OpenAIResponsesFinalAnalysisTransport {
    private let network: any FinalAnalysisNetworking
    private let endpoint: URL
    private let maximumResponseBytes: Int

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        maximumResponseBytes: Int = 2_000_000
    ) {
        network = session
        self.endpoint = endpoint
        self.maximumResponseBytes = maximumResponseBytes
    }

    init(
        network: any FinalAnalysisNetworking,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        maximumResponseBytes: Int = 2_000_000
    ) {
        self.network = network
        self.endpoint = endpoint
        self.maximumResponseBytes = maximumResponseBytes
    }

    func send(
        requestBody: Data,
        idempotencyKey: String,
        apiKey: String
    ) async throws -> OpenAIResponsesFinalAnalysisTransportResponse {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.httpMethod = "POST"
        request.httpBody = requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "X-Client-Request-Id")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (body, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FinalAnalysisHTTPTransportError.invalidResponse
        }
        guard body.count <= maximumResponseBytes else {
            throw FinalAnalysisHTTPTransportError.responseTooLarge
        }
        return OpenAIResponsesFinalAnalysisTransportResponse(
            statusCode: http.statusCode,
            body: body
        )
    }
}

enum FinalAnalysisProductionFactory {
    static func makeCoordinator(
        callFolderURL: URL,
        callID: UUID,
        secretStore: any SecretStore,
        spendLedger: CallSpendLedger,
        maximumInputUTF8Bytes: Int,
        session: URLSession = .shared,
        maximumAttemptsPerTrigger: Int = 2
    ) throws -> FinalAnalysisCoordinator {
        let transport = URLSessionOpenAIFinalAnalysisTransport(session: session)
        let provider = OpenAIResponsesFinalAnalysisProvider(
            transport: transport,
            promptBuilder: FinalAnalysisPromptBuilder(
                maximumInputUTF8Bytes: maximumInputUTF8Bytes
            )
        )
        return FinalAnalysisCoordinator(
            store: try FinalAnalysisStore(
                callFolderURL: callFolderURL,
                callID: callID
            ),
            provider: provider,
            credentialProvider: SecretStoreFinalAnalysisCredentialProvider(
                secretStore: secretStore
            ),
            spendReserver: spendLedger,
            maximumAttemptsPerTrigger: maximumAttemptsPerTrigger
        )
    }
}
