import Foundation
import XCTest
@testable import AICallAssistant

final class RealtimeTransportTests: XCTestCase {
    func testConnectionUsesTranscriptionIntentInsteadOfTranscriptionModelQuery() throws {
        let endpoint = try XCTUnwrap(
            URL(string: "wss://api.openai.com/v1/realtime?model=stale&region=test")
        )
        let result = try URLSessionRealtimeTransport.transcriptionEndpoint(from: endpoint)
        let components = try XCTUnwrap(
            URLComponents(url: result, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value)
        })

        XCTAssertEqual(query["intent"]!, "transcription")
        XCTAssertEqual(query["region"]!, "test")
        XCTAssertFalse(query.keys.contains("model"))
    }

    func testOutboundJSONUsesTextWebSocketFrame() throws {
        let json = #"{"type":"session.update"}"#
        let message = try URLSessionRealtimeTransport.textMessage(for: Data(json.utf8))

        switch message {
        case let .string(value):
            XCTAssertEqual(value, json)
        case .data:
            XCTFail("Realtime JSON must be sent as a WebSocket text frame")
        @unknown default:
            XCTFail("Unexpected WebSocket message kind")
        }
    }

    func testOutboundInvalidUTF8IsRejectedBeforeSocketWrite() {
        XCTAssertThrowsError(
            try URLSessionRealtimeTransport.textMessage(for: Data([0xFF]))
        ) { error in
            XCTAssertEqual(error as? RealtimeTransportError, .unsupportedMessage)
        }
    }
}
