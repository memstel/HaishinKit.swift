import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct AudioCodecTests {
    @Test func aac_44100hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 44100)
    }

    @Test func aac_48000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(48000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 48000)
    }

    @Test func aac_24000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(24000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 24000)
    }

    @Test func aac_16000hz_step_1024() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(16000.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 16000)
    }

    @Test func aac_8000hz_step_256() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(8000.0, numSamples: 256) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 8000)
    }

    @Test func aac_8000hz_step_960() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(8000.0, numSamples: 960) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 8000)
    }

    @Test func aac_44100hz_step_1224() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: 1224) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
    }

    @Test func aac_1_channel_to_2_channel() {
        let encoder = HaishinKit.AudioCodec()
        encoder.settings = .init(downmix: false, channelMap: [0, 0])
        encoder.startRunning()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.channelCount == 2)
    }

    @Test func aac_44100_any_steps() {
        let numSamples: [Int] = [1024, 1024, 1028, 1024, 1028, 1028, 962, 962, 960, 2237, 2236]
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        for numSample in numSamples {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: numSample) {
                encoder.append(sampleBuffer, when: .init())
            }
        }
        #expect(encoder.outputFormat?.sampleRate == 44100)
    }

    @Test func compressedOutputMakesAACSampleBuffer() async {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        var iterator = encoder.outputStream.makeAsyncIterator()
        for _ in 0..<10 {
            if let sampleBuffer = AVAudioPCMBufferFactory.makeSinWave(44100.0, numSamples: 1024) {
                encoder.append(sampleBuffer, when: .init())
            }
        }

        let output = await iterator.next()
        #expect(output != nil)
        guard let (audioBuffer, when) = output,
              let compressedBuffer = audioBuffer as? AVAudioCompressedBuffer,
              let sampleBuffer = compressedBuffer.makeCompressedSampleBuffer(when) else {
            return
        }
        #expect(sampleBuffer.formatDescription?.mediaType == .audio)
        #expect(sampleBuffer.formatDescription?.mediaSubType == .mpeg4AAC)
        #expect(sampleBuffer.presentationTimeStamp.isValid)
        #expect(sampleBuffer.duration.isValid)
        #expect(sampleBuffer.numSamples == Int(compressedBuffer.packetCount))
        #expect(sampleBuffer.duration.seconds < 0.1)
        guard let dataBuffer = sampleBuffer.dataBuffer else {
            Issue.record("The AAC sample buffer has no data block")
            return
        }
        #expect(CMSampleBufferGetTotalSampleSize(sampleBuffer) == CMBlockBufferGetDataLength(dataBuffer))
        #expect(CMSampleBufferGetTotalSampleSize(sampleBuffer) > 0)
    }

    @Test func stopRunningAndDrainEmitsNonFrameAlignedAACTail() async throws {
        let emissionSpy = AudioEmissionSpy()
        let encoder = HaishinKit.AudioCodec(
            outputObserver: emissionSpy.record
        )
        var iterator = encoder.outputStream.makeAsyncIterator()
        encoder.startRunning()
        let input = try #require(AVAudioPCMBufferFactory.makeSinWave(
            44_100,
            numSamples: 1_500
        ))

        encoder.append(input, when: AVAudioTime(sampleTime: 0, atRate: 44_100))
        let framesPerPacket = try #require(
            encoder.outputFormat?.streamDescription.pointee.mFramesPerPacket
        )
        #expect(framesPerPacket > 0)
        let expectedTailFrameCount = UInt32(input.frameLength) % framesPerPacket
        #expect(expectedTailFrameCount != 0)
        #expect(encoder.pendingInputFrameCount == Int(expectedTailFrameCount))
        let preDrainPacketCount = emissionSpy.packetCount
        #expect(preDrainPacketCount > 0)
        try encoder.stopRunningAndDrain()

        var packetCount: UInt32 = 0
        while let (buffer, _) = await iterator.next() {
            packetCount += (buffer as? AVAudioCompressedBuffer)?.packetCount ?? 0
        }
        #expect(encoder.pendingInputFrameCount == 0)
        #expect(packetCount == emissionSpy.packetCount)
        #expect(packetCount > preDrainPacketCount)
        #expect(
            (packetCount - preDrainPacketCount) * framesPerPacket
                >= expectedTailFrameCount
        )
    }

    @Test func appendRejectsConverterRecreationInsideRunningEpoch() throws {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        let first = try #require(AVAudioPCMBufferFactory.makeSinWave(
            44_100,
            numSamples: 1_024
        ))
        try encoder.appendOrThrow(
            first,
            when: AVAudioTime(sampleTime: 0, atRate: 44_100)
        )
        let changed = try #require(AVAudioPCMBufferFactory.makeSinWave(
            48_000,
            numSamples: 1_024
        ))

        do {
            try encoder.appendOrThrow(
                changed,
                when: AVAudioTime(sampleTime: 1_024, atRate: 48_000)
            )
            Issue.record("Expected a changed audio input format to require a new codec epoch")
        } catch {
            #expect(encoder.outputFormat?.sampleRate == 44_100)
        }
    }

    @Test func cleanStopAllowsDifferentInputFormatInNextEpoch() throws {
        let encoder = HaishinKit.AudioCodec()
        _ = encoder.outputStream
        encoder.startRunning()
        let firstEpochInput = try #require(AVAudioPCMBufferFactory.makeSinWave(
            44_100,
            numSamples: 1_024
        ))
        try encoder.appendOrThrow(
            firstEpochInput,
            when: AVAudioTime(sampleTime: 0, atRate: 44_100)
        )
        try encoder.stopRunningAndDrain()

        _ = encoder.outputStream
        encoder.startRunning()
        let secondEpochInput = try #require(AVAudioPCMBufferFactory.makeSinWave(
            48_000,
            numSamples: 1_024
        ))

        try encoder.appendOrThrow(
            secondEpochInput,
            when: AVAudioTime(sampleTime: 0, atRate: 48_000)
        )

        #expect(encoder.outputFormat?.sampleRate == 48_000)
        try encoder.stopRunningAndDrain()
    }

    @Test func test3Channel_withoutCrash() {
        let encoder = HaishinKit.AudioCodec()
        encoder.startRunning()
        if let sampleBuffer = CMAudioSampleBufferFactory.makeSilence(44100, numSamples: 256, channels: 3) {
            encoder.append(sampleBuffer)
        }
    }

    private final class AudioEmissionSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var storedPacketCount: UInt32 = 0

        var packetCount: UInt32 {
            lock.withLock {
                storedPacketCount
            }
        }

        var record: @Sendable (AVAudioBuffer, AVAudioTime) -> Void {
            { [weak self] buffer, _ in
                guard let compressedBuffer = buffer as? AVAudioCompressedBuffer else {
                    return
                }
                self?.lock.withLock {
                    self?.storedPacketCount += compressedBuffer.packetCount
                }
            }
        }
    }
}
