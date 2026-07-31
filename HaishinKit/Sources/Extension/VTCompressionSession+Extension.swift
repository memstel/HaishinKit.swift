import Foundation
import VideoToolbox

struct VTCompressionSessionOutputHandler: Sendable {
    let continuation: AsyncStream<CMSampleBuffer>.Continuation?
    let failureHandler: @Sendable (VTSessionError) -> Void

    func handle(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr else {
            failureHandler(.failedToConvert(status: status))
            return
        }
        if let sampleBuffer {
            continuation?.yield(sampleBuffer)
        }
    }
}

extension VTCompressionSession {
    func prepareToEncodeFrames() -> OSStatus {
        VTCompressionSessionPrepareToEncodeFrames(self)
    }

    func completeFrames() -> OSStatus {
        VTCompressionSessionCompleteFrames(self, untilPresentationTimeStamp: .invalid)
    }
}

extension VTCompressionSession: VTSessionConvertible {
    @inline(__always)
    func convert(_ sampleBuffer: CMSampleBuffer, continuation: AsyncStream<CMSampleBuffer>.Continuation?) throws {
        try convert(
            sampleBuffer,
            continuation: continuation,
            forceKeyFrame: false,
            failureHandler: { _ in }
        )
    }

    @inline(__always)
    func convert(
        _ sampleBuffer: CMSampleBuffer,
        continuation: AsyncStream<CMSampleBuffer>.Continuation?,
        forceKeyFrame: Bool,
        failureHandler: @escaping @Sendable (VTSessionError) -> Void
    ) throws {
        guard let imageBuffer = sampleBuffer.imageBuffer else {
            return
        }
        var flags: VTEncodeInfoFlags = []
        let outputHandler = VTCompressionSessionOutputHandler(
            continuation: continuation,
            failureHandler: failureHandler
        )
        let status = VTCompressionSessionEncodeFrame(
            self,
            imageBuffer: imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: sampleBuffer.duration,
            frameProperties: forceKeyFrame ? [
                kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any
            ] as CFDictionary : nil,
            infoFlagsOut: &flags,
            outputHandler: { status, _, sampleBuffer in
                outputHandler.handle(status: status, sampleBuffer: sampleBuffer)
            }
        )
        if status != noErr {
            throw VTSessionError.failedToConvert(status: status)
        }
    }

    func invalidate() {
        VTCompressionSessionInvalidate(self)
    }
}
