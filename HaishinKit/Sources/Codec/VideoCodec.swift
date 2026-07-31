import AVFoundation
import CoreFoundation
import VideoToolbox
#if canImport(UIKit)
import UIKit
#endif

final class VideoCodec {
    typealias SessionFactory = (VTSessionMode, VideoCodec) throws -> any VTSessionConvertible

    static let frameInterval: Double = 0.0

    var settings: VideoCodecSettings = .default {
        didSet {
            let invalidateSession = settings.invalidateSession(oldValue)
            if invalidateSession {
                self.invalidateSession = invalidateSession
            } else {
                settings.apply(self, rhs: oldValue)
            }
        }
    }
    var passthrough = true
    var outputStream: AsyncStream<CMSampleBuffer> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }
    var terminalFailureStream: AsyncStream<any Swift.Error> {
        terminalFailures.makeStream()
    }
    var frameInterval = VideoCodec.frameInterval
    private var startedAt: CMTime = .zero
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private var forceNextKeyFrame = false
    private var invalidateSession = true
    private var presentationTimeStamp: CMTime = .zero
    private var sessionFactory: SessionFactory?
    private let terminalFailures = TerminalFailureFlow()
    private var terminalFailureToken: TerminalFailureFlow.Token?
    private(set) var isRunning = false
    private(set) var inputFormat: CMFormatDescription? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            invalidateSession = true
            outputFormat = nil
        }
    }
    private(set) var session: (any VTSessionConvertible)? {
        didSet {
            oldValue?.invalidate()
            invalidateSession = false
        }
    }
    private(set) var outputFormat: CMFormatDescription?

    init() {
    }

    init(session: any VTSessionConvertible) {
        self.session = session
    }

    init(_ sessionFactory: @escaping SessionFactory) {
        self.sessionFactory = sessionFactory
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        do {
            try append(sampleBuffer, allowsSessionRecreation: true)
        } catch {
            logger.warn(error)
        }
    }

    func appendOrThrow(_ sampleBuffer: CMSampleBuffer) throws {
        try append(sampleBuffer, allowsSessionRecreation: false)
    }

    private func append(
        _ sampleBuffer: CMSampleBuffer,
        allowsSessionRecreation: Bool
    ) throws {
        guard isRunning else {
            return
        }
        inputFormat = sampleBuffer.formatDescription
        if invalidateSession {
            if session != nil, !allowsSessionRecreation {
                throw VTSessionError.codecRestartRequired
            }
            let mode: VTSessionMode = if sampleBuffer.formatDescription?.isCompressed == true {
                .decompression
            } else {
                .compression
            }
            if let sessionFactory {
                session = try sessionFactory(mode, self)
            } else {
                session = try mode.makeSession(self)
            }
            terminalFailureToken = terminalFailures.beginSession()
        }
        guard let session, let continuation else {
            return
        }
        if sampleBuffer.formatDescription?.isCompressed == true {
            try session.convert(sampleBuffer, continuation: continuation)
        } else {
            if useFrame(sampleBuffer.presentationTimeStamp) {
                let terminalFailureToken = if let terminalFailureToken {
                    terminalFailureToken
                } else {
                    terminalFailures.beginSession()
                }
                self.terminalFailureToken = terminalFailureToken
                try session.convert(
                    sampleBuffer,
                    continuation: continuation,
                    forceKeyFrame: forceNextKeyFrame,
                    failureHandler: { [terminalFailures, terminalFailureToken] error in
                        terminalFailures.yield(
                            error,
                            token: terminalFailureToken
                        )
                    }
                )
                forceNextKeyFrame = false
                presentationTimeStamp = sampleBuffer.presentationTimeStamp
            }
        }
    }

    func requestKeyFrame() {
        forceNextKeyFrame = true
    }

    func stopRunningAndDrain() throws {
        guard isRunning else {
            return
        }
        defer {
            stopRunning()
        }
        if let status = session?.completeFrames(), status != noErr {
            throw VTSessionError.failedToComplete(status: status)
        }
    }

    func makeImageBufferAttributes(_ mode: VTSessionMode) -> [NSString: AnyObject]? {
        switch mode {
        case .compression:
            var attributes: [NSString: AnyObject] = [:]
            if let inputFormat {
                // Specify the pixel format of the uncompressed video.
                attributes[kCVPixelBufferPixelFormatTypeKey] = inputFormat.mediaType.rawValue as CFNumber
            }
            return attributes.isEmpty ? nil : attributes
        case .decompression:
            return [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue
            ]
        }
    }

    private func useFrame(_ presentationTimeStamp: CMTime) -> Bool {
        guard startedAt <= presentationTimeStamp else {
            return false
        }
        guard self.presentationTimeStamp < presentationTimeStamp else {
            return false
        }
        guard Self.frameInterval < frameInterval else {
            return true
        }
        return frameInterval <= presentationTimeStamp.seconds - self.presentationTimeStamp.seconds
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    @objc
    private func applicationWillEnterForeground(_ notification: Notification) {
        invalidateSession = true
    }

    @objc
    private func didAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo: [AnyHashable: Any] = notification.userInfo,
            let value: NSNumber = userInfo[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else {
            return
        }
        switch type {
        case .ended:
            invalidateSession = true
        default:
            break
        }
    }
    #endif
}

extension VideoCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.didAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
        startedAt = passthrough ? .zero : CMClockGetTime(CMClockGetHostTimeClock())
        terminalFailures.beginEpoch()
        if session != nil {
            terminalFailureToken = terminalFailures.beginSession()
        }
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        session = nil
        invalidateSession = true
        inputFormat = nil
        outputFormat = nil
        presentationTimeStamp = .zero
        forceNextKeyFrame = false
        continuation?.finish()
        terminalFailureToken = nil
        terminalFailures.finishEpoch()
        startedAt = .zero
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }
}

private extension VideoCodec {
    final class TerminalFailureFlow: @unchecked Sendable {
        struct Token: Sendable, Equatable {
            let epoch: UUID
            let session: UUID
        }

        private let lock = NSLock()
        private var continuation: AsyncStream<any Swift.Error>.Continuation?
        private var epoch: UUID?
        private var activeToken: Token?

        func makeStream() -> AsyncStream<any Swift.Error> {
            let (stream, continuation) = AsyncStream.makeStream(
                of: (any Swift.Error).self
            )
            let previous = lock.withLock {
                let previous = self.continuation
                self.continuation = continuation
                return previous
            }
            previous?.finish()
            return stream
        }

        func beginEpoch() {
            lock.withLock {
                epoch = UUID()
                activeToken = nil
            }
        }

        func beginSession() -> Token {
            lock.withLock {
                guard let epoch else {
                    preconditionFailure("A terminal-failure session requires an active codec epoch")
                }
                let token = Token(epoch: epoch, session: UUID())
                activeToken = token
                return token
            }
        }

        func yield(_ error: any Swift.Error, token: Token) {
            let continuation = lock.withLock {
                activeToken == token ? self.continuation : nil
            }
            continuation?.yield(error)
        }

        func finishEpoch() {
            let continuation = lock.withLock {
                let continuation = self.continuation
                self.continuation = nil
                activeToken = nil
                epoch = nil
                return continuation
            }
            continuation?.finish()
        }
    }
}
