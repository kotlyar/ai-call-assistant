import Foundation

protocol OpenAIResponsesGuidanceTransport: Sendable {
    func send(requestBody: Data) async throws -> OpenAIResponsesTransportResponse
}

struct OpenAIResponsesTransportResponse: Equatable, Sendable {
    let statusCode: Int
    let body: Data
}

struct OpenAIResponsesGuidanceClient: Sendable {
    private let transport: any OpenAIResponsesGuidanceTransport
    private let promptBuilder: GuidancePromptBuilder
    private let responseValidator: GuidanceResponseValidator

    init(
        transport: any OpenAIResponsesGuidanceTransport,
        promptBuilder: GuidancePromptBuilder = GuidancePromptBuilder(),
        responseValidator: GuidanceResponseValidator = GuidanceResponseValidator()
    ) {
        self.transport = transport
        self.promptBuilder = promptBuilder
        self.responseValidator = responseValidator
    }

    func analyze(snapshot: ConversationSnapshot) async throws -> ValidatedGuidancePage {
        let request = try promptBuilder.makeRequest(for: snapshot)
        let requestBody = try OpenAIResponsesRequestEncoding.encode(request)
        let transportResponse = try await transport.send(requestBody: requestBody)

        if let providerError = try? JSONDecoder().decode(
            OpenAIProviderErrorEnvelope.self,
            from: transportResponse.body
        ), providerError.error != nil {
            let error = providerError.error!
            if Self.isContextLimitCode(error.code) || Self.isContextLimitCode(error.type) {
                throw OpenAIResponsesGuidanceClientError.contextLimitReached
            }
            guard (200..<300).contains(transportResponse.statusCode) else {
                throw OpenAIResponsesGuidanceClientError.providerError(
                    statusCode: transportResponse.statusCode,
                    code: error.code ?? error.type
                )
            }
        }

        guard (200..<300).contains(transportResponse.statusCode) else {
            throw OpenAIResponsesGuidanceClientError.providerError(
                statusCode: transportResponse.statusCode,
                code: nil
            )
        }

        let envelope: OpenAIResponsesEnvelope
        do {
            envelope = try JSONDecoder().decode(
                OpenAIResponsesEnvelope.self,
                from: transportResponse.body
            )
        } catch {
            throw OpenAIResponsesGuidanceClientError.malformedResponse
        }

        if envelope.status == "incomplete" {
            let reason = envelope.incompleteDetails?.reason
            if Self.isContextLimitCode(reason) {
                throw OpenAIResponsesGuidanceClientError.contextLimitReached
            }
            throw OpenAIResponsesGuidanceClientError.incomplete(reason: reason)
        }
        guard envelope.status == "completed" else {
            throw OpenAIResponsesGuidanceClientError.incomplete(reason: envelope.status)
        }

        let contentItems = envelope.output.flatMap { $0.content ?? [] }
        if contentItems.contains(where: { $0.type == "refusal" || $0.refusal != nil }) {
            throw OpenAIResponsesGuidanceClientError.refusal
        }

        guard let outputText = contentItems
            .first(where: { $0.type == "output_text" })?
            .text,
            let pageData = outputText.data(using: .utf8)
        else {
            throw OpenAIResponsesGuidanceClientError.malformedResponse
        }

        let page: GuidanceResponsePage
        do {
            page = try JSONDecoder().decode(GuidanceResponsePage.self, from: pageData)
        } catch {
            throw OpenAIResponsesGuidanceClientError.invalidStructuredOutput
        }

        do {
            return try responseValidator.validate(page, against: snapshot)
        } catch let error as GuidanceResponseValidationError {
            throw OpenAIResponsesGuidanceClientError.validationFailed(error)
        }
    }

    private static func isContextLimitCode(_ code: String?) -> Bool {
        guard let code else { return false }
        return code == "context_length_exceeded" || code == "context_window_exceeded"
    }
}

enum OpenAIResponsesGuidanceClientError: Error, Equatable, Sendable {
    case contextLimitReached
    case providerError(statusCode: Int, code: String?)
    case incomplete(reason: String?)
    case refusal
    case malformedResponse
    case invalidStructuredOutput
    case validationFailed(GuidanceResponseValidationError)

    var isTerminal: Bool {
        if case .contextLimitReached = self {
            return true
        }
        return false
    }
}

private struct OpenAIProviderErrorEnvelope: Decodable {
    struct ProviderError: Decodable {
        let code: String?
        let type: String?
    }

    let error: ProviderError?
}

private struct OpenAIResponsesEnvelope: Decodable {
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
