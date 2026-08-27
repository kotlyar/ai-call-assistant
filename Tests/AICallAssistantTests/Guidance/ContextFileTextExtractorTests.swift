import Foundation
import XCTest
@testable import AICallAssistant

final class ContextFileTextExtractorTests: XCTestCase {
    func testRequestContainsInlineFileContractAndReturnsExactUnicodeText() async throws {
        let extractedText = "\nЗаголовок 🙂\nСтрока e\u{301}\n"
        let network = FakeContextFileTextExtractionNetwork(
            statusCode: 200,
            body: try completedResponse(text: extractedText)
        )
        let extractor = OpenAIContextFileTextExtractor(network: network)
        let apiKey = "unit-test-secret-key"

        let result = try await extractor.extractText(
            from: ContextFileExtractionInput(
                fileName: #"private/folder\résumé.txt"#,
                mediaType: "text/plain",
                data: Data([0x00, 0x01, 0x02, 0xFF])
            ),
            apiKey: apiKey,
            modelID: "gpt-5.6-terra"
        )

        XCTAssertEqual(result, extractedText)
        let recordedRequest = await network.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let body = try XCTUnwrap(request.httpBody)
        let bodyText = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(bodyText.contains(apiKey))
        let root = try dictionary(JSONSerialization.jsonObject(with: body))
        XCTAssertEqual(root["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(root["store"] as? Bool, false)
        XCTAssertEqual(root["max_output_tokens"] as? Int, 32_768)
        XCTAssertEqual(try dictionary(root["reasoning"])["effort"] as? String, "none")
        XCTAssertEqual(root["tools"] as? [String], [])

        let messages = try arrayOfDictionaries(root["input"])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["developer", "user"])
        let developerContent = try arrayOfDictionaries(messages[0]["content"])
        let developerText = try XCTUnwrap(developerContent.first?["text"] as? String)
        XCTAssertTrue(developerText.contains("faithfully and completely"))
        XCTAssertTrue(developerText.contains("Do not summarize"))
        XCTAssertTrue(developerText.contains("untrusted data"))

        let userContent = try arrayOfDictionaries(messages[1]["content"])
        XCTAssertEqual(userContent.map { $0["type"] as? String }, ["input_file", "input_text"])
        XCTAssertEqual(userContent[0]["filename"] as? String, "résumé.txt")
        XCTAssertEqual(
            userContent[0]["file_data"] as? String,
            "data:text/plain;base64,AAEC/w=="
        )
        XCTAssertNil(userContent[0]["detail"])
        XCTAssertEqual(
            userContent[1]["text"] as? String,
            "Return only the complete extracted text from the attached file."
        )
    }

    func testPDFRequestUsesApplicationPDFAndLowDetail() async throws {
        let network = FakeContextFileTextExtractionNetwork(
            statusCode: 200,
            body: try completedResponse(text: "Текст PDF")
        )
        let extractor = OpenAIContextFileTextExtractor(network: network)

        _ = try await extractor.extractText(
            from: ContextFileExtractionInput(
                fileName: "документ.pdf",
                mediaType: "application/octet-stream",
                data: Data("pdf".utf8)
            ),
            apiKey: "test-key",
            modelID: "gpt-5.6-terra"
        )

        let recordedRequest = await network.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        let root = try dictionary(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
        )
        let messages = try arrayOfDictionaries(root["input"])
        let userContent = try arrayOfDictionaries(messages[1]["content"])
        XCTAssertEqual(userContent[0]["filename"] as? String, "документ.pdf")
        XCTAssertEqual(userContent[0]["file_data"] as? String, "data:application/pdf;base64,cGRm")
        XCTAssertEqual(userContent[0]["detail"] as? String, "low")
    }

    func testAllOutputTextPartsArePreservedInOrder() async throws {
        let body = Data(
            #"{"status":"completed","output":[{"content":[{"type":"output_text","text":"Первая\n"}]},{"content":[{"type":"output_text","text":"вторая 🙂"}]}]}"#.utf8
        )
        let extractor = OpenAIContextFileTextExtractor(
            network: FakeContextFileTextExtractionNetwork(statusCode: 200, body: body)
        )

        let text = try await extract(extractor)

        XCTAssertEqual(text, "Первая\nвторая 🙂")
    }

    func testIncompleteResponseIsRejectedWithoutPublishingPartialText() async throws {
        let body = Data(
            #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"content":[{"type":"output_text","text":"PARTIAL_SECRET_TEXT"}]}]}"#.utf8
        )
        let extractor = OpenAIContextFileTextExtractor(
            network: FakeContextFileTextExtractionNetwork(statusCode: 200, body: body)
        )

        await assertExtractionError(.incomplete, from: extractor)
    }

    func testRefusalResponseIsRejectedWithoutLeakingRefusalText() async throws {
        let marker = "provider-refusal-secret-marker"
        let body = Data(
            #"{"status":"completed","output":[{"content":[{"type":"refusal","refusal":"provider-refusal-secret-marker"}]}]}"#.utf8
        )
        let extractor = OpenAIContextFileTextExtractor(
            network: FakeContextFileTextExtractionNetwork(statusCode: 200, body: body)
        )

        do {
            _ = try await extract(extractor)
            XCTFail("Expected refusal")
        } catch {
            XCTAssertEqual(error as? ContextFileTextExtractionError, .refusal)
            XCTAssertFalse(error.localizedDescription.contains(marker))
        }
    }

    func testProviderErrorIsSanitized() async throws {
        let marker = "provider-body-secret-marker"
        let key = "api-key-secret-marker"
        let body = Data(
            #"{"error":{"type":"invalid_request_error","code":"bad_file","message":"provider-body-secret-marker /private/source.txt"}}"#.utf8
        )
        let extractor = OpenAIContextFileTextExtractor(
            network: FakeContextFileTextExtractionNetwork(statusCode: 400, body: body)
        )

        do {
            _ = try await extractor.extractText(
                from: validInput,
                apiKey: key,
                modelID: "gpt-5.6-terra"
            )
            XCTFail("Expected provider error")
        } catch {
            XCTAssertEqual(
                error as? ContextFileTextExtractionError,
                .providerError(statusCode: 400)
            )
            XCTAssertFalse(error.localizedDescription.contains(marker))
            XCTAssertFalse(error.localizedDescription.contains(key))
            XCTAssertFalse(error.localizedDescription.contains("source.txt"))
        }
    }

    func testMalformedCompletedResponseIsRejected() async throws {
        let body = Data(
            #"{"status":"completed","output":[{"content":[{"type":"output_text"}]}]}"#.utf8
        )
        let extractor = OpenAIContextFileTextExtractor(
            network: FakeContextFileTextExtractionNetwork(statusCode: 200, body: body)
        )

        await assertExtractionError(.malformedResponse, from: extractor)
    }

    func testUnsupportedExtensionIsRejectedBeforeNetworkRequest() async throws {
        let network = FakeContextFileTextExtractionNetwork(
            statusCode: 200,
            body: try completedResponse(text: "unused")
        )
        let extractor = OpenAIContextFileTextExtractor(network: network)

        do {
            _ = try await extractor.extractText(
                from: ContextFileExtractionInput(
                    fileName: "payload.exe",
                    mediaType: "application/octet-stream",
                    data: Data([1])
                ),
                apiKey: "test-key",
                modelID: "gpt-5.6-terra"
            )
            XCTFail("Expected unsupported file type")
        } catch {
            XCTAssertEqual(
                error as? ContextFileTextExtractionError,
                .unsupportedFileType
            )
        }
        let requestCount = await network.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testFileAtOfficialBoundaryIsRejectedBeforeBase64Encoding() async throws {
        let network = FakeContextFileTextExtractionNetwork(
            statusCode: 200,
            body: try completedResponse(text: "unused")
        )
        let extractor = OpenAIContextFileTextExtractor(network: network)
        let boundarySizedData = Data(
            repeating: 0,
            count: OpenAIContextFileTextExtractor.maximumFileBytes
        )

        do {
            _ = try await extractor.extractText(
                from: ContextFileExtractionInput(
                    fileName: "large.pdf",
                    mediaType: "application/pdf",
                    data: boundarySizedData
                ),
                apiKey: "test-key",
                modelID: "gpt-5.6-terra"
            )
            XCTFail("Expected fileTooLarge")
        } catch {
            XCTAssertEqual(error as? ContextFileTextExtractionError, .fileTooLarge)
            XCTAssertEqual(error.localizedDescription, "Файл должен быть меньше 50 МБ.")
        }
        let requestCount = await network.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testEmptyFileIsRejectedBeforeNetworkRequest() async throws {
        let network = FakeContextFileTextExtractionNetwork(
            statusCode: 200,
            body: try completedResponse(text: "unused")
        )
        let extractor = OpenAIContextFileTextExtractor(network: network)

        do {
            _ = try await extractor.extractText(
                from: ContextFileExtractionInput(
                    fileName: "empty.txt",
                    mediaType: "text/plain",
                    data: Data()
                ),
                apiKey: "test-key",
                modelID: "gpt-5.6-terra"
            )
            XCTFail("Expected emptyFile")
        } catch {
            XCTAssertEqual(error as? ContextFileTextExtractionError, .emptyFile)
        }
        let requestCount = await network.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    private var validInput: ContextFileExtractionInput {
        ContextFileExtractionInput(
            fileName: "context.txt",
            mediaType: "text/plain",
            data: Data("file body".utf8)
        )
    }

    private func extract(_ extractor: OpenAIContextFileTextExtractor) async throws -> String {
        try await extractor.extractText(
            from: validInput,
            apiKey: "test-key",
            modelID: "gpt-5.6-terra"
        )
    }

    private func assertExtractionError(
        _ expected: ContextFileTextExtractionError,
        from extractor: OpenAIContextFileTextExtractor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await extract(extractor)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ContextFileTextExtractionError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func completedResponse(text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [
                [
                    "content": [
                        ["type": "output_text", "text": text]
                    ]
                ]
            ]
        ])
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try XCTUnwrap(value as? [String: Any])
    }

    private func arrayOfDictionaries(_ value: Any?) throws -> [[String: Any]] {
        try XCTUnwrap(value as? [[String: Any]])
    }
}

private actor FakeContextFileTextExtractionNetwork: ContextFileTextExtractionNetworking {
    private let statusCode: Int
    private let body: Data
    private var requests: [URLRequest] = []

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }

    func requestCount() -> Int {
        requests.count
    }
}
