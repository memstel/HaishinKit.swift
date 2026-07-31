import AVFoundation
import Foundation
import VideoToolbox

enum VTSessionError: Swift.Error {
    case failedToCreate(status: OSStatus)
    case failedToPrepare(status: OSStatus)
    case failedToConvert(status: OSStatus)
    case failedToComplete(status: OSStatus)
    case codecRestartRequired
}

protocol VTSessionConvertible {
    func setOption(_ option: VTSessionOption) -> OSStatus
    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: AsyncStream<CMSampleBuffer>.Continuation?) throws
    func convert(
        _ sampleBuffer: CMSampleBuffer,
        continuation: AsyncStream<CMSampleBuffer>.Continuation?,
        forceKeyFrame: Bool,
        failureHandler: @escaping @Sendable (VTSessionError) -> Void
    ) throws
    func completeFrames() -> OSStatus
    func invalidate()
}

extension VTSessionConvertible {
    func convert(
        _ sampleBuffer: CMSampleBuffer,
        continuation: AsyncStream<CMSampleBuffer>.Continuation?,
        forceKeyFrame: Bool,
        failureHandler: @escaping @Sendable (VTSessionError) -> Void
    ) throws {
        try convert(
            sampleBuffer,
            continuation: continuation
        )
    }
}

extension VTSessionConvertible where Self: VTSession {
    func setOption(_ option: VTSessionOption) -> OSStatus {
        return VTSessionSetProperty(self, key: option.key.CFString, value: option.value)
    }

    func setOptions(_ options: Set<VTSessionOption>) -> OSStatus {
        var properties: [AnyHashable: AnyObject] = [:]
        for option in options {
            properties[option.key.CFString] = option.value
        }
        return VTSessionSetProperties(self, propertyDictionary: properties as CFDictionary)
    }
}
