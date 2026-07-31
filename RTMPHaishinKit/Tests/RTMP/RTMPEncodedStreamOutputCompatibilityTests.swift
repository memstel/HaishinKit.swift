import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import RTMPHaishinKit

@Suite struct RTMPEncodedStreamOutputCompatibilityTests {
    @Test func legacySignatureReceivesSameVideoObjectsInAppendOrderWithUnchangedTimestamps() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let observer: any RTMPEncodedStreamOutput = LegacyObserver()
        await stream.addEncodedOutput(observer)

        let first = try #require(Self.makeCompressedVideoSampleBuffer(
            presentationTimeStamp: CMTime(value: 3, timescale: 30),
            decodeTimeStamp: CMTime(value: 1, timescale: 30)
        ))
        let second = try #require(Self.makeCompressedVideoSampleBuffer(
            presentationTimeStamp: CMTime(value: 4, timescale: 30),
            decodeTimeStamp: CMTime(value: 2, timescale: 30)
        ))
        await stream.append(first)
        await stream.append(second)

        let legacyObserver = try #require(observer as? LegacyObserver)
        #expect(legacyObserver.samples.count == 2)
        #expect(legacyObserver.samples[0] === first)
        #expect(legacyObserver.samples[1] === second)
        #expect(legacyObserver.samples.map(\.presentationTimeStamp) == [
            first.presentationTimeStamp,
            second.presentationTimeStamp
        ])
        #expect(legacyObserver.samples.map(\.decodeTimeStamp) == [
            first.decodeTimeStamp,
            second.decodeTimeStamp
        ])
    }

    @Test func observerRegistrationAndRemovalDoNotChangeStreamLifecycle() async {
        let stream = RTMPStream(connection: RTMPConnection())
        let observer = LegacyObserver()
        #expect(await stream.readyState == .idle)

        await stream.addEncodedOutput(observer)
        #expect(await stream.readyState == .idle)

        await stream.removeEncodedOutput(observer)
        #expect(await stream.readyState == .idle)
    }

    private final class LegacyObserver: RTMPEncodedStreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var storedSamples: [CMSampleBuffer] = []

        var samples: [CMSampleBuffer] {
            lock.lock()
            defer { lock.unlock() }
            return storedSamples
        }

        // This fixture intentionally uses the pre-existing public signature verbatim.
        func stream(_ stream: RTMPStream, didOutputEncoded sampleBuffer: CMSampleBuffer) {
            lock.lock()
            storedSamples.append(sampleBuffer)
            lock.unlock()
        }
    }

    private static func makeCompressedVideoSampleBuffer(
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1e, 0xe9, 0x01, 0x40, 0x7b, 0x20]
        let pps: [UInt8] = [0x68, 0xce, 0x3c, 0x80]
        var formatDescription: CMFormatDescription?
        let formatStatus = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                let parameterSetPointers = [
                    spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let parameterSetSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSetPointers.count,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard formatStatus == noErr, let formatDescription else {
            return nil
        }

        let data = Data([0, 0, 0, 2, 0x65, 0x88])
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }
        let replaceStatus = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard replaceStatus == noErr else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [data.count],
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}
