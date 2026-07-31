import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct VideoCodecTests {
    @Test func stopRunningAndDrainPropagatesCompleteFramesFailure() {
        let session = FailingSession()
        let codec = VideoCodec(session: session)
        codec.startRunning()

        do {
            try codec.stopRunningAndDrain()
            Issue.record("Expected completeFrames failure to be propagated")
        } catch {
            #expect(session.completeFramesCallCount == 1)
            #expect(codec.isRunning == false)
        }
    }

    @Test func appendPropagatesSessionConversionFailure() throws {
        let session = FailingSession(convertError: VTSessionError.failedToConvert(status: -2))
        let codec = VideoCodec { _, _ in
            session
        }
        _ = codec.outputStream
        codec.startRunning()
        let sampleBuffer = try #require(Self.makeVideoSampleBuffer())

        do {
            try codec.appendOrThrow(sampleBuffer)
            Issue.record("Expected the VideoToolbox conversion failure to be propagated")
        } catch {
            #expect(session.convertCallCount == 1)
        }
    }

    @Test func appendRejectsSessionRecreationInsideRunningEpoch() throws {
        var sessionCreationCount = 0
        let codec = VideoCodec { _, _ in
            sessionCreationCount += 1
            return FailingSession()
        }
        _ = codec.outputStream
        codec.startRunning()
        try codec.appendOrThrow(try #require(Self.makeVideoSampleBuffer(width: 16)))

        do {
            try codec.appendOrThrow(try #require(Self.makeVideoSampleBuffer(width: 32)))
            Issue.record("Expected a changed input format to require a new codec epoch")
        } catch {
            #expect(sessionCreationCount == 1)
        }
    }

    @Test func asynchronousCompressionCallbackFailureBecomesTerminalCodecFailure() async throws {
        let callbackStatus: OSStatus = -12_903
        let session = CallbackFailingSession(callbackStatus: callbackStatus)
        let codec = VideoCodec { _, _ in
            session
        }
        let terminalFailureStream = codec.terminalFailureStream
        _ = codec.outputStream
        codec.startRunning()

        try codec.appendOrThrow(try #require(Self.makeVideoSampleBuffer()))

        var iterator = terminalFailureStream.makeAsyncIterator()
        let failure = try #require(await iterator.next())
        guard
            let videoToolboxError = failure as? VTSessionError,
            case let .failedToConvert(status) = videoToolboxError else {
            Issue.record("Expected a VideoToolbox conversion failure")
            codec.stopRunning()
            return
        }
        #expect(status == callbackStatus)
        codec.stopRunning()
    }

    @Test func delayedFailureFromPreviousSessionCannotEnterRestartedEpoch() async throws {
        let previousEpochStatus: OSStatus = -12_904
        let currentEpochStatus: OSStatus = -12_905
        let previousSession = DeferredCallbackSession()
        let currentSession = DeferredCallbackSession()
        var sessions: [DeferredCallbackSession] = [
            previousSession,
            currentSession
        ]
        let codec = VideoCodec { _, _ in
            sessions.removeFirst()
        }

        _ = codec.terminalFailureStream
        _ = codec.outputStream
        codec.startRunning()
        try codec.appendOrThrow(try #require(Self.makeVideoSampleBuffer()))
        codec.stopRunning()

        let restartedTerminalFailureStream = codec.terminalFailureStream
        _ = codec.outputStream
        codec.startRunning()
        try codec.appendOrThrow(try #require(Self.makeVideoSampleBuffer()))

        previousSession.fail(status: previousEpochStatus)
        currentSession.fail(status: currentEpochStatus)

        var iterator = restartedTerminalFailureStream.makeAsyncIterator()
        let failure = try #require(await iterator.next())
        guard
            let videoToolboxError = failure as? VTSessionError,
            case let .failedToConvert(status) = videoToolboxError else {
            Issue.record("Expected a VideoToolbox conversion failure")
            codec.stopRunning()
            return
        }
        #expect(status == currentEpochStatus)
        codec.stopRunning()
    }

    private final class CallbackFailingSession: VTSessionConvertible {
        private let callbackStatus: OSStatus

        init(callbackStatus: OSStatus) {
            self.callbackStatus = callbackStatus
        }

        func setOption(_ option: VTSessionOption) -> OSStatus {
            noErr
        }

        func setOptions(_ options: Set<VTSessionOption>) -> OSStatus {
            noErr
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?
        ) throws {
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?,
            forceKeyFrame: Bool
        ) throws {
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?,
            forceKeyFrame: Bool,
            failureHandler: @escaping @Sendable (VTSessionError) -> Void
        ) throws {
            VTCompressionSessionOutputHandler(
                continuation: continuation,
                failureHandler: failureHandler
            ).handle(status: callbackStatus, sampleBuffer: nil)
        }

        func completeFrames() -> OSStatus {
            noErr
        }

        func invalidate() {
        }
    }

    private final class DeferredCallbackSession: VTSessionConvertible {
        private let lock = NSLock()
        private var failureHandler: (@Sendable (VTSessionError) -> Void)?

        func setOption(_ option: VTSessionOption) -> OSStatus {
            noErr
        }

        func setOptions(_ options: Set<VTSessionOption>) -> OSStatus {
            noErr
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?
        ) throws {
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?,
            forceKeyFrame: Bool
        ) throws {
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?,
            forceKeyFrame: Bool,
            failureHandler: @escaping @Sendable (VTSessionError) -> Void
        ) throws {
            lock.withLock {
                self.failureHandler = failureHandler
            }
        }

        func completeFrames() -> OSStatus {
            noErr
        }

        func invalidate() {
        }

        func fail(status: OSStatus) {
            let failureHandler = lock.withLock {
                self.failureHandler
            }
            failureHandler?(.failedToConvert(status: status))
        }
    }

    private final class FailingSession: VTSessionConvertible {
        private(set) var completeFramesCallCount = 0
        private(set) var convertCallCount = 0
        private let convertError: (any Swift.Error)?

        init(convertError: (any Swift.Error)? = nil) {
            self.convertError = convertError
        }

        func setOption(_ option: VTSessionOption) -> OSStatus {
            noErr
        }

        func setOptions(_ options: Set<VTSessionOption>) -> OSStatus {
            noErr
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?
        ) throws {
            convertCallCount += 1
            if let convertError {
                throw convertError
            }
        }

        func convert(
            _ sampleBuffer: CMSampleBuffer,
            continuation: AsyncStream<CMSampleBuffer>.Continuation?,
            forceKeyFrame: Bool
        ) throws {
            try convert(sampleBuffer, continuation: continuation)
        }

        func completeFrames() -> OSStatus {
            completeFramesCallCount += 1
            return -1
        }

        func invalidate() {
        }
    }

    private static func makeVideoSampleBuffer(width: Int = 16) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: 1, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }
}
