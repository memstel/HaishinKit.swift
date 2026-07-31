import AVFoundation
import Foundation

/// An immutable envelope for one encoded audio or video sample.
public struct EncodedMediaSample: @unchecked Sendable {
    public let codecEpoch: UUID
    public let formatEpoch: UInt64
    public let deliverySequence: UInt64
    public let sampleBuffer: CMSampleBuffer

    public init(
        codecEpoch: UUID,
        formatEpoch: UInt64,
        deliverySequence: UInt64,
        sampleBuffer: CMSampleBuffer
    ) {
        self.codecEpoch = codecEpoch
        self.formatEpoch = formatEpoch
        self.deliverySequence = deliverySequence
        self.sampleBuffer = sampleBuffer
    }
}
