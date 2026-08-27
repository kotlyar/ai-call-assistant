@preconcurrency import AVFoundation
import AudioToolbox
import XCTest
@testable import AICallAssistant

final class AudioCapturePipelineTests: XCTestCase {
    func testActivationGateSuppressesSamplesUntilBothSourcesAreReady() {
        let gate = CaptureActivationGate()

        XCTAssertFalse(gate.isOpen)
        gate.open()
        XCTAssertTrue(gate.isOpen)
        gate.close()
        XCTAssertFalse(gate.isOpen)
    }

    func testMicrophoneCaptureRequestsCanonicalFloat32PCM() throws {
        let settings = CanonicalMicrophoneCaptureFormat.audioSettings
        let format = try XCTUnwrap(AVAudioFormat(settings: settings))

        XCTAssertEqual(settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertTrue(format.isInterleaved)
        XCTAssertEqual(format.streamDescription.pointee.mBytesPerFrame, 4)
        XCTAssertEqual(format.streamDescription.pointee.mFramesPerPacket, 1)
    }
}
