import Foundation
import XCTest
@testable import AICallAssistant

final class RealtimeEventsTests: XCTestCase {
    func testSessionUpdateMatchesTranscriptionContract() throws {
        let event = RealtimeClientEvent.updateSession(
            RealtimeTranscriptionConfiguration(
                languages: ["ru", "en"],
                delay: "low",
                prompt: "Interview",
                keywords: ["OpenAI"]
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertTrue(input.keys.contains("turn_detection"))
        XCTAssertTrue(input["turn_detection"] is NSNull)
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["languages"] as? [String], ["ru", "en"])
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertEqual(transcription["prompt"] as? String, "Interview")
        XCTAssertEqual(transcription["keywords"] as? [String], ["OpenAI"])
    }

    func testAppendAndCommitEncoding() throws {
        let append = try jsonObject(.appendAudio(Data([0x01, 0x02, 0x03])))
        XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(append["audio"] as? String, "AQID")

        let commit = try jsonObject(.commit(eventID: "incoming:1:turn"))
        XCTAssertEqual(commit["type"] as? String, "input_audio_buffer.commit")
        XCTAssertEqual(commit["event_id"] as? String, "incoming:1:turn")
    }

    func testServerEventsDecodeByItemID() throws {
        let decoder = JSONDecoder()
        let delta = try decoder.decode(
            RealtimeServerEvent.self,
            from: Data(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_3","content_index":0,"delta":"При"}"#.utf8)
        )
        XCTAssertEqual(
            delta,
            .transcriptDelta(itemID: "item_3", contentIndex: 0, delta: "При")
        )

        let completed = try decoder.decode(
            RealtimeServerEvent.self,
            from: Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_3","content_index":0,"transcript":"Привет"}"#.utf8)
        )
        XCTAssertEqual(
            completed,
            .transcriptCompleted(itemID: "item_3", contentIndex: 0, transcript: "Привет")
        )
    }

    func testProviderErrorDecodesWithoutExposingAuthorization() throws {
        let event = try JSONDecoder().decode(
            RealtimeServerEvent.self,
            from: Data(#"{"type":"error","error":{"type":"invalid_request_error","code":"bad_audio","message":"Invalid audio"}}"#.utf8)
        )
        XCTAssertEqual(
            event,
            .providerError(
                RealtimeProviderError(
                    type: "invalid_request_error",
                    code: "bad_audio"
                )
            )
        )
    }

    private func jsonObject(_ event: RealtimeClientEvent) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]
        )
    }
}
