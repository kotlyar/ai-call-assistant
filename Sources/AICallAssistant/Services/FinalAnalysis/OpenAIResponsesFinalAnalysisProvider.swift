import Foundation

protocol OpenAIResponsesFinalAnalysisTransport: Sendable {
    /// `idempotencyKey` is a stable client correlation key. The durable store
    /// does not assume the remote endpoint provides exactly-once execution.
    func send(
        requestBody: Data,
        idempotencyKey: String,
        apiKey: String
    ) async throws -> OpenAIResponsesFinalAnalysisTransportResponse
}

struct OpenAIResponsesFinalAnalysisTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let body: Data
}

struct OpenAIResponsesFinalAnalysisProvider: FinalAnalysisProvider, Sendable {
    private let transport: any OpenAIResponsesFinalAnalysisTransport
    private let promptBuilder: FinalAnalysisPromptBuilder
    private let validator: FinalAnalysisResponseValidator

    init(
        transport: any OpenAIResponsesFinalAnalysisTransport,
        promptBuilder: FinalAnalysisPromptBuilder,
        validator: FinalAnalysisResponseValidator = FinalAnalysisResponseValidator()
    ) {
        self.transport = transport
        self.promptBuilder = promptBuilder
        self.validator = validator
    }

    func analyze(
        request: FinalAnalysisProviderRequest
    ) async throws -> FinalAnalysisTriggerResult {
        let apiRequest: OpenAIResponsesGuidanceRequest
        do {
            apiRequest = try promptBuilder.makeRequest(for: request)
        } catch let error as FinalAnalysisPromptBuilderError {
            if case .contextLimitExceeded = error {
                throw FinalAnalysisProviderError.contextLimitExceeded
            }
            throw FinalAnalysisProviderError.invalidRequest
        }

        let response = try await transport.send(
            requestBody: OpenAIResponsesRequestEncoding.encode(apiRequest),
            idempotencyKey: request.idempotencyKey,
            apiKey: request.apiKey
        )

        if let providerError = try? JSONDecoder().decode(
            FinalOpenAIProviderErrorEnvelope.self,
            from: response.body
        ), let error = providerError.error {
            if Self.isContextLimitCode(error.code)
                || Self.isContextLimitCode(error.type) {
                throw FinalAnalysisProviderError.contextLimitExceeded
            }
            guard (200..<300).contains(response.statusCode) else {
                throw FinalAnalysisProviderError.providerError(
                    statusCode: response.statusCode,
                    code: error.code ?? error.type
                )
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FinalAnalysisProviderError.providerError(
                statusCode: response.statusCode,
                code: nil
            )
        }

        let envelope: FinalOpenAIResponsesEnvelope
        do {
            envelope = try JSONDecoder().decode(
                FinalOpenAIResponsesEnvelope.self,
                from: response.body
            )
        } catch {
            throw FinalAnalysisProviderError.malformedResponse
        }
        if envelope.status == "incomplete" {
            let reason = envelope.incompleteDetails?.reason
            if Self.isContextLimitCode(reason) {
                throw FinalAnalysisProviderError.contextLimitExceeded
            }
            throw FinalAnalysisProviderError.incomplete(reason: reason)
        }
        guard envelope.status == "completed" else {
            throw FinalAnalysisProviderError.incomplete(reason: envelope.status)
        }

        let content = envelope.output.flatMap { $0.content ?? [] }
        if content.contains(where: { $0.type == "refusal" || $0.refusal != nil }) {
            throw FinalAnalysisProviderError.refusal
        }
        guard let outputText = content.first(where: { $0.type == "output_text" })?.text,
              let data = outputText.data(using: .utf8) else {
            throw FinalAnalysisProviderError.malformedResponse
        }

        let page: FinalAnalysisResponsePage
        do {
            page = try JSONDecoder().decode(FinalAnalysisResponsePage.self, from: data)
        } catch {
            throw FinalAnalysisProviderError.invalidStructuredOutput
        }
        do {
            return try validator.validate(page, request: request)
        } catch let error as FinalAnalysisResponseValidationError {
            throw FinalAnalysisProviderError.validationFailed(error)
        }
    }

    private static func isContextLimitCode(_ code: String?) -> Bool {
        guard let code else { return false }
        return code == "context_length_exceeded"
            || code == "context_window_exceeded"
    }
}

private struct FinalOpenAIProviderErrorEnvelope: Decodable {
    struct ProviderError: Decodable {
        let code: String?
        let type: String?
    }

    let error: ProviderError?
}

private struct FinalOpenAIResponsesEnvelope: Decodable {
    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct OutputItem: Decodable {
        struct ContentItem: Decodable {
            let type: String
            let text: String?
            let refusal: String?
        }

        let content: [ContentItem]?
    }

    let status: String?
    let incompleteDetails: IncompleteDetails?
    let output: [OutputItem]

    private enum CodingKeys: String, CodingKey {
        case status
        case incompleteDetails = "incomplete_details"
        case output
    }
}
