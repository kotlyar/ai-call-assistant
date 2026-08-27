import Foundation

enum OpenAIModelRole: String, Equatable, Sendable {
    case responses
    case realtimeTranscription
    case fileTranscription
}

struct OpenAIModelCatalog: Equatable, Sendable {
    let responsesModelIDs: Set<String>
    let realtimeTranscriptionModelIDs: Set<String>
    let fileTranscriptionModelIDs: Set<String>

    static let current = OpenAIModelCatalog(
        responsesModelIDs: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"],
        realtimeTranscriptionModelIDs: [GuidanceConfigurationDefaults.realtimeTranscriptionModelID],
        fileTranscriptionModelIDs: [GuidanceConfigurationDefaults.fileTranscriptionModelID]
    )

    func supports(_ modelID: String, for role: OpenAIModelRole) -> Bool {
        switch role {
        case .responses:
            return responsesModelIDs.contains(modelID)
        case .realtimeTranscription:
            return realtimeTranscriptionModelIDs.contains(modelID)
        case .fileTranscription:
            return fileTranscriptionModelIDs.contains(modelID)
        }
    }
}

enum GuidanceConfigurationValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedModel(role: OpenAIModelRole, modelID: String)
    case missingTranscriptionLanguage
    case unsupportedTranscriptionLanguage(String)
    case invalidPositiveLimit(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedModel(role, modelID):
            return "Model \(modelID) is not supported for \(role.rawValue)."
        case .missingTranscriptionLanguage:
            return "At least one transcription language is required."
        case let .unsupportedTranscriptionLanguage(language):
            return "Transcription language \(language) is not supported."
        case let .invalidPositiveLimit(field):
            return "\(field) must be greater than zero."
        }
    }
}

struct GuidanceConfiguration: Codable, Equatable, Sendable {
    var responsesModelID: String
    var realtimeTranscriptionModelID: String
    var fileTranscriptionModelID: String
    var transcriptionLanguages: [String]
    var answerStyle: AnswerStyle
    var answerLanguage: AnswerLanguage
    var briefAnswerMaxWords: Int
    var detailedAnswerMaxWords: Int
    var adviceMaxWords: Int
    var maxOutputTokens: Int
    var perCallSpendLimitUSD: Decimal

    init(
        responsesModelID: String = GuidanceConfigurationDefaults.responsesModelID,
        realtimeTranscriptionModelID: String = GuidanceConfigurationDefaults.realtimeTranscriptionModelID,
        fileTranscriptionModelID: String = GuidanceConfigurationDefaults.fileTranscriptionModelID,
        transcriptionLanguages: [String] = GuidanceConfigurationDefaults.transcriptionLanguages,
        answerStyle: AnswerStyle = .brief,
        answerLanguage: AnswerLanguage = .automatic,
        briefAnswerMaxWords: Int = GuidanceConfigurationDefaults.briefAnswerMaxWords,
        detailedAnswerMaxWords: Int = GuidanceConfigurationDefaults.detailedAnswerMaxWords,
        adviceMaxWords: Int = GuidanceConfigurationDefaults.adviceMaxWords,
        maxOutputTokens: Int = GuidanceConfigurationDefaults.maxOutputTokens,
        perCallSpendLimitUSD: Decimal = 2
    ) {
        self.responsesModelID = responsesModelID
        self.realtimeTranscriptionModelID = realtimeTranscriptionModelID
        self.fileTranscriptionModelID = fileTranscriptionModelID
        self.transcriptionLanguages = transcriptionLanguages
        self.answerStyle = answerStyle
        self.answerLanguage = answerLanguage
        self.briefAnswerMaxWords = briefAnswerMaxWords
        self.detailedAnswerMaxWords = detailedAnswerMaxWords
        self.adviceMaxWords = adviceMaxWords
        self.maxOutputTokens = maxOutputTokens
        self.perCallSpendLimitUSD = perCallSpendLimitUSD
    }

    static let `default` = GuidanceConfiguration()

    func validated(using catalog: OpenAIModelCatalog = .current) throws -> GuidanceConfiguration {
        var result = self
        result.responsesModelID = responsesModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.realtimeTranscriptionModelID = realtimeTranscriptionModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        result.fileTranscriptionModelID = fileTranscriptionModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        let models: [(OpenAIModelRole, String)] = [
            (.responses, result.responsesModelID),
            (.realtimeTranscription, result.realtimeTranscriptionModelID),
            (.fileTranscription, result.fileTranscriptionModelID)
        ]
        for (role, modelID) in models where !catalog.supports(modelID, for: role) {
            throw GuidanceConfigurationValidationError.unsupportedModel(
                role: role,
                modelID: modelID
            )
        }

        let normalizedLanguages = transcriptionLanguages.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard !normalizedLanguages.isEmpty else {
            throw GuidanceConfigurationValidationError.missingTranscriptionLanguage
        }

        let supportedLanguages: Set<String> = ["ru", "en"]
        var seenLanguages = Set<String>()
        result.transcriptionLanguages = []
        for language in normalizedLanguages {
            guard supportedLanguages.contains(language) else {
                throw GuidanceConfigurationValidationError.unsupportedTranscriptionLanguage(language)
            }
            if seenLanguages.insert(language).inserted {
                result.transcriptionLanguages.append(language)
            }
        }

        let limits = [
            ("briefAnswerMaxWords", briefAnswerMaxWords),
            ("detailedAnswerMaxWords", detailedAnswerMaxWords),
            ("adviceMaxWords", adviceMaxWords),
            ("maxOutputTokens", maxOutputTokens)
        ]
        for (field, value) in limits where value <= 0 {
            throw GuidanceConfigurationValidationError.invalidPositiveLimit(field)
        }
        guard perCallSpendLimitUSD > 0 else {
            throw GuidanceConfigurationValidationError.invalidPositiveLimit("perCallSpendLimitUSD")
        }

        return result
    }
}
