import AVFoundation
import Foundation

extension AVAudioCompressedBuffer {
    package func makeCompressedSampleBuffer(_ when: AVAudioTime) -> CMSampleBuffer? {
        // CoreMedia's numSamples is the number of packet descriptions here;
        // each AAC packet already carries its frame count in the format.
        let sampleCount = packetCount
        var status: OSStatus = noErr
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: Int(sampleCount),
            presentationTimeStamp: when.makeTime(),
            packetDescriptions: packetDescriptions,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            return nil
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        )
        guard status == noErr else {
            return nil
        }
        return sampleBuffer
    }

    @discardableResult
    @inline(__always)
    final func copy(_ buffer: AVAudioBuffer) -> Bool {
        guard let buffer = buffer as? AVAudioCompressedBuffer else {
            return false
        }
        if let packetDescriptions = buffer.packetDescriptions {
            self.packetDescriptions?.pointee = packetDescriptions.pointee
        }
        packetCount = buffer.packetCount
        byteLength = buffer.byteLength
        data.copyMemory(from: buffer.data, byteCount: Int(buffer.byteLength))
        return true
    }

    package func encode(to data: inout Data) {
        guard let config = AudioSpecificConfig(formatDescription: format.formatDescription) else {
            return
        }
        config.encode(to: &data, length: Int(byteLength))
        data.withUnsafeMutableBytes {
            guard let baseAddress = $0.baseAddress else {
                return
            }
            memcpy(baseAddress.advanced(by: AudioSpecificConfig.adtsHeaderSize), self.data, Int(self.byteLength))
        }
    }
}
