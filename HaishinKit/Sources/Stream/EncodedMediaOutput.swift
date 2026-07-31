import Foundation

/// Receives encoded samples from an ``EncodedMediaPipeline``.
public protocol EncodedMediaOutput: AnyObject, Sendable {
    func encodedMediaPipeline(
        _ pipeline: EncodedMediaPipeline,
        didOutput sample: EncodedMediaSample
    )

    func encodedMediaPipeline(
        _ pipeline: EncodedMediaPipeline,
        didEndCodecEpoch codecEpoch: UUID,
        lastDeliverySequence: UInt64
    )
}

/// Bounds one output's independent delivery queue.
public struct EncodedMediaOutputIngressPolicy: Sendable, Equatable {
    public enum OverflowDisposition: Sendable, Equatable {
        case dropNewest
        case failPipeline
    }

    public static let `default` = EncodedMediaOutputIngressPolicy(
        maximumSampleCount: 512,
        maximumByteCount: 32 * 1_024 * 1_024,
        overflowDisposition: .dropNewest
    )

    public static let authoritative = EncodedMediaOutputIngressPolicy(
        maximumSampleCount: 512,
        maximumByteCount: 32 * 1_024 * 1_024,
        overflowDisposition: .failPipeline
    )

    public let maximumSampleCount: Int
    public let maximumByteCount: Int
    public let overflowDisposition: OverflowDisposition

    public init(
        maximumSampleCount: Int,
        maximumByteCount: Int,
        overflowDisposition: OverflowDisposition = .dropNewest
    ) {
        precondition(maximumSampleCount > 0)
        precondition(maximumByteCount > 0)
        self.maximumSampleCount = maximumSampleCount
        self.maximumByteCount = maximumByteCount
        self.overflowDisposition = overflowDisposition
    }
}
