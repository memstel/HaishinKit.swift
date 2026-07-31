import AVFoundation
import Foundation

package struct EncodedMediaPipelineIngressConfiguration: Sendable, Equatable {
    package static let realtime = EncodedMediaPipelineIngressConfiguration(
        audioCapacity: 8,
        videoCapacity: 3
    )

    package let audioCapacity: Int
    package let videoCapacity: Int

    package init(audioCapacity: Int, videoCapacity: Int) {
        precondition(0 < audioCapacity)
        precondition(0 < videoCapacity)
        self.audioCapacity = audioCapacity
        self.videoCapacity = videoCapacity
    }
}

package typealias EncodedMediaPipelineAsyncOperationScheduler =
    @Sendable (@escaping @Sendable () async -> Void) -> Void

package struct EncodedMediaPipelineTestHooks: Sendable {
    package let stoppingTaskBarrier: @Sendable () async -> Void
    package let didJoinStoppingTask: @Sendable () -> Void

    package init(
        stoppingTaskBarrier: @escaping @Sendable () async -> Void = {},
        didJoinStoppingTask: @escaping @Sendable () -> Void = {}
    ) {
        self.stoppingTaskBarrier = stoppingTaskBarrier
        self.didJoinStoppingTask = didJoinStoppingTask
    }
}

package protocol EncodedMediaPipelineOutgoing: AnyObject, Sendable {
    var audioOutputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)> { get }
    var videoOutputStream: AsyncStream<CMSampleBuffer> { get }
    var videoTerminalFailureStream: AsyncStream<any Swift.Error> { get }
    var audioSettings: AudioCodecSettings { get set }
    var videoSettings: VideoCodecSettings { get set }

    func applyAudioSettings(
        _ settings: AudioCodecSettings,
        allowingCodecRestart: Bool
    ) throws
    func applyVideoSettings(
        _ settings: VideoCodecSettings,
        allowingCodecRestart: Bool
    ) throws
    func appendEncodedAudio(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) throws
    func appendEncodedVideo(_ sampleBuffer: CMSampleBuffer) throws
    func requestVideoKeyFrame()
    func startRunning()
    func stopRunningAndDrain() async throws
}

extension EncodedMediaPipelineOutgoing {
    package func applyAudioSettings(
        _ settings: AudioCodecSettings,
        allowingCodecRestart: Bool
    ) throws {
        if
            !allowingCodecRestart,
            settings.invalidateConverter(audioSettings) {
            throw EncodedMediaPipeline.Error.settingsChangeRequiresCodecRestart
        }
        audioSettings = settings
    }

    package func applyVideoSettings(
        _ settings: VideoCodecSettings,
        allowingCodecRestart: Bool
    ) throws {
        if
            !allowingCodecRestart,
            settings.invalidateSession(videoSettings) {
            throw EncodedMediaPipeline.Error.settingsChangeRequiresCodecRestart
        }
        videoSettings = settings
    }
}

