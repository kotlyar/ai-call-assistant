@preconcurrency import AVFoundation
import XCTest
@testable import AICallAssistant

final class LiveAudioPCMConverterTests: XCTestCase {
    func testConverts48KHzStereoTo24KHzMonoPCM16Chunks() throws {
        let converter = LiveAudioPCMConverter(track: .incoming)
        let input = try makeFloatBuffer(
            sampleRate: 48_000,
            channels: 2,
            frameCount: 4_800
        ) { channel, _ in
            channel == 0 ? 0.5 : -0.5
        }

        var chunks = try converter.convert(input, startCallNanoseconds: 250_000_000)
        chunks.append(contentsOf: converter.finish())

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertLessThanOrEqual(
            abs(chunks.map(\.frameCount).reduce(0, +) - 2_400),
            2
        )
        XCTAssertEqual(chunks.first?.track, .incoming)
        XCTAssertEqual(chunks.first?.startCallNanoseconds, 250_000_000)
        XCTAssertTrue(chunks.allSatisfy { $0.pcm16LittleEndian.count == $0.frameCount * 2 })

        let samples = chunks.flatMap { decodePCM16($0.pcm16LittleEndian) }
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertLessThan(peak, 1_500, "Stereo channels should be downmixed close to silence")
    }

    func testConverts44100HzMicWithoutLosingDurationAcrossBuffers() throws {
        let converter = LiveAudioPCMConverter(track: .outgoing)
        let first = try makeFloatBuffer(
            sampleRate: 44_100,
            channels: 1,
            frameCount: 22_050
        ) { _, frame in
            sin(Float(frame) * 0.01) * 0.2
        }
        let second = try makeFloatBuffer(
            sampleRate: 44_100,
            channels: 1,
            frameCount: 22_050
        ) { _, frame in
            sin(Float(frame + 22_050) * 0.01) * 0.2
        }

        var chunks = try converter.convert(first, startCallNanoseconds: 0)
        chunks += try converter.convert(second, startCallNanoseconds: 500_000_000)
        chunks += converter.finish()

        let totalFrames = chunks.map(\.frameCount).reduce(0, +)
        XCTAssertLessThanOrEqual(abs(totalFrames - 24_000), 4)
        XCTAssertEqual(chunks.map(\.sequence), Array(0..<UInt64(chunks.count)))
        XCTAssertTrue(chunks.allSatisfy { $0.track == .outgoing })
    }

    func testConvertsInterleavedFloat32AirPodsMicrophonePCM() throws {
        let converter = LiveAudioPCMConverter(track: .outgoing)
        let input = try makeFloatBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800,
            interleaved: true
        ) { _, frame in
            sin(Float(frame) * 0.01) * 0.25
        }

        XCTAssertFalse(
            input.format.isStandard,
            "The regression fixture must match AVCapture's interleaved AirPods format"
        )

        var chunks = try converter.convert(input, startCallNanoseconds: 0)
        chunks += converter.finish()

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertLessThanOrEqual(
            abs(chunks.map(\.frameCount).reduce(0, +) - 2_400),
            2
        )
        XCTAssertTrue(chunks.allSatisfy { $0.track == .outgoing })
        XCTAssertGreaterThan(
            chunks.flatMap { decodePCM16($0.pcm16LittleEndian) }
                .map { abs(Int($0)) }
                .max() ?? 0,
            1_000
        )
    }

    func testConvertsCapturedAirPodsInterleavedSampleBuffer() throws {
        let converter = LiveAudioPCMConverter(track: .outgoing)
        let input = try makeFloatBuffer(
            sampleRate: 24_000,
            channels: 1,
            frameCount: 2_400,
            interleaved: true
        ) { _, frame in
            sin(Float(frame) * 0.02) * 0.2
        }
        let sampleBuffer = try makeSampleBuffer(from: input)

        var chunks = try converter.convert(
            CapturedAudioFrame(
                track: .outgoing,
                sampleBuffer: sampleBuffer,
                startCallNanoseconds: 500_000_000
            )
        )
        chunks += converter.finish()

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.map(\.frameCount).reduce(0, +), 2_400)
        XCTAssertEqual(chunks.first?.startCallNanoseconds, 500_000_000)
        XCTAssertTrue(chunks.allSatisfy { $0.track == .outgoing })
    }

    func testLongSourceGapIsExplicitDiscontinuityAndKeepsAbsoluteTimestamp() throws {
        let converter = LiveAudioPCMConverter(track: .incoming)
        let input = try makeFloatBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800
        ) { _, _ in 0.1 }

        var chunks = try converter.convert(input, startCallNanoseconds: 0)
        chunks += try converter.convert(input, startCallNanoseconds: 7_000_000_000)
        chunks += converter.finish()

        let discontinuous = try XCTUnwrap(chunks.first(where: \.discontinuityBefore))
        XCTAssertEqual(discontinuous.startCallNanoseconds, 7_000_000_000)
        XCTAssertLessThanOrEqual(chunks.map(\.pcm16LittleEndian.count).max() ?? 0, 4_800)
    }

    func testForcedDiscontinuitySkipsShortGapSilence() throws {
        let converter = LiveAudioPCMConverter(track: .incoming)
        let input = try makeFloatBuffer(
            sampleRate: 48_000,
            channels: 1,
            frameCount: 4_800
        ) { _, _ in 0.1 }

        var chunks = try converter.convert(input, startCallNanoseconds: 0)
        chunks += converter.forceDiscontinuityBeforeNextInput()
        chunks += try converter.convert(input, startCallNanoseconds: 1_000_000_000)
        chunks += converter.finish()

        let discontinuous = try XCTUnwrap(chunks.first(where: \.discontinuityBefore))
        XCTAssertEqual(discontinuous.startCallNanoseconds, 1_000_000_000)
        XCTAssertLessThan(
            chunks.map(\.frameCount).reduce(0, +),
            6_000,
            "A known loss must not be padded with the 900 ms source-clock gap"
        )
    }

    private func makeFloatBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: AVAudioFrameCount,
        interleaved: Bool = false,
        sample: (Int, Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = sample(channel, frame)
            }
        }
        return buffer
    }

    private func decodePCM16(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { rawBuffer in
            let words = rawBuffer.bindMemory(to: Int16.self)
            return words.map { Int16(littleEndian: $0) }
        }
    }

    private func makeSampleBuffer(from input: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var formatDescription: CMAudioFormatDescription?
        let descriptionStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: input.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(descriptionStatus, noErr)

        let byteCount = Int(input.frameLength)
            * Int(input.format.streamDescription.pointee.mBytesPerFrame)
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, noErr)
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: samples,
            blockBuffer: try XCTUnwrap(blockBuffer),
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        XCTAssertEqual(copyStatus, noErr)

        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: try XCTUnwrap(blockBuffer),
            formatDescription: try XCTUnwrap(formatDescription),
            sampleCount: CMItemCount(input.frameLength),
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sampleStatus, noErr)
        return try XCTUnwrap(sampleBuffer)
    }
}
