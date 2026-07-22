import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import RTMPHaishinKit

@Suite struct RTMPStreamEncodedOutputTests {
    @Test func encodedOutputRegistrationIsIdempotentAndRemovalUsesIdentity() async {
        let stream = RTMPStream(connection: RTMPConnection())
        let spy = Spy()
        await stream.addEncodedOutput(spy)
        await stream.addEncodedOutput(spy)

        guard let sampleBuffer = Self.makeCompressedVideoSampleBuffer() else {
            #expect(Bool(false))
            return
        }
        await stream.append(sampleBuffer)
        #expect(spy.count == 1)

        await stream.removeEncodedOutput(spy)
        guard let nextSampleBuffer = Self.makeCompressedVideoSampleBuffer(presentationTimeStamp: CMTime(value: 2, timescale: 1)) else {
            #expect(Bool(false))
            return
        }
        await stream.append(nextSampleBuffer)
        #expect(spy.count == 1)
    }

    private final class Spy: RTMPEncodedStreamOutput, @unchecked Sendable {
        var count = 0

        func stream(_ stream: RTMPStream, didOutputEncoded sampleBuffer: CMSampleBuffer) {
            count += 1
        }
    }

    private static func makeCompressedVideoSampleBuffer(presentationTimeStamp: CMTime = CMTime(value: 1, timescale: 1)) -> CMSampleBuffer? {
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
        ) == noErr, let blockBuffer,
        CMBlockBufferReplaceDataBytes(
            with: data.withUnsafeBytes { $0.baseAddress! },
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: data.count
        ) == noErr else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
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