/// Encodes composited mixer output without coupling the codec lifecycle to a transport.
public actor EncodedMediaPipeline: MediaMixerOutput {
    public enum Error: Swift.Error {
        case encodedAudioOutputIsNotCompressed
        case failedToCreateCompressedAudioSampleBuffer
        case lifecycleTransitionInProgress
        case settingsChangeRequiresCodecRestart
        case audioIngressOverflow
        case videoIngressOverflow
        case outputIngressOverflow
        case keyFrameFenceUnavailable
    }

    private enum Lifecycle {
        case idle
        case starting
        case running
        case stopping
    }

    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max

    private let outgoing: any EncodedMediaPipelineOutgoing
    private let audioSampleBufferFactory:
        @Sendable (AVAudioCompressedBuffer, AVAudioTime) -> CMSampleBuffer?
    nonisolated private let overflowFailureScheduler:
        EncodedMediaPipelineAsyncOperationScheduler
    private let testHooks: EncodedMediaPipelineTestHooks
    private let fanoutTestHooks: EncodedMediaOutputFanoutTestHooks
    nonisolated private let outputFailure = EncodedMediaPipelineFailureLatch()
    nonisolated private let mixerIngress: EncodedMediaPipelineIngress
    private var registeredOutputs: [
        ObjectIdentifier: (output: any EncodedMediaOutput, policy: EncodedMediaOutputIngressPolicy)
    ] = [:]
    private var fanout: EncodedMediaOutputFanout?
    private var stoppingFanout: EncodedMediaOutputFanout?
    private var activeCodecEpoch: UUID?
    private var mixerIngressEpoch: EncodedMediaPipelineIngress.Epoch?
    private var mixerAudioInputTask: Task<Void, Never>?
    private var mixerVideoInputTask: Task<Void, Never>?
    private var audioOutputTask: Task<Void, Never>?
    private var videoOutputTask: Task<Void, Never>?
    private var videoTerminalFailureTask: Task<Void, Never>?
    private var lifecycle: Lifecycle = .idle
    private var terminalFailure: (any Swift.Error)?
    private var completedTerminalFailure: (any Swift.Error)?
    private var automaticStopTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, any Swift.Error>?

    package var activeCodecEpochForTesting: UUID? {
        activeCodecEpoch
    }

    public init() {
        outgoing = OutgoingStream()
        mixerIngress = EncodedMediaPipelineIngress(configuration: .realtime)
        audioSampleBufferFactory = { audioBuffer, when in
            audioBuffer.makeCompressedSampleBuffer(when)
        }
        overflowFailureScheduler = { operation in
            Task {
                await operation()
            }
        }
        testHooks = .init()
        fanoutTestHooks = .init()
    }

    package init(
        outgoing: any EncodedMediaPipelineOutgoing,
        ingressConfiguration: EncodedMediaPipelineIngressConfiguration = .realtime,
        overflowFailureScheduler:
            @escaping EncodedMediaPipelineAsyncOperationScheduler = { operation in
                Task {
                    await operation()
                }
            },
        audioSampleBufferFactory:
            @escaping @Sendable (AVAudioCompressedBuffer, AVAudioTime) -> CMSampleBuffer? = {
                audioBuffer,
                when in
                audioBuffer.makeCompressedSampleBuffer(when)
            },
        testHooks: EncodedMediaPipelineTestHooks = .init(),
        fanoutTestHooks: EncodedMediaOutputFanoutTestHooks = .init()
    ) {
        self.outgoing = outgoing
        mixerIngress = EncodedMediaPipelineIngress(
            configuration: ingressConfiguration
        )
        self.audioSampleBufferFactory = audioSampleBufferFactory
        self.overflowFailureScheduler = overflowFailureScheduler
        self.testHooks = testHooks
        self.fanoutTestHooks = fanoutTestHooks
    }

    public func setVideoSettings(_ settings: VideoCodecSettings) throws {
        let allowingCodecRestart: Bool
        switch lifecycle {
        case .idle:
            allowingCodecRestart = true
        case .running:
            allowingCodecRestart = false
        case .starting, .stopping:
            throw Error.lifecycleTransitionInProgress
        }
        try outgoing.applyVideoSettings(
            settings,
            allowingCodecRestart: allowingCodecRestart
        )
    }

    public func setAudioSettings(_ settings: AudioCodecSettings) throws {
        let allowingCodecRestart: Bool
        switch lifecycle {
        case .idle:
            allowingCodecRestart = true
        case .running:
            allowingCodecRestart = false
        case .starting, .stopping:
            throw Error.lifecycleTransitionInProgress
        }
        try outgoing.applyAudioSettings(
            settings,
            allowingCodecRestart: allowingCodecRestart
        )
    }

    public func addOutput(_ output: some EncodedMediaOutput) {
        addOutput(output, ingressPolicy: .default)
    }

    public func addOutput(
        _ output: some EncodedMediaOutput,
        ingressPolicy: EncodedMediaOutputIngressPolicy
    ) {
        let identifier = ObjectIdentifier(output)
        guard registeredOutputs[identifier] == nil else {
            return
        }
        registeredOutputs[identifier] = (output, ingressPolicy)
        guard lifecycle == .running else {
            return
        }
        fanout?.addOutput(output, policy: ingressPolicy)
    }

    public func removeOutput(_ output: some EncodedMediaOutput) async {
        registeredOutputs.removeValue(forKey: ObjectIdentifier(output))
        let removalFanout = fanout ?? stoppingFanout
        await removalFanout?.removeOutput(output)
    }

    public func startEncoding() throws {
        switch lifecycle {
        case .idle:
            lifecycle = .starting
            terminalFailure = nil
            completedTerminalFailure = nil
            automaticStopTask = nil
        case .running:
            return
        case .starting, .stopping:
            throw Error.lifecycleTransitionInProgress
        }
        let codecEpoch = UUID()
        activeCodecEpoch = codecEpoch
        outputFailure.begin(codecEpoch)
        let fanout = EncodedMediaOutputFanout(
            codecEpoch: codecEpoch,
            pipeline: self,
            testHooks: fanoutTestHooks,
            didOverflow: { [weak self] reportedCodecEpoch in
                self?.reportOutputFailure(
                    Error.outputIngressOverflow,
                    codecEpoch: reportedCodecEpoch
                )
            }
        )
        for registration in registeredOutputs.values {
            fanout.addOutput(registration.output, policy: registration.policy)
        }
        self.fanout = fanout

        let audioOutputStream = outgoing.audioOutputStream
        let audioSampleBufferFactory = self.audioSampleBufferFactory
        let videoOutputStream = outgoing.videoOutputStream
        let videoTerminalFailureStream = outgoing.videoTerminalFailureStream
        let overflowFailureScheduler = self.overflowFailureScheduler
        let mixerIngressEpoch = mixerIngress.open(
            onAudioOverflow: { [weak self] identifier in
                guard let self else {
                    return
                }
                overflowFailureScheduler {
                    await self.recordTerminalFailure(
                        Error.audioIngressOverflow,
                        mixerIngressEpochIdentifier: identifier,
                        codecEpoch: codecEpoch
                    )
                }
            },
            onVideoOverflow: { [weak self] identifier in
                guard let self else {
                    return
                }
                overflowFailureScheduler {
                    await self.recordTerminalFailure(
                        Error.videoIngressOverflow,
                        mixerIngressEpochIdentifier: identifier,
                        codecEpoch: codecEpoch
                    )
                }
            }
        )
        self.mixerIngressEpoch = mixerIngressEpoch
        outgoing.startRunning()

        mixerAudioInputTask = Task { [weak self] in
            for await input in mixerIngressEpoch.audioStream {
                do {
                    try await self?.appendAdmitted(input.buffer, when: input.when)
                } catch {
                    await self?.recordTerminalFailure(
                        error,
                        codecEpoch: codecEpoch
                    )
                    break
                }
            }
        }
        mixerVideoInputTask = Task { [weak self] in
            for await sampleBuffer in mixerIngressEpoch.videoStream {
                do {
                    try await self?.encodeVideo(sampleBuffer)
                } catch {
                    await self?.recordTerminalFailure(
                        error,
                        codecEpoch: codecEpoch
                    )
                    break
                }
            }
        }
        audioOutputTask = Task { [weak self] in
            for await (buffer, when) in audioOutputStream {
                guard
                    let compressedBuffer = buffer as? AVAudioCompressedBuffer else {
                    await self?.recordTerminalFailure(
                        Error.encodedAudioOutputIsNotCompressed,
                        codecEpoch: codecEpoch
                    )
                    break
                }
                guard let sampleBuffer = audioSampleBufferFactory(compressedBuffer, when) else {
                    await self?.recordTerminalFailure(
                        Error.failedToCreateCompressedAudioSampleBuffer,
                        codecEpoch: codecEpoch
                    )
                    break
                }
                await self?.didEncode(sampleBuffer, codecEpoch: codecEpoch)
            }
        }
        videoOutputTask = Task { [weak self] in
            for await sampleBuffer in videoOutputStream {
                await self?.didEncode(sampleBuffer, codecEpoch: codecEpoch)
            }
        }
        videoTerminalFailureTask = Task { [weak self] in
            for await error in videoTerminalFailureStream {
                await self?.recordTerminalFailure(
                    error,
                    codecEpoch: codecEpoch
                )
                break
            }
        }
        lifecycle = .running
    }

    public func requestVideoKeyFrame() {
        guard lifecycle == .running else {
            return
        }
        outgoing.requestVideoKeyFrame()
    }

    /// Requests a video key frame and returns the delivery-sequence fence that
    /// precedes the requested frame.
    ///
    /// The request and the fanout snapshot execute in one actor turn. Encoded
    /// output accepted by this pipeline also reaches the fanout through this
    /// actor, so no accepted output can be interleaved between the outgoing
    /// request and the snapshot. Output accepted after this method returns is
    /// processed in a later actor turn and receives a greater sequence.
    public func requestVideoKeyFrameAndCaptureDeliverySequence() throws -> UInt64 {
        guard lifecycle == .running, let fanout else {
            throw Error.keyFrameFenceUnavailable
        }
        outgoing.requestVideoKeyFrame()
        guard let deliverySequence = fanout.currentDeliverySequenceSnapshot() else {
            throw Error.keyFrameFenceUnavailable
        }
        return deliverySequence
    }

    public func stopEncoding() async throws {
        let task: Task<Void, any Swift.Error>
        switch lifecycle {
        case .running:
            guard let codecEpoch = activeCodecEpoch else {
                return
            }
            lifecycle = .stopping
            let stoppingTaskBarrier = testHooks.stoppingTaskBarrier
            let newTask: Task<Void, any Swift.Error> = Task { [weak self] in
                await stoppingTaskBarrier()
                guard let self else {
                    return
                }
                try await self.finishStopping(codecEpoch: codecEpoch)
            }
            stoppingTask = newTask
            task = newTask
        case .stopping:
            guard let stoppingTask else {
                return
            }
            testHooks.didJoinStoppingTask()
            task = stoppingTask
        case .idle:
            if let completedTerminalFailure {
                throw completedTerminalFailure
            }
            return
        case .starting:
            return
        }
        try await task.value
    }

    private func finishStopping(codecEpoch: UUID) async throws {
        guard activeCodecEpoch == codecEpoch else {
            return
        }
        let stoppingMixerIngressEpoch = mixerIngressEpoch
        let stoppingMixerAudioInputTask = mixerAudioInputTask
        let stoppingMixerVideoInputTask = mixerVideoInputTask
        let stoppingAudioOutputTask = audioOutputTask
        let stoppingVideoOutputTask = videoOutputTask
        let stoppingVideoTerminalFailureTask = videoTerminalFailureTask
        let stoppingFanout = fanout
        self.stoppingFanout = stoppingFanout
        mixerIngressEpoch = nil
        mixerAudioInputTask = nil
        mixerVideoInputTask = nil
        audioOutputTask = nil
        videoOutputTask = nil
        videoTerminalFailureTask = nil
        fanout = nil

        if let stoppingMixerIngressEpoch {
            mixerIngress.close(stoppingMixerIngressEpoch)
        }
        let ingressError = stoppingMixerIngressEpoch?.consumeOverflowFailure()
        await stoppingMixerAudioInputTask?.value
        await stoppingMixerVideoInputTask?.value
        let drainError: (any Swift.Error)?
        do {
            try await outgoing.stopRunningAndDrain()
            drainError = nil
        } catch {
            drainError = error
        }
        await stoppingVideoTerminalFailureTask?.value
        await stoppingAudioOutputTask?.value
        await stoppingVideoOutputTask?.value
        await stoppingFanout?.finishAndWait()
        let outputError = outputFailure.consume(codecEpoch)
        if self.stoppingFanout === stoppingFanout {
            self.stoppingFanout = nil
        }
        let encodingError = terminalFailure
        terminalFailure = nil
        let stopError = encodingError ?? ingressError ?? outputError ?? drainError
        completedTerminalFailure = stopError
        stoppingTask = nil
        if activeCodecEpoch == codecEpoch {
            activeCodecEpoch = nil
        }
        lifecycle = .idle
        if let stopError {
            throw stopError
        }
    }

    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(
        _ mixer: MediaMixer,
        didOutput sampleBuffer: CMSampleBuffer
    ) {
        mixerIngress.append(sampleBuffer)
    }

    nonisolated public func mixer(
        _ mixer: MediaMixer,
        didOutput buffer: AVAudioPCMBuffer,
        when: AVAudioTime
    ) {
        mixerIngress.append(buffer, when: when)
    }

    package nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        mixerIngress.append(sampleBuffer)
    }

    package nonisolated func append(_ buffer: AVAudioBuffer, when: AVAudioTime) {
        guard let buffer = buffer as? AVAudioPCMBuffer else {
            return
        }
        mixerIngress.append(buffer, when: when)
    }

    private func appendAdmitted(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) throws {
        try outgoing.appendEncodedAudio(buffer, when: when)
    }

    private func encodeVideo(_ sampleBuffer: CMSampleBuffer) throws {
        try outgoing.appendEncodedVideo(sampleBuffer)
    }

    private func didEncode(_ sampleBuffer: CMSampleBuffer, codecEpoch: UUID) {
        guard activeCodecEpoch == codecEpoch else {
            return
        }
        (fanout ?? stoppingFanout)?.enqueue(sampleBuffer)
    }

    private func recordTerminalFailure(
        _ error: any Swift.Error,
        codecEpoch: UUID
    ) {
        guard
            activeCodecEpoch == codecEpoch,
            terminalFailure == nil else {
            return
        }
        terminalFailure = error
        if let mixerIngressEpoch {
            mixerIngress.close(mixerIngressEpoch)
        }
        automaticStopTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.stopEncodingIfCurrent(codecEpoch)
        }
    }

    package nonisolated func reportOutputFailure(
        _ error: any Swift.Error,
        codecEpoch: UUID
    ) {
        guard outputFailure.record(error, codecEpoch: codecEpoch) else {
            return
        }
        overflowFailureScheduler { [weak self] in
            await self?.recordTerminalFailure(
                error,
                codecEpoch: codecEpoch
            )
        }
    }

    private func stopEncodingIfCurrent(_ codecEpoch: UUID) async {
        guard activeCodecEpoch == codecEpoch else {
            return
        }
        do {
            try await stopEncoding()
        } catch {
            // The terminal failure is retained by stopEncoding() for the caller.
        }
    }

    private func recordTerminalFailure(
        _ error: any Swift.Error,
        mixerIngressEpochIdentifier: UUID,
        codecEpoch: UUID
    ) {
        guard
            activeCodecEpoch == codecEpoch,
            mixerIngressEpoch?.identifier == mixerIngressEpochIdentifier else {
            return
        }
        recordTerminalFailure(error, codecEpoch: codecEpoch)
    }
}

private final class EncodedMediaPipelineFailureLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var codecEpoch: UUID?
    private var failure: (any Swift.Error)?

    func begin(_ codecEpoch: UUID) {
        lock.withLock {
            self.codecEpoch = codecEpoch
            failure = nil
        }
    }

    @discardableResult
    func record(
        _ error: any Swift.Error,
        codecEpoch: UUID
    ) -> Bool {
        lock.withLock {
            guard self.codecEpoch == codecEpoch, failure == nil else {
                return false
            }
            failure = error
            return true
        }
    }

    func consume(_ codecEpoch: UUID) -> (any Swift.Error)? {
        lock.withLock {
            guard self.codecEpoch == codecEpoch else {
                return nil
            }
            let failure = self.failure
            self.failure = nil
            self.codecEpoch = nil
            return failure
        }
    }
}

private final class EncodedMediaPipelineIngress: @unchecked Sendable {
    struct AudioInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let when: AVAudioTime
    }

    struct Epoch: @unchecked Sendable {
        fileprivate let identifier: UUID
        fileprivate let state: EpochState
        let audioStream: AsyncStream<AudioInput>
        let videoStream: AsyncStream<CMSampleBuffer>

        fileprivate func consumeOverflowFailure() -> (any Swift.Error)? {
            state.consumeOverflowFailure()
        }
    }

    private struct ActiveEpoch {
        let identifier: UUID
        let state: EpochState
        let audioContinuation: AsyncStream<AudioInput>.Continuation
        let videoContinuation: AsyncStream<CMSampleBuffer>.Continuation
        let onAudioOverflow: @Sendable (UUID) -> Void
        let onVideoOverflow: @Sendable (UUID) -> Void
    }

    private let configuration: EncodedMediaPipelineIngressConfiguration
    private let lock = NSLock()
    private var activeEpoch: ActiveEpoch?

    fileprivate final class EpochState: @unchecked Sendable {
        private let lock = NSLock()
        private var overflowFailure: (any Swift.Error)?

        func recordOverflowFailure(_ error: any Swift.Error) {
            lock.withLock {
                guard overflowFailure == nil else {
                    return
                }
                overflowFailure = error
            }
        }

        func consumeOverflowFailure() -> (any Swift.Error)? {
            lock.withLock {
                let overflowFailure = self.overflowFailure
                self.overflowFailure = nil
                return overflowFailure
            }
        }
    }

    init(configuration: EncodedMediaPipelineIngressConfiguration) {
        self.configuration = configuration
    }

    func open(
        onAudioOverflow: @escaping @Sendable (UUID) -> Void,
        onVideoOverflow: @escaping @Sendable (UUID) -> Void
    ) -> Epoch {
        lock.withLock {
            let identifier = UUID()
            let state = EpochState()
            var audioContinuation: AsyncStream<AudioInput>.Continuation!
            let audioStream = AsyncStream<AudioInput>(
                bufferingPolicy: .bufferingOldest(configuration.audioCapacity)
            ) {
                audioContinuation = $0
            }
            var videoContinuation: AsyncStream<CMSampleBuffer>.Continuation!
            let videoStream = AsyncStream<CMSampleBuffer>(
                bufferingPolicy: .bufferingOldest(configuration.videoCapacity)
            ) {
                videoContinuation = $0
            }
            activeEpoch = ActiveEpoch(
                identifier: identifier,
                state: state,
                audioContinuation: audioContinuation,
                videoContinuation: videoContinuation,
                onAudioOverflow: onAudioOverflow,
                onVideoOverflow: onVideoOverflow
            )
            return Epoch(
                identifier: identifier,
                state: state,
                audioStream: audioStream,
                videoStream: videoStream
            )
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        let overflow: (handler: @Sendable (UUID) -> Void, identifier: UUID)? = lock.withLock {
            guard let activeEpoch else {
                return nil
            }
            guard case .dropped = activeEpoch.videoContinuation.yield(sampleBuffer) else {
                return nil
            }
            activeEpoch.state.recordOverflowFailure(
                EncodedMediaPipeline.Error.videoIngressOverflow
            )
            activeEpoch.audioContinuation.finish()
            activeEpoch.videoContinuation.finish()
            self.activeEpoch = nil
            return (activeEpoch.onVideoOverflow, activeEpoch.identifier)
        }
        if let overflow {
            overflow.handler(overflow.identifier)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let overflow: (handler: @Sendable (UUID) -> Void, identifier: UUID)? = lock.withLock {
            guard let activeEpoch else {
                return nil
            }
            guard case .dropped = activeEpoch.audioContinuation.yield(
                .init(buffer: buffer, when: when)
            ) else {
                return nil
            }
            activeEpoch.state.recordOverflowFailure(
                EncodedMediaPipeline.Error.audioIngressOverflow
            )
            activeEpoch.audioContinuation.finish()
            activeEpoch.videoContinuation.finish()
            self.activeEpoch = nil
            return (activeEpoch.onAudioOverflow, activeEpoch.identifier)
        }
        if let overflow {
            overflow.handler(overflow.identifier)
        }
    }

    func close(_ epoch: Epoch) {
        lock.withLock {
            guard activeEpoch?.identifier == epoch.identifier else {
                return
            }
            activeEpoch?.audioContinuation.finish()
            activeEpoch?.videoContinuation.finish()
            activeEpoch = nil
        }
    }
}
