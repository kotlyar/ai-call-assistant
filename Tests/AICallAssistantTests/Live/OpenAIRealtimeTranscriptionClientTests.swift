import Foundation
import XCTest
@testable import AICallAssistant

final class OpenAIRealtimeTranscriptionClientTests: XCTestCase {
    func testConnectSendsSessionUpdateThenPublishesEvents() async throws {
        let transport = FakeRealtimeTransport()
        await transport.enqueue(
            Data(#"{"type":"session.updated","session":{"expires_at":123}}"#.utf8)
        )
        await transport.enqueue(
            Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","content_index":0,"transcript":"Hello"}"#.utf8)
        )
        let client = OpenAIRealtimeTranscriptionClient(transport: transport)

        let connection = try await client.connect(
            apiKey: "test-key-not-a-secret",
            configuration: RealtimeTranscriptionConfiguration()
        )

        var iterator = client.signals.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        XCTAssertEqual(connection, RealtimeClientConnection(id: 1, expiresAt: 123))
        XCTAssertEqual(
            first,
            .server(connectionID: 1, .sessionUpdated(expiresAt: 123))
        )
        XCTAssertEqual(
            second,
            .server(
                connectionID: 1,
                .transcriptCompleted(itemID: "item_1", contentIndex: 0, transcript: "Hello")
            )
        )
        let state = await client.state
        let connectedModel = await transport.connectedModel
        let sentPayloadCount = await transport.sentPayloads.count
        XCTAssertEqual(state, .ready(expiresAt: 123))
        XCTAssertEqual(connectedModel, "gpt-live-transcribe")
        XCTAssertEqual(sentPayloadCount, 1)
    }

    func testAppendAndCommitAreSerialized() async throws {
        let transport = FakeRealtimeTransport()
        await transport.enqueue(
            Data(#"{"type":"session.updated","session":{"expires_at":123}}"#.utf8)
        )
        let client = OpenAIRealtimeTranscriptionClient(transport: transport)
        _ = try await client.connect(
            apiKey: "test-key-not-a-secret",
            configuration: RealtimeTranscriptionConfiguration()
        )

        try await client.appendPCM16(Data([1, 2]))
        try await client.commit(eventID: "outgoing:0:abc")

        let payloads = await transport.sentPayloads
        XCTAssertEqual(payloads.count, 3)
        let append = try jsonObject(payloads[1])
        let commit = try jsonObject(payloads[2])
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(append["audio"] as? String, "AQI=")
        XCTAssertEqual(commit["type"] as? String, "input_audio_buffer.commit")
        XCTAssertEqual(commit["event_id"] as? String, "outgoing:0:abc")
    }

    func testHandshakeAuthorizationFailureIsTypedAndTerminal() async throws {
        let transport = FakeRealtimeTransport()
        await transport.fail(
            RealtimeTransportError.httpStatus(401, retryAfterSeconds: nil)
        )
        let client = OpenAIRealtimeTranscriptionClient(transport: transport)

        do {
            _ = try await client.connect(
                apiKey: "test-key-not-a-secret",
                configuration: RealtimeTranscriptionConfiguration()
            )
            XCTFail("Expected authentication failure")
        } catch let RealtimeClientError.connectionFailed(failure) {
            XCTAssertEqual(failure.reason, .authentication)
            XCTAssertTrue(failure.isTerminal)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHandshakeForbiddenFailureIsTypedAndTerminal() async throws {
        let transport = FakeRealtimeTransport()
        await transport.fail(
            RealtimeTransportError.httpStatus(403, retryAfterSeconds: nil)
        )
        let client = OpenAIRealtimeTranscriptionClient(transport: transport)

        do {
            _ = try await client.connect(
                apiKey: "test-key-not-a-secret",
                configuration: RealtimeTranscriptionConfiguration()
            )
            XCTFail("Expected forbidden failure")
        } catch let RealtimeClientError.connectionFailed(failure) {
            XCTAssertEqual(failure.reason, .forbidden)
            XCTAssertTrue(failure.isTerminal)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProviderQuotaFailureIsSanitizedAndTerminal() async throws {
        let transport = FakeRealtimeTransport()
        await transport.enqueue(
            Data(#"{"type":"error","error":{"type":"requests","code":"insufficient_quota","message":"sensitive provider detail"}}"#.utf8)
        )
        let client = OpenAIRealtimeTranscriptionClient(transport: transport)

        do {
            _ = try await client.connect(
                apiKey: "test-key-not-a-secret",
                configuration: RealtimeTranscriptionConfiguration()
            )
            XCTFail("Expected quota failure")
        } catch let RealtimeClientError.connectionFailed(failure) {
            XCTAssertEqual(failure.reason, .quotaExceeded)
            XCTAssertEqual(failure.code, "insufficient_quota")
            XCTAssertEqual(failure.httpStatus, 429)
            XCTAssertTrue(failure.isTerminal)
            XCTAssertEqual(
                failure.diagnostic,
                RealtimeFailureDiagnostic(
                    code: "insufficient_quota",
                    reason: .quotaExceeded,
                    httpStatus: 429
                )
            )
        } catch {
            XCTFail("Unexpected unsanitized failure type")
        }
    }

    func testHandshakeRateLimitPreservesStatusAndRetryAfter() async throws {
        let transport = FakeRealtimeTransport()
        await transport.fail(
            RealtimeTransportError.httpStatus(429, retryAfterSeconds: 2.5)
        )
        let client = OpenAIRealtimeTranscriptionClient(transport: transport)

        do {
            _ = try await client.connect(
                apiKey: "test-key-not-a-secret",
                configuration: RealtimeTranscriptionConfiguration()
            )
            XCTFail("Expected rate limit failure")
        } catch let RealtimeClientError.connectionFailed(failure) {
            XCTAssertEqual(failure.reason, .rateLimited)
            XCTAssertEqual(failure.code, "http_429")
            XCTAssertEqual(failure.httpStatus, 429)
            XCTAssertEqual(failure.retryAfterSeconds, 2.5)
            XCTAssertFalse(failure.isTerminal)
        } catch {
            XCTFail("Unexpected unsanitized failure type")
        }
    }

    func testLiveHandshakeWithConfiguredAPIKey() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("OPENAI_API_KEY is not configured")
        }

        let client = OpenAIRealtimeTranscriptionClient()
        do {
            let connection = try await client.connect(
                apiKey: apiKey,
                configuration: RealtimeTranscriptionConfiguration()
            )
            XCTAssertGreaterThan(connection.id, 0)
            let state = await client.state
            guard case .ready = state else {
                XCTFail("Realtime handshake did not reach ready state")
                await client.disconnect()
                return
            }
            await client.disconnect()
        } catch let RealtimeClientError.connectionFailed(failure) {
            await client.disconnect()
            XCTFail(
                "Realtime handshake failed: reason=\(failure.reason.rawValue), "
                    + "code=\(failure.code), http=\(failure.httpStatus.map(String.init) ?? "none")"
            )
        } catch {
            await client.disconnect()
            XCTFail("Realtime handshake failed with an unexpected sanitized error type")
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor FakeRealtimeTransport: RealtimeTransport {
    private(set) var connectedModel: String?
    private(set) var sentPayloads: [Data] = []
    private var queued: [Result<Data, Error>] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []

    func enqueue(_ data: Data) {
        if waiters.isEmpty {
            queued.append(.success(data))
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    func fail(_ error: Error) {
        if waiters.isEmpty {
            queued.append(.failure(error))
        } else {
            waiters.removeFirst().resume(throwing: error)
        }
    }

    func connect(apiKey: String, modelID: String) async throws {
        connectedModel = modelID
    }

    func send(_ data: Data) async throws {
        sentPayloads.append(data)
    }

    func receive() async throws -> Data {
        if !queued.isEmpty {
            return try queued.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
