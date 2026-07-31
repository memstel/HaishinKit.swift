@preconcurrency import AVFAudio
import AVFoundation
import Combine
import HaishinKit

#if canImport(UIKit)
import UIKit
typealias View = UIView
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
typealias View = NSView
#endif

package struct RTMPPublishSessionState: Sendable {
    package struct Token: Sendable, Equatable {
        fileprivate let generation: UInt64
    }

    package enum CancellationDisposition: Sendable, Equatable {
        case noReservedStart
        case joinReservedStart
    }

    package private(set) var activeToken: Token?
    private var generation: UInt64 = 0
    private var isCancelled = false
    private var isPipelineStartReserved = false
    private var isPipelineTerminalExpected = false
    private var isPublishStartPending = false

    package mutating func begin() -> Token {
        precondition(activeToken == nil)
        generation &+= 1
        let token = Token(generation: generation)
        activeToken = token
        isCancelled = false
        isPipelineStartReserved = false
        isPipelineTerminalExpected = false
        isPublishStartPending = true
        return token
    }

    package func permitsProgress(_ token: Token) -> Bool {
        activeToken == token && !isCancelled
    }

    package func isCancelled(_ token: Token) -> Bool {
        activeToken == token && isCancelled
    }

    package var isLifecycleTransitionInProgress: Bool {
        activeToken != nil && (isCancelled || isPipelineStartReserved || isPublishStartPending)
    }

    package mutating func reservePipelineStart(_ token: Token) -> Bool {
        guard permitsProgress(token), !isPipelineStartReserved else {
            return false
        }
        isPipelineStartReserved = true
        return true
    }

    package mutating func completePipelineStart(_ token: Token) -> Bool {
        guard permitsProgress(token), isPipelineStartReserved else {
            return false
        }
        isPipelineStartReserved = false
        isPublishStartPending = false
        return true
    }

    @discardableResult
    package mutating func cancel(
        _ token: Token,
        expectsPipelineTerminal: Bool
    ) -> CancellationDisposition? {
        guard activeToken == token else {
            return nil
        }
        isCancelled = true
        if expectsPipelineTerminal {
            isPipelineTerminalExpected = true
        }
        return isPipelineStartReserved ? .joinReservedStart : .noReservedStart
    }

    package mutating func handlePipelineTerminal(_ token: Token) -> Bool {
        guard activeToken == token, !isPipelineTerminalExpected else {
            return false
        }
        isCancelled = true
        isPipelineTerminalExpected = true
        return true
    }

    package mutating func finish(_ token: Token) {
        guard activeToken == token else {
            return
        }
        activeToken = nil
        isCancelled = false
        isPipelineStartReserved = false
        isPipelineTerminalExpected = false
        isPublishStartPending = false
    }
}

package struct RTMPTeardownState: Sendable {
    package enum Operation: Sendable, Equatable {
        case close
        case delete
    }

    package struct Token: Sendable, Equatable {
        fileprivate let generation: UInt64
        fileprivate let operation: Operation
    }

    package private(set) var activeToken: Token?
    private var generation: UInt64 = 0

    package mutating func begin(_ operation: Operation) -> Token? {
        guard activeToken == nil else {
            return nil
        }
        generation &+= 1
        activeToken = Token(generation: generation, operation: operation)
        return activeToken
    }

    package func matches(_ token: Token) -> Bool {
        activeToken == token
    }

    @discardableResult
    package mutating func finish(_ token: Token) -> Bool {
        guard activeToken == token else {
            return false
        }
        activeToken = nil
        return true
    }
}

private struct RTMPCommandRequestState {
    enum Operation: Equatable {
        case play
        case publish(RTMPPublishSessionState.Token)
        case pause
    }

    struct Token: Equatable {
        fileprivate let generation: UInt64
        fileprivate let operation: Operation
    }

    private(set) var activeToken: Token?
    private var generation: UInt64 = 0

    mutating func begin(_ operation: Operation) -> Token? {
        guard activeToken == nil else {
            return nil
        }
        generation &+= 1
        let token = Token(generation: generation, operation: operation)
        activeToken = token
        return token
    }

    func matches(_ token: Token) -> Bool {
        activeToken == token
    }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard activeToken == token else {
            return false
        }
        activeToken = nil
        return true
    }
}

package enum RTMPEncodedMediaOutputError: Swift.Error {
    case invalidVideoTimestamp
    case invalidAudioTimestamp
    case failedToCreateVideoSequenceHeader
    case failedToCreateAudioSequenceHeader
    case failedToCreateVideoMessage
    case failedToCreateAudioMessage
}

/// An object that provides the interface to control a one-way channel over an RTMPConnection.
public actor RTMPStream {
    /// The error domain code.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
        /// The requested operation timed out.
        case requestTimedOut
        /// A request fails.
        case requestFailed(response: RTMPResponse)
        /// An unsupported codec.
        case unsupportedCodec
    }

    /// NetStatusEvent#info.code for NetStream
    /// - seealso: https://help.adobe.com/en_US/air/reference/html/flash/events/NetStatusEvent.html#NET_STATUS
    public enum Code: String {
        case bufferEmpty               = "NetStream.Buffer.Empty"
        case bufferFlush               = "NetStream.Buffer.Flush"
        case bufferFull                = "NetStream.Buffer.Full"
        case connectClosed             = "NetStream.Connect.Closed"
        case connectFailed             = "NetStream.Connect.Failed"
        case connectRejected           = "NetStream.Connect.Rejected"
        case connectSuccess            = "NetStream.Connect.Success"
        case drmUpdateNeeded           = "NetStream.DRM.UpdateNeeded"
        case failed                    = "NetStream.Failed"
        case multicastStreamReset      = "NetStream.MulticastStream.Reset"
        case pauseNotify               = "NetStream.Pause.Notify"
        case playFailed                = "NetStream.Play.Failed"
        case playFileStructureInvalid  = "NetStream.Play.FileStructureInvalid"
        case playInsufficientBW        = "NetStream.Play.InsufficientBW"
        case playNoSupportedTrackFound = "NetStream.Play.NoSupportedTrackFound"
        case playReset                 = "NetStream.Play.Reset"
        case playStart                 = "NetStream.Play.Start"
        case playStop                  = "NetStream.Play.Stop"
        case playStreamNotFound        = "NetStream.Play.StreamNotFound"
        case playTransition            = "NetStream.Play.Transition"
        case playUnpublishNotify       = "NetStream.Play.UnpublishNotify"
        case publishBadName            = "NetStream.Publish.BadName"
        case publishIdle               = "NetStream.Publish.Idle"
        case publishStart              = "NetStream.Publish.Start"
        case recordAlreadyExists       = "NetStream.Record.AlreadyExists"
        case recordFailed              = "NetStream.Record.Failed"
        case recordNoAccess            = "NetStream.Record.NoAccess"
        case recordStart               = "NetStream.Record.Start"
        case recordStop                = "NetStream.Record.Stop"
        case recordDiskQuotaExceeded   = "NetStream.Record.DiskQuotaExceeded"
        case secondScreenStart         = "NetStream.SecondScreen.Start"
        case secondScreenStop          = "NetStream.SecondScreen.Stop"
        case seekFailed                = "NetStream.Seek.Failed"
        case seekInvalidTime           = "NetStream.Seek.InvalidTime"
        case seekNotify                = "NetStream.Seek.Notify"
        case stepNotify                = "NetStream.Step.Notify"
        case unpauseNotify             = "NetStream.Unpause.Notify"
        case unpublishSuccess          = "NetStream.Unpublish.Success"
        case videoDimensionChange      = "NetStream.Video.DimensionChange"

        public var level: String {
            switch self {
            case .bufferEmpty:
                return "status"
            case .bufferFlush:
                return "status"
            case .bufferFull:
                return "status"
            case .connectClosed:
                return "status"
            case .connectFailed:
                return "error"
            case .connectRejected:
                return "error"
            case .connectSuccess:
                return "status"
            case .drmUpdateNeeded:
                return "status"
            case .failed:
                return "error"
            case .multicastStreamReset:
                return "status"
            case .pauseNotify:
                return "status"
            case .playFailed:
                return "error"
            case .playFileStructureInvalid:
                return "error"
            case .playInsufficientBW:
                return "warning"
            case .playNoSupportedTrackFound:
                return "status"
            case .playReset:
                return "status"
            case .playStart:
                return "status"
            case .playStop:
                return "status"
            case .playStreamNotFound:
                return "error"
            case .playTransition:
                return "status"
            case .playUnpublishNotify:
                return "status"
            case .publishBadName:
                return "error"
            case .publishIdle:
                return "status"
            case .publishStart:
                return "status"
            case .recordAlreadyExists:
                return "status"
            case .recordFailed:
                return "error"
            case .recordNoAccess:
                return "error"
            case .recordStart:
                return "status"
            case .recordStop:
                return "status"
            case .recordDiskQuotaExceeded:
                return "error"
            case .secondScreenStart:
                return "status"
            case .secondScreenStop:
                return "status"
            case .seekFailed:
                return "error"
            case .seekInvalidTime:
                return "error"
            case .seekNotify:
                return "status"
            case .stepNotify:
                return "status"
            case .unpauseNotify:
                return "status"
            case .unpublishSuccess:
                return "status"
            case .videoDimensionChange:
                return "status"
            }
        }

        func status(_ description: String) -> RTMPStatus {
            return .init(code: rawValue, level: level, description: description)
        }
    }

    /// The type of publish options.
    public enum HowToPublish: String, Sendable {
        /// Publish with server-side recording.
        case record
        /// Publish with server-side recording which is to append file if exists.
        case append
        /// Publish with server-side recording which is to append and ajust time file if exists.
        case appendWithGap
        /// Publish.
        case live
    }

    static let defaultID: UInt32 = 0
    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac, .opus]
    static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases
    package static let encodedMediaOutputIngressPolicy = EncodedMediaOutputIngressPolicy.authoritative

    /// The RTMPStream metadata.
    public private(set) var metadata: AMFArray = .init(count: 0)
    /// The RTMPStreamInfo object whose properties contain data.
    public private(set) var info = RTMPStreamInfo()
    /// The object encoding (AMF). Framework supports AMF0 only.
    public private(set) var objectEncoding = RTMPConnection.defaultObjectEncoding
    /// The boolean value that indicates audio samples allow access or not.
    public private(set) var audioSampleAccess = true
    /// The boolean value that indicates video samples allow access or not.
    public private(set) var videoSampleAccess = true
    /// The number of video frames per seconds.
    @Published public private(set) var currentFPS: UInt16 = 0
    /// The ready state of stream.
    @Published public private(set) var readyState: StreamReadyState = .idle
    /// The stream of events you receive RTMP status events from a service.
    public var status: AsyncStream<RTMPStatus> {
        AsyncStream { continuation in
            statusContinuation = continuation
        }
    }
    /// The stream's name used for FMLE-compatible sequences.
    public private(set) var fcPublishName: String?

    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max

    private var isPaused = false
    private var startedAt = Date() {
        didSet {
            dataTimestamps.removeAll()
        }
    }
    package var outputs: [any StreamOutput] = []
    private var encodedOutputs: [any RTMPEncodedStreamOutput] = []
    private var frameCount: UInt16 = 0
    private var audioBuffer: AVAudioCompressedBuffer?
    private var howToPublish: RTMPStream.HowToPublish = .live
    private var commandRequestState = RTMPCommandRequestState()
    private var commandExpectedResponse: Code?
    private var commandContinuation:
        CheckedContinuation<RTMPResponse, any Swift.Error>?
    private var commandTimeoutTask: Task<Void, Never>?
    private var dataTimestamps: [String: Date] = .init()
    private var audioTimestamp: RTMPTimestamp<AVAudioTime> = .init()
    private var outboundAudioTimestamp: RTMPTimestamp<CMTime> = .init()
    private var videoTimestamp: RTMPTimestamp<CMTime> = .init()
    private var requestTimeout = RTMPConnection.defaultRequestTimeout
    private var isWireSessionReusable = true
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    private var statusContinuation: AsyncStream<RTMPStatus>.Continuation?
    private(set) var id: UInt32 = RTMPStream.defaultID
    package lazy var incoming = IncomingStream(self)
    package let outgoing: OutgoingStream
    private let encodedMediaPipeline: EncodedMediaPipeline
    private lazy var encodedMediaOutput = RTMPStreamEncodedMediaOutput(stream: self)
    private var publishSessionState = RTMPPublishSessionState()
    private var publishPipelineStartTask: (
        token: RTMPPublishSessionState.Token,
        task: Task<Void, any Swift.Error>
    )?
    private var teardownState = RTMPTeardownState()
    private var teardownOperation: RTMPTeardownState.Operation?
    private var teardownPublishToken: RTMPPublishSessionState.Token?
    private var teardownExpectedResponse: Code?
    private var teardownContinuation: CheckedContinuation<RTMPResponse, any Swift.Error>?
    private var teardownTimeoutTask: Task<Void, Never>?
    private var outputMessageHandlerForTesting:
        (@Sendable (UInt8, UInt32, Data) -> Void)?
    private var encodedMediaDeliveryBarrierForTesting:
        (@Sendable () async -> Void)?
    private var encodedPipelineAudioHeaderFactory:
        (UInt32, UInt32, CMFormatDescription?) -> RTMPAudioMessage? = {
            RTMPAudioMessage(
                streamId: $0,
                timestamp: $1,
                formatDescription: $2
            )
        }
    private var encodedPipelineVideoHeaderFactory:
        (UInt32, UInt32, CMFormatDescription?) -> RTMPVideoMessage? = {
            RTMPVideoMessage(
                streamId: $0,
                timestamp: $1,
                formatDescription: $2
            )
        }
    private var isApplyingEncodedPipelineAudioFormat = false
    private var isApplyingEncodedPipelineVideoFormat = false
    private let rawMixerOutputDispatcher = RTMPRawMixerOutputDispatcher()
    private weak var connection: RTMPConnection?

    private var audioFormat: AVAudioFormat? {
        didSet {
            guard
                audioFormat != oldValue,
                !isApplyingEncodedPipelineAudioFormat else {
                return
            }
            switch readyState {
            case .publishing:
                guard let message = RTMPAudioMessage(streamId: id, timestamp: 0, formatDescription: audioFormat?.formatDescription) else {
                    return
                }
                doOutput(oldValue == nil ? .zero : .one, chunkStreamId: .audio, message: message)
            case .playing:
                if let audioFormat {
                    audioBuffer = AVAudioCompressedBuffer(format: audioFormat, packetCapacity: 1, maximumPacketSize: 1024 * Int(audioFormat.channelCount))
                } else {
                    audioBuffer = nil
                }
            default:
                break
            }
        }
    }

    private var videoFormat: CMFormatDescription? {
        didSet {
            guard
                videoFormat != oldValue,
                !isApplyingEncodedPipelineVideoFormat else {
                return
            }
            switch readyState {
            case .publishing:
                guard let message = RTMPVideoMessage(streamId: id, timestamp: 0, formatDescription: videoFormat) else {
                    return
                }
                doOutput(oldValue == nil ? .zero : .one, chunkStreamId: .video, message: message)
            default:
                break
            }
        }
    }

    /// Creates a new stream.
    public init(connection: RTMPConnection, fcPublishName: String? = nil) {
        let outgoing = OutgoingStream()
        self.connection = connection
        self.fcPublishName = fcPublishName
        self.requestTimeout = connection.requestTimeout
        self.outgoing = outgoing
        self.encodedMediaPipeline = EncodedMediaPipeline(outgoing: outgoing)
        Task {
            await connection.addStream(self)
            if await connection.connected {
                await createStream()
            }
        }
    }

    deinit {
        outputs.removeAll()
        encodedOutputs.removeAll()
    }

    /// Plays a live stream from a server.
    public func play(_ arguments: (any Sendable)?...) async throws -> RTMPResponse {
        guard let name = arguments.first as? String else {
            switch readyState {
            case .playing:
                info.resourceName = nil
                return try await close()
            default:
                throw Error.invalidState
            }
        }
        guard
            isWireSessionReusable,
            readyState == .idle,
            commandRequestState.activeToken == nil,
            publishSessionState.activeToken == nil,
            teardownState.activeToken == nil else {
            throw Error.invalidState
        }
        do {
            audioFormat = nil
            videoFormat = nil
            let response = try await withCheckedThrowingContinuation { continuation in
                readyState = .play
                guard let commandToken = beginCommandRequest(
                    .play,
                    expectedResponse: .playStart,
                    continuation: continuation
                ) else {
                    readyState = .idle
                    continuation.resume(throwing: Error.invalidState)
                    return
                }
                Task { [weak self] in
                    await self?.incoming.startRunning()
                    await self?.scheduleCommandTimeout(commandToken)
                }
                doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                    streamId: id,
                    transactionId: 0,
                    objectEncoding: objectEncoding,
                    commandName: "play",
                    commandObject: nil,
                    arguments: arguments
                ))
            }
            startedAt = .init()
            readyState = .playing
            info.resourceName = name
            return response
        } catch {
            Task { await incoming.stopRunning() }
            outgoing.stopRunning()
            readyState = .idle
            throw error
        }
    }

    /// Seeks the keyframe.
    public func seek(_ offset: Double) async throws {
        guard readyState == .playing else {
            throw Error.invalidState
        }
        doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
            streamId: id,
            transactionId: 0,
            objectEncoding: objectEncoding,
            commandName: "seek",
            commandObject: nil,
            arguments: [offset]
        ))
    }

    /// Sends streaming audio, vidoe and data message from client.
    public func publish(_ name: String?, type: RTMPStream.HowToPublish = .live) async throws -> RTMPResponse {
        guard let name else {
            switch readyState {
            case .publishing:
                return try await close()
            default:
                throw Error.invalidState
            }
        }
        guard publishSessionState.activeToken == nil else {
            throw Error.invalidState
        }
        guard
            isWireSessionReusable,
            readyState == .idle,
            commandRequestState.activeToken == nil,
            teardownState.activeToken == nil else {
            throw Error.invalidState
        }
        let publishToken = beginPublishSession()
        do {
            audioFormat = nil
            videoFormat = nil
            let response = try await withCheckedThrowingContinuation { continuation in
                readyState = .publish
                guard let commandToken = beginCommandRequest(
                    .publish(publishToken),
                    expectedResponse: .publishStart,
                    continuation: continuation
                ) else {
                    readyState = .idle
                    continuation.resume(throwing: Error.invalidState)
                    return
                }
                scheduleCommandTimeout(commandToken)
                doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                    streamId: id,
                    transactionId: 0,
                    objectEncoding: objectEncoding,
                    commandName: "publish",
                    commandObject: nil,
                    arguments: [name, type.rawValue]
                ))
            }
            try requirePublishSessionProgress(publishToken)
            info.resourceName = name
            howToPublish = type
            startedAt = .init()
            audioTimestamp.clear()
            outboundAudioTimestamp.clear()
            videoTimestamp.clear()
            metadata = makeMetadata()
            readyState = .publishing
            try? send("@setDataFrame", arguments: "onMetaData", metadata)
            guard publishSessionState.reservePipelineStart(publishToken) else {
                throw Error.invalidState
            }
            await encodedMediaPipeline.addOutput(
                encodedMediaOutput,
                ingressPolicy: Self.encodedMediaOutputIngressPolicy
            )
            try requirePublishSessionProgress(publishToken)
            let pipelineStartTask = Task { [encodedMediaPipeline] in
                try await encodedMediaPipeline.startEncoding()
            }
            publishPipelineStartTask = (publishToken, pipelineStartTask)
            try await pipelineStartTask.value
            guard publishSessionState.activeToken == publishToken else {
                throw Error.invalidState
            }
            guard publishSessionState.completePipelineStart(publishToken) else {
                throw Error.invalidState
            }
            if publishPipelineStartTask?.token == publishToken {
                publishPipelineStartTask = nil
            }
            try requirePublishSessionProgress(publishToken)
            return response
        } catch {
            if
                publishSessionState.activeToken == publishToken,
                !publishSessionState.isCancelled(publishToken) {
                await stopPublishingPipeline(publishToken)
                finishPublishSession(publishToken)
                readyState = .idle
            }
            throw error
        }
    }

    /// Stops playing or publishing and makes available other uses.
    public func close() async throws -> RTMPResponse {
        let closingReadyState = readyState
        guard
            teardownState.activeToken == nil,
            closingReadyState == .playing ||
            closingReadyState == .publishing ||
            (
                closingReadyState == .publish &&
                publishSessionState.activeToken != nil
            ) else {
            throw Error.invalidState
        }
        let expectedResponse: Code = closingReadyState == .playing
            ? .playStop
            : .unpublishSuccess
        guard let teardownToken = beginTeardown(
            .close,
            publishToken: publishSessionState.activeToken,
            expectedResponse: expectedResponse
        ) else {
            throw Error.invalidState
        }
        if let publishToken = teardownPublishToken {
            if closingReadyState == .publish {
                cancelPendingPublishResponse(publishToken)
            }
            guard await stopPublishingPipeline(publishToken), teardownState.matches(teardownToken) else {
                completeTeardown(
                    teardownToken,
                    result: .failure(Error.invalidState)
                )
                throw Error.invalidState
            }
        } else {
            cancelPendingCommandIfNeeded()
            await incoming.stopRunning()
        }
        return try await awaitTeardownResponse(teardownToken)
    }

    /// Sends a message on a published stream to all subscribing clients.
    ///
    /// ```
    /// // To add a metadata to a live stream sent to an RTMP Service.
    /// stream.send("@setDataFrame", "onMetaData", metaData)
    /// // To clear a metadata that has already been set in the stream.
    /// stream.send("@clearDataFrame", "onMetaData");
    /// ```
    ///
    /// - Parameters:
    ///   - handlerName: The message to send.
    ///   - arguments: Optional arguments.
    ///   - isResetTimestamp: A workaround option for sending timestamps as 0 in some services.
    public func send(_ handlerName: String, arguments: (any Sendable)?..., isResetTimestamp: Bool = false) throws {
        guard readyState == .publishing, teardownState.activeToken == nil else {
            throw Error.invalidState
        }
        if isResetTimestamp {
            dataTimestamps[handlerName] = nil
        }
        let dataWasSent = dataTimestamps[handlerName] == nil ? false : true
        let timestmap: UInt32 = dataWasSent ? UInt32((dataTimestamps[handlerName]?.timeIntervalSinceNow ?? 0) * -1000) : UInt32(startedAt.timeIntervalSinceNow * -1000)
        doOutput(
            dataWasSent ? RTMPChunkType.one : RTMPChunkType.zero,
            chunkStreamId: .data,
            message: RTMPDataMessage(
                streamId: id,
                objectEncoding: objectEncoding,
                timestamp: timestmap,
                handlerName: handlerName,
                arguments: arguments
            )
        )
        dataTimestamps[handlerName] = .init()
    }

    /// Incoming audio plays on a stream or not.
    public func receiveAudio(_ receiveAudio: Bool) async throws {
        guard readyState == .playing else {
            throw Error.invalidState
        }
        doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
            streamId: id,
            transactionId: 0,
            objectEncoding: objectEncoding,
            commandName: "receiveAudio",
            commandObject: nil,
            arguments: [receiveAudio]
        ))
    }

    /// Incoming video plays on a stream or not.
    public func receiveVideo(_ receiveVideo: Bool) async throws {
        guard readyState == .playing else {
            throw Error.invalidState
        }
        doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
            streamId: id,
            transactionId: 0,
            objectEncoding: objectEncoding,
            commandName: "receiveVideo",
            commandObject: nil,
            arguments: [receiveVideo]
        ))
    }

    /// Pauses playback a  stream or not.
    public func pause(_ paused: Bool) async throws -> RTMPResponse {
        guard
            isWireSessionReusable,
            readyState == .playing,
            commandRequestState.activeToken == nil,
            teardownState.activeToken == nil else {
            throw Error.invalidState
        }
        let response = try await withCheckedThrowingContinuation { continuation in
            guard let commandToken = beginCommandRequest(
                .pause,
                expectedResponse: paused ? .pauseNotify : .unpauseNotify,
                continuation: continuation
            ) else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            scheduleCommandTimeout(commandToken)
            doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                streamId: id,
                transactionId: 0,
                objectEncoding: objectEncoding,
                commandName: "pause",
                commandObject: nil,
                arguments: [paused, floor(startedAt.timeIntervalSinceNow * -1000)]
            ))
        }
        isPaused = paused
        return response
    }

    /// Pauses or resumes playback of a stream.
    public func togglePause() async throws -> RTMPResponse {
        try await pause(!isPaused)
    }

    func doOutput(_ type: RTMPChunkType, chunkStreamId: RTMPChunkStreamId, message: some RTMPMessage) {
        outputMessageHandlerForTesting?(message.type.rawValue, message.timestamp, message.payload)
        Task {
            let length = await connection?.doOutput(type, chunkStreamId: chunkStreamId, message: message) ?? 0
            info.byteCount += length
        }
    }

    func dispatch(_ message: some RTMPMessage, type: RTMPChunkType) {
        info.byteCount += message.payload.count
        switch message {
        case let message as RTMPCommandMessage:
            let response = RTMPResponse(message)
            switch message.commandName {
            case "onStatus":
                if
                    let teardownToken = teardownState.activeToken,
                    teardownContinuation != nil,
                    let code = response.status?.code,
                    teardownExpectedResponse?.rawValue == code {
                    completeTeardown(teardownToken, result: .success(response))
                    _ = response.status.map {
                        statusContinuation?.yield($0)
                    }
                    return
                }
                if
                    teardownState.activeToken != nil,
                    teardownContinuation != nil,
                    response.status?.level != "status" {
                    completeTeardown(
                        teardownState.activeToken!,
                        result: .failure(Error.requestFailed(response: response))
                    )
                    _ = response.status.map {
                        statusContinuation?.yield($0)
                    }
                    return
                }
                if let commandToken = commandRequestState.activeToken {
                    switch response.status?.level {
                    case "status":
                        // During playback, only NetStream.Play.Start is awaited, as it follows the next sequence.
                        // 1. NetStream.Play.Rest
                        // 2. NetStream.Play.Start
                        if
                            let code = response.status?.code,
                            commandExpectedResponse?.rawValue == code {
                            completeCommandRequest(
                                commandToken,
                                result: .success(response),
                                marksWireSessionUnusable: false
                            )
                        }
                    default:
                        completeCommandRequest(
                            commandToken,
                            result: .failure(Error.requestFailed(response: response)),
                            marksWireSessionUnusable: false
                        )
                    }
                }
                _ = response.status.map {
                    statusContinuation?.yield($0)
                }
            default:
                logger.info(message)
            }
        case let message as RTMPAudioMessage:
            append(message, type: type)
        case let message as RTMPVideoMessage:
            append(message, type: type)
        case let message as RTMPDataMessage:
            switch message.handlerName {
            case "onMetaData":
                metadata = message.arguments[0] as? AMFArray ?? .init(count: 0)
            case "|RtmpSampleAccess":
                audioSampleAccess = message.arguments[0] as? Bool ?? true
                videoSampleAccess = message.arguments[1] as? Bool ?? true
            default:
                break
            }
        case let message as RTMPUserControlMessage:
            switch message.event {
            case .bufferEmpty:
                statusContinuation?.yield(Code.bufferEmpty.status(""))
            case .bufferFull:
                statusContinuation?.yield(Code.bufferFull.status(""))
            default:
                break
            }
        default:
            break
        }
    }

    func createStream() async {
        if let fcPublishName {
            // FMLE-compatible sequences
            async let _ = connection?.call("releaseStream", arguments: fcPublishName)
            async let _ = connection?.call("FCPublish", arguments: fcPublishName)
        }
        do {
            let response = try await connection?.call("createStream")
            guard let first = response?.arguments.first as? Double else {
                return
            }
            id = UInt32(first)
            isWireSessionReusable = true
            readyState = .idle
        } catch {
            logger.error(error)
        }
    }

    func deleteStream() async {
        guard
            let fcPublishName,
            teardownState.activeToken == nil,
            readyState == .publish || readyState == .publishing,
            let publishToken = publishSessionState.activeToken else {
            return
        }
        guard let teardownToken = beginTeardown(
            .delete,
            publishToken: publishToken,
            expectedResponse: nil
        ) else {
            return
        }
        if readyState == .publish {
            cancelPendingPublishResponse(publishToken)
        }
        guard await stopPublishingPipeline(publishToken), teardownState.matches(teardownToken) else {
            completeTeardown(teardownToken, result: nil)
            return
        }
        let connection = self.connection
        async let fcUnpublish = try? connection?.call("FCUnpublish", arguments: fcPublishName)
        async let delete = try? connection?.call("deleteStream", arguments: id)
        _ = await fcUnpublish
        guard teardownState.matches(teardownToken) else {
            return
        }
        _ = await delete
        guard teardownState.matches(teardownToken) else {
            return
        }
        completeTeardown(teardownToken, result: nil)
    }

    private func beginTeardown(
        _ operation: RTMPTeardownState.Operation,
        publishToken: RTMPPublishSessionState.Token?,
        expectedResponse: Code?
    ) -> RTMPTeardownState.Token? {
        guard let token = teardownState.begin(operation) else {
            return nil
        }
        teardownOperation = operation
        teardownPublishToken = publishToken
        teardownExpectedResponse = expectedResponse
        return token
    }

    private func awaitTeardownResponse(
        _ token: RTMPTeardownState.Token
    ) async throws -> RTMPResponse {
        let requestTimeout = self.requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            guard teardownState.matches(token) else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            teardownContinuation = continuation
            teardownTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: requestTimeout * 1_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await self?.timeoutTeardown(token)
            }
            doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
                streamId: id,
                transactionId: 0,
                objectEncoding: objectEncoding,
                commandName: "closeStream",
                commandObject: nil,
                arguments: []
            ))
        }
    }

    private func timeoutTeardown(_ token: RTMPTeardownState.Token) {
        guard teardownState.matches(token) else {
            return
        }
        isWireSessionReusable = false
        completeTeardown(token, result: .failure(Error.requestTimedOut))
    }

    private func completeTeardown(
        _ token: RTMPTeardownState.Token,
        result: Result<RTMPResponse, any Swift.Error>?
    ) {
        guard teardownState.matches(token) else {
            return
        }
        teardownTimeoutTask?.cancel()
        teardownTimeoutTask = nil
        let continuation = teardownContinuation
        teardownContinuation = nil
        let publishToken = teardownPublishToken
        if let publishToken {
            finishPublishSession(publishToken)
        }
        if teardownOperation != nil {
            readyState = .idle
            info.resourceName = nil
        }
        teardownPublishToken = nil
        teardownExpectedResponse = nil
        teardownOperation = nil
        _ = teardownState.finish(token)
        if let result {
            continuation?.resume(with: result)
        }
    }

    private func beginPublishSession() -> RTMPPublishSessionState.Token {
        let token = publishSessionState.begin()
        encodedMediaOutput.beginSession(token)
        return token
    }

    private func requirePublishSessionProgress(
        _ token: RTMPPublishSessionState.Token
    ) throws {
        guard publishSessionState.permitsProgress(token) else {
            throw Error.invalidState
        }
    }

    private func beginCommandRequest(
        _ operation: RTMPCommandRequestState.Operation,
        expectedResponse: Code,
        continuation: CheckedContinuation<RTMPResponse, any Swift.Error>
    ) -> RTMPCommandRequestState.Token? {
        guard let token = commandRequestState.begin(operation) else {
            return nil
        }
        commandExpectedResponse = expectedResponse
        commandContinuation = continuation
        return token
    }

    private func scheduleCommandTimeout(
        _ token: RTMPCommandRequestState.Token
    ) {
        guard commandRequestState.matches(token) else {
            return
        }
        let requestTimeout = self.requestTimeout
        commandTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: requestTimeout * 1_000_000)
            guard !Task.isCancelled else {
                return
            }
            await self?.timeoutCommandRequest(token)
        }
    }

    private func timeoutCommandRequest(
        _ token: RTMPCommandRequestState.Token
    ) {
        completeCommandRequest(
            token,
            result: .failure(Error.requestTimedOut),
            marksWireSessionUnusable: true
        )
    }

    private func completeCommandRequest(
        _ token: RTMPCommandRequestState.Token,
        result: Result<RTMPResponse, any Swift.Error>,
        marksWireSessionUnusable: Bool
    ) {
        guard commandRequestState.matches(token) else {
            return
        }
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        let continuation = commandContinuation
        commandContinuation = nil
        commandExpectedResponse = nil
        _ = commandRequestState.finish(token)
        if marksWireSessionUnusable {
            isWireSessionReusable = false
        }
        continuation?.resume(with: result)
    }

    private func cancelPendingCommandIfNeeded() {
        guard let token = commandRequestState.activeToken else {
            return
        }
        completeCommandRequest(
            token,
            result: .failure(Error.invalidState),
            marksWireSessionUnusable: true
        )
    }

    private func timeoutPublishRequest(_ token: RTMPPublishSessionState.Token) {
        guard
            publishSessionState.permitsProgress(token),
            readyState == .publish,
            let commandToken = commandRequestState.activeToken,
            commandToken.operation == .publish(token) else {
            return
        }
        timeoutCommandRequest(commandToken)
    }

    private func cancelPendingPublishResponse(
        _ token: RTMPPublishSessionState.Token
    ) {
        guard
            publishSessionState.activeToken == token,
            readyState == .publish,
            let commandToken = commandRequestState.activeToken,
            commandToken.operation == .publish(token) else {
            return
        }
        _ = publishSessionState.cancel(
            token,
            expectsPipelineTerminal: true
        )
        completeCommandRequest(
            commandToken,
            result: .failure(Error.invalidState),
            marksWireSessionUnusable: true
        )
    }

    @discardableResult
    private func stopPublishingPipeline(
        _ token: RTMPPublishSessionState.Token
    ) async -> Bool {
        guard publishSessionState.activeToken == token else {
            return false
        }
        _ = publishSessionState.cancel(
            token,
            expectsPipelineTerminal: true
        )
        if
            let pipelineStartTask = publishPipelineStartTask,
            pipelineStartTask.token == token {
            _ = try? await pipelineStartTask.task.value
            guard publishSessionState.activeToken == token else {
                return false
            }
        }
        await encodedMediaPipeline.removeOutput(encodedMediaOutput)
        guard publishSessionState.activeToken == token else {
            return false
        }
        try? await encodedMediaPipeline.stopEncoding()
        guard publishSessionState.activeToken == token else {
            return false
        }
        await encodedMediaOutput.waitForIdle()
        return publishSessionState.activeToken == token
    }

    private func finishPublishSession(
        _ token: RTMPPublishSessionState.Token
    ) {
        if publishPipelineStartTask?.token == token {
            publishPipelineStartTask = nil
        }
        publishSessionState.finish(token)
        encodedMediaOutput.endSession(token)
    }

    private func append(_ message: RTMPAudioMessage, type: RTMPChunkType) {
        audioTimestamp.update(message, chunkType: type)
        guard message.codec.isSupported else {
            return
        }
        switch message.payload[1] {
        case RTMPAACPacketType.seq.rawValue:
            audioFormat = message.makeAudioFormat()
        case RTMPAACPacketType.raw.rawValue:
            if audioFormat == nil {
                audioFormat = message.makeAudioFormat()
            }
            if let audioBuffer {
                message.copyMemory(audioBuffer)
                Task { await incoming.append(audioBuffer, when: audioTimestamp.value) }
            }
        default:
            break
        }
    }

    private func append(_ message: RTMPVideoMessage, type: RTMPChunkType) {
        videoTimestamp.update(message, chunkType: type)
        guard RTMPTagType.video.headerSize <= message.payload.count && message.isSupported else {
            return
        }
        if message.isExHeader {
            // IsExHeader for Enhancing RTMP, FLV
            switch message.packetType {
            case RTMPVideoPacketType.sequenceStart.rawValue:
                videoFormat = message.makeFormatDescription()
            case RTMPVideoPacketType.codedFrames.rawValue:
                Task { await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat) }
            case RTMPVideoPacketType.codedFramesX.rawValue:
                Task { await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat) }
            default:
                break
            }
        } else {
            switch message.packetType {
            case RTMPAVCPacketType.seq.rawValue:
                videoFormat = message.makeFormatDescription()
            case RTMPAVCPacketType.nal.rawValue:
                Task { await incoming.append(message, presentationTimeStamp: videoTimestamp.value, formatDesciption: videoFormat) }
            default:
                break
            }
        }
    }

    /// Creates flv metadata for a stream.
    private func makeMetadata() -> AMFArray {
        // https://github.com/shogo4405/HaishinKit.swift/issues/1410
        var metadata: AMFObject = ["duration": 0]
        let snapshot = outgoing.metadataSnapshot
        if snapshot.videoInputFormat != nil {
            metadata["width"] = snapshot.videoSettings.videoSize.width
            metadata["height"] = snapshot.videoSettings.videoSize.height
            metadata["videocodecid"] = snapshot.videoSettings.format.codecid
            metadata["videodatarate"] = snapshot.videoSettings.bitRate / 1000
            if let expectedFrameRate = snapshot.videoSettings.expectedFrameRate {
                metadata["framerate"] = expectedFrameRate
            }
        }
        if let audioFormat = snapshot.audioInputFormat?.audioStreamBasicDescription {
            metadata["audiocodecid"] = snapshot.audioSettings.format.codecid
            metadata["audiodatarate"] = snapshot.audioSettings.bitRate / 1000
            metadata["audiosamplerate"] = snapshot.audioSettings.format.makeSampleRate(
                audioFormat.mSampleRate,
                output: snapshot.audioSettings.sampleRate
            )
        }
        return AMFArray(metadata)
    }

    private func notifyRawVideoOutputs(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.formatDescription?.isCompressed == false else {
            return
        }
        outputs.forEach {
            if videoSampleAccess || ($0 is View) {
                $0.stream(self, didOutput: sampleBuffer)
            }
        }
    }

    private func notifyRawAudioOutputs(_ audioBuffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard audioSampleAccess else {
            return
        }
        outputs.forEach {
            $0.stream(self, didOutput: audioBuffer, when: when)
        }
    }

    fileprivate func receiveEncodedMediaSample(
        _ sample: EncodedMediaSample,
        publishToken: RTMPPublishSessionState.Token
    ) async throws {
        let deliveryBarrier = encodedMediaDeliveryBarrierForTesting
        encodedMediaDeliveryBarrierForTesting = nil
        await deliveryBarrier?()
        guard publishSessionState.permitsProgress(publishToken) else {
            return
        }
        try deliverEncodedMediaSample(sample)
    }

    private func deliverEncodedMediaSample(_ sample: EncodedMediaSample) throws {
        guard readyState == .publishing else {
            return
        }
        let sampleBuffer = sample.sampleBuffer
        switch sampleBuffer.formatDescription?.mediaType {
        case .video where sampleBuffer.formatDescription?.isCompressed == true:
            let decodeTimeStamp = sampleBuffer.decodeTimeStamp.isValid
                ? sampleBuffer.decodeTimeStamp
                : sampleBuffer.presentationTimeStamp
            let timestamp: UInt32
            do {
                timestamp = try videoTimestamp.update(decodeTimeStamp)
            } catch {
                throw RTMPEncodedMediaOutputError.invalidVideoTimestamp
            }
            frameCount += 1
            try applyEncodedPipelineVideoFormat(
                sampleBuffer.formatDescription
            )
            encodedOutputs.forEach {
                $0.stream(self, didOutputEncoded: sampleBuffer)
            }
            guard let message = RTMPVideoMessage(
                streamId: id,
                timestamp: timestamp,
                sampleBuffer: sampleBuffer
            ) else {
                throw RTMPEncodedMediaOutputError.failedToCreateVideoMessage
            }
            doOutput(.one, chunkStreamId: .video, message: message)
        case .audio where sampleBuffer.formatDescription?.isCompressed == true:
            let timestamp: UInt32
            do {
                timestamp = try outboundAudioTimestamp.update(
                    sampleBuffer.presentationTimeStamp
                )
            } catch {
                throw RTMPEncodedMediaOutputError.invalidAudioTimestamp
            }
            try applyEncodedPipelineAudioFormat(
                sampleBuffer.formatDescription
            )
            encodedOutputs.forEach {
                $0.stream(self, didOutputEncoded: sampleBuffer)
            }
            guard let message = RTMPAudioMessage(
                streamId: id,
                timestamp: timestamp,
                sampleBuffer: sampleBuffer
            ) else {
                throw RTMPEncodedMediaOutputError.failedToCreateAudioMessage
            }
            doOutput(.one, chunkStreamId: .audio, message: message)
        default:
            break
        }
    }

    private func applyEncodedPipelineVideoFormat(
        _ formatDescription: CMFormatDescription?
    ) throws {
        guard let formatDescription else {
            throw RTMPEncodedMediaOutputError.failedToCreateVideoSequenceHeader
        }
        if
            let videoFormat,
            CMFormatDescriptionEqual(
                videoFormat,
                otherFormatDescription: formatDescription
            ) {
            return
        }
        guard let message = encodedPipelineVideoHeaderFactory(
            id,
            0,
            formatDescription
        ) else {
            throw RTMPEncodedMediaOutputError.failedToCreateVideoSequenceHeader
        }
        let chunkType: RTMPChunkType = videoFormat == nil ? .zero : .one
        isApplyingEncodedPipelineVideoFormat = true
        videoFormat = formatDescription
        isApplyingEncodedPipelineVideoFormat = false
        doOutput(chunkType, chunkStreamId: .video, message: message)
    }

    private func applyEncodedPipelineAudioFormat(
        _ formatDescription: CMFormatDescription?
    ) throws {
        guard let formatDescription else {
            throw RTMPEncodedMediaOutputError.failedToCreateAudioSequenceHeader
        }
        let nextAudioFormat = AVAudioFormat(
            cmAudioFormatDescription: formatDescription
        )
        if audioFormat == nextAudioFormat {
            return
        }
        guard let message = encodedPipelineAudioHeaderFactory(
            id,
            0,
            nextAudioFormat.formatDescription
        ) else {
            throw RTMPEncodedMediaOutputError.failedToCreateAudioSequenceHeader
        }
        let chunkType: RTMPChunkType = audioFormat == nil ? .zero : .one
        isApplyingEncodedPipelineAudioFormat = true
        audioFormat = nextAudioFormat
        isApplyingEncodedPipelineAudioFormat = false
        doOutput(chunkType, chunkStreamId: .audio, message: message)
    }

    package func deliverEncodedMediaSampleForTesting(
        _ sample: EncodedMediaSample
    ) throws {
        let previousReadyState = readyState
        readyState = .publishing
        defer {
            readyState = previousReadyState
        }
        try deliverEncodedMediaSample(sample)
    }

    package func beginTeardownForTesting(
        _ operation: RTMPTeardownState.Operation
    ) -> RTMPTeardownState.Token? {
        beginTeardown(
            operation,
            publishToken: nil,
            expectedResponse: operation == .close ? .unpublishSuccess : nil
        )
    }

    package var hasActiveTeardownForTesting: Bool {
        teardownState.activeToken != nil
    }

    package func finishTeardownForTesting(_ token: RTMPTeardownState.Token) {
        completeTeardown(token, result: nil)
    }

    package func timeoutPublishRequestForTesting(
        _ token: RTMPPublishSessionState.Token
    ) {
        timeoutPublishRequest(token)
    }

    package var hasActivePublishSessionForTesting: Bool {
        publishSessionState.activeToken != nil
    }

    fileprivate func encodedMediaPipelineDidEnd(
        publishToken: RTMPPublishSessionState.Token,
        codecEpoch: UUID,
        lastDeliverySequence: UInt64
    ) {
        guard publishSessionState.handlePipelineTerminal(publishToken) else {
            return
        }
        logger.error(
            "Unexpected encoded media pipeline terminal:",
            codecEpoch,
            "lastDeliverySequence:",
            lastDeliverySequence
        )
        isWireSessionReusable = false
        readyState = .idle
        info.resourceName = nil
        statusContinuation?.yield(Code.failed.status(
            "The encoded media pipeline terminated unexpectedly."
        ))
        doOutput(.zero, chunkStreamId: .command, message: RTMPCommandMessage(
            streamId: id,
            transactionId: 0,
            objectEncoding: objectEncoding,
            commandName: "closeStream",
            commandObject: nil,
            arguments: []
        ))
        finishPublishSession(publishToken)
    }

    package func beginPublishSessionForTesting() -> RTMPPublishSessionState.Token {
        let token = beginPublishSession()
        _ = publishSessionState.reservePipelineStart(token)
        _ = publishSessionState.completePipelineStart(token)
        readyState = .publishing
        return token
    }

    package func beginPendingPublishSessionForTesting() -> RTMPPublishSessionState.Token {
        let token = beginPublishSession()
        readyState = .publish
        return token
    }

    package func markPipelineTerminalExpectedForTesting(
        _ token: RTMPPublishSessionState.Token
    ) {
        _ = publishSessionState.cancel(
            token,
            expectsPipelineTerminal: true
        )
    }

    package func deliverPipelineTerminalForTesting(
        _ token: RTMPPublishSessionState.Token
    ) {
        encodedMediaPipelineDidEnd(
            publishToken: token,
            codecEpoch: UUID(),
            lastDeliverySequence: 0
        )
    }

    package func finishPublishSessionForTesting(
        _ token: RTMPPublishSessionState.Token
    ) {
        finishPublishSession(token)
        readyState = .idle
    }

    package func setOutputMessageHandlerForTesting(
        _ handler: (@Sendable (UInt8, UInt32, Data) -> Void)?
    ) {
        outputMessageHandlerForTesting = handler
    }

    package var hasPendingCommandForTesting: Bool {
        commandRequestState.activeToken != nil
    }

    package var hasPendingTeardownResponseForTesting: Bool {
        teardownContinuation != nil
    }

    package var isWireSessionReusableForTesting: Bool {
        isWireSessionReusable
    }

    package var encodedMediaPipelineForTesting: EncodedMediaPipeline {
        encodedMediaPipeline
    }

    package var encodedMediaOutputForTesting: RTMPStreamEncodedMediaOutput {
        encodedMediaOutput
    }

    package func setEncodedMediaDeliveryBarrierForTesting(
        _ barrier: (@Sendable () async -> Void)?
    ) {
        encodedMediaDeliveryBarrierForTesting = barrier
    }

    func setEncodedPipelineAudioHeaderFactoryForTesting(
        _ factory: @escaping
            (UInt32, UInt32, CMFormatDescription?) -> RTMPAudioMessage?
    ) {
        encodedPipelineAudioHeaderFactory = factory
    }

    func setEncodedPipelineVideoHeaderFactoryForTesting(
        _ factory: @escaping
            (UInt32, UInt32, CMFormatDescription?) -> RTMPVideoMessage?
    ) {
        encodedPipelineVideoHeaderFactory = factory
    }

    package func makeMetadataForTesting() -> AMFArray {
        makeMetadata()
    }
}

extension RTMPStream: _Stream {
    public func addEncodedOutput(_ observer: some RTMPEncodedStreamOutput) {
        guard !encodedOutputs.contains(where: { $0 === observer }) else {
            return
        }
        encodedOutputs.append(observer)
    }

    public func removeEncodedOutput(_ observer: some RTMPEncodedStreamOutput) {
        if let index = encodedOutputs.firstIndex(where: { $0 === observer }) {
            encodedOutputs.remove(at: index)
        }
    }

    public func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        if
            teardownState.activeToken != nil ||
            publishSessionState.isLifecycleTransitionInProgress {
            throw EncodedMediaPipeline.Error.lifecycleTransitionInProgress
        }
        try outgoing.applyAudioSettings(
            audioSettings,
            allowingCodecRestart: readyState != .publishing
        )
    }

    public func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        if
            teardownState.activeToken != nil ||
            publishSessionState.isLifecycleTransitionInProgress {
            throw EncodedMediaPipeline.Error.lifecycleTransitionInProgress
        }
        try outgoing.applyVideoSettings(
            videoSettings,
            allowingCodecRestart: readyState != .publishing
        )
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if sampleBuffer.formatDescription?.isCompressed == true {
                do {
                    outgoing.captureInputFormat(sampleBuffer)
                    let decodeTimeStamp = sampleBuffer.decodeTimeStamp.isValid ? sampleBuffer.decodeTimeStamp : sampleBuffer.presentationTimeStamp
                    let timedelta = try videoTimestamp.update(decodeTimeStamp)
                    frameCount += 1
                    videoFormat = sampleBuffer.formatDescription
                    encodedOutputs.forEach {
                        $0.stream(self, didOutputEncoded: sampleBuffer)
                    }
                    guard let message = RTMPVideoMessage(streamId: id, timestamp: timedelta, sampleBuffer: sampleBuffer) else {
                        return
                    }
                    doOutput(.one, chunkStreamId: .video, message: message)
                } catch {
                    logger.warn(error)
                }
            } else {
                outgoing.captureInputFormat(sampleBuffer)
                notifyRawVideoOutputs(sampleBuffer)
                encodedMediaPipeline.append(sampleBuffer)
            }
        default:
            break
        }
    }

    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        switch audioBuffer {
        case let audioBuffer as AVAudioCompressedBuffer:
            do {
                outgoing.captureInputFormat(audioBuffer)
                let timedelta = try outboundAudioTimestamp.update(when.makeTime())
                audioFormat = audioBuffer.format
                if !encodedOutputs.isEmpty, let sampleBuffer = audioBuffer.makeCompressedSampleBuffer(when) {
                    encodedOutputs.forEach {
                        $0.stream(self, didOutputEncoded: sampleBuffer)
                    }
                }
                guard let message = RTMPAudioMessage(streamId: id, timestamp: timedelta, audioBuffer: audioBuffer) else {
                    return
                }
                doOutput(.one, chunkStreamId: .audio, message: message)
            } catch {
                logger.warn(error)
            }
        default:
            if let audioBuffer = audioBuffer as? AVAudioPCMBuffer {
                outgoing.captureInputFormat(audioBuffer)
                notifyRawAudioOutputs(audioBuffer, when: when)
            }
            encodedMediaPipeline.append(audioBuffer, when: when)
        }
    }

    public func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
        currentFPS = frameCount
        frameCount = 0
        info.update()
    }
}

extension RTMPStream: MediaMixerOutput {
    // MARK: MediaMixerOutput
    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) async {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
        await encodedMediaPipeline.selectTrack(id, mediaType: mediaType)
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        outgoing.captureInputFormat(sampleBuffer)
        encodedMediaPipeline.mixer(mixer, didOutput: sampleBuffer)
        rawMixerOutputDispatcher.enqueue { [weak self] in
            await self?.notifyRawVideoOutputs(sampleBuffer)
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        outgoing.captureInputFormat(buffer)
        encodedMediaPipeline.mixer(mixer, didOutput: buffer, when: when)
        rawMixerOutputDispatcher.enqueue { [weak self] in
            await self?.notifyRawAudioOutputs(buffer, when: when)
        }
    }
}

private final class RTMPRawMixerOutputDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        lock.unlock()
    }
}

package final class RTMPStreamEncodedMediaOutput: EncodedMediaOutput, @unchecked Sendable {
    private enum Work: @unchecked Sendable {
        case sample(
            pipeline: EncodedMediaPipeline,
            sample: EncodedMediaSample,
            publishToken: RTMPPublishSessionState.Token,
            byteCount: Int
        )
        case terminal(
            codecEpoch: UUID,
            lastDeliverySequence: UInt64,
            publishToken: RTMPPublishSessionState.Token
        )
    }

    private weak var stream: RTMPStream?
    private let ingressPolicy = RTMPStream.encodedMediaOutputIngressPolicy
    private let lock = NSLock()
    private var publishToken: RTMPPublishSessionState.Token?
    private var acceptingSamples = false
    private var didReportFailure = false
    private var pendingSampleCount = 0
    private var pendingByteCount = 0
    private var maximumObservedPendingSampleCount = 0
    private var reportedFailureCount = 0
    private var work: [Work] = []
    private var workerTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(stream: RTMPStream) {
        self.stream = stream
    }

    func beginSession(_ token: RTMPPublishSessionState.Token) {
        lock.withLock {
            publishToken = token
            acceptingSamples = true
            didReportFailure = false
            pendingSampleCount = 0
            pendingByteCount = 0
            maximumObservedPendingSampleCount = 0
            reportedFailureCount = 0
        }
    }

    func endSession(_ token: RTMPPublishSessionState.Token) {
        lock.withLock {
            guard publishToken == token else {
                return
            }
            publishToken = nil
            acceptingSamples = false
        }
    }

    package func encodedMediaPipeline(
        _ pipeline: EncodedMediaPipeline,
        didOutput sample: EncodedMediaSample
    ) {
        let byteCount = CMSampleBufferGetTotalSampleSize(sample.sampleBuffer)
        let admission: (
            publishToken: RTMPPublishSessionState.Token?,
            shouldReportOverflow: Bool
        ) = lock.withLock {
            guard
                let publishToken,
                acceptingSamples else {
                return (nil, false)
            }
            guard
                0 <= byteCount,
                byteCount <= ingressPolicy.maximumByteCount,
                pendingSampleCount < ingressPolicy.maximumSampleCount,
                pendingByteCount <= ingressPolicy.maximumByteCount - byteCount else {
                acceptingSamples = false
                let shouldReportOverflow = !didReportFailure
                if shouldReportOverflow {
                    didReportFailure = true
                    reportedFailureCount += 1
                }
                return (publishToken, shouldReportOverflow)
            }
            pendingSampleCount += 1
            pendingByteCount += byteCount
            maximumObservedPendingSampleCount = max(
                maximumObservedPendingSampleCount,
                pendingSampleCount
            )
            work.append(.sample(
                pipeline: pipeline,
                sample: sample,
                publishToken: publishToken,
                byteCount: byteCount
            ))
            startWorkerLocked()
            return (publishToken, false)
        }
        guard admission.publishToken != nil else {
            return
        }
        if admission.shouldReportOverflow {
            pipeline.reportOutputFailure(
                EncodedMediaPipeline.Error.outputIngressOverflow,
                codecEpoch: sample.codecEpoch
            )
        }
    }

    package func encodedMediaPipeline(
        _ pipeline: EncodedMediaPipeline,
        didEndCodecEpoch codecEpoch: UUID,
        lastDeliverySequence: UInt64
    ) {
        lock.withLock {
            guard let publishToken else {
                return
            }
            work.append(.terminal(
                codecEpoch: codecEpoch,
                lastDeliverySequence: lastDeliverySequence,
                publishToken: publishToken,
            ))
            startWorkerLocked()
        }
    }

    package func waitForIdle() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard workerTask != nil || !work.isEmpty else {
                    return true
                }
                idleWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    package var pendingSampleCountForTesting: Int {
        lock.withLock {
            pendingSampleCount
        }
    }

    package var maximumObservedPendingSampleCountForTesting: Int {
        lock.withLock {
            maximumObservedPendingSampleCount
        }
    }

    package var isAcceptingSamplesForTesting: Bool {
        lock.withLock {
            acceptingSamples
        }
    }

    package var reportedFailureCountForTesting: Int {
        lock.withLock {
            reportedFailureCount
        }
    }

    private func startWorkerLocked() {
        guard workerTask == nil else {
            return
        }
        workerTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let next = takeNextWork() {
            switch next {
            case let .sample(pipeline, sample, publishToken, byteCount):
                do {
                    try await stream?.receiveEncodedMediaSample(
                        sample,
                        publishToken: publishToken
                    )
                } catch {
                    reportFailureIfNeeded(
                        error,
                        pipeline: pipeline,
                        codecEpoch: sample.codecEpoch,
                        publishToken: publishToken
                    )
                }
                lock.withLock {
                    pendingSampleCount -= 1
                    pendingByteCount -= byteCount
                }
            case let .terminal(codecEpoch, lastDeliverySequence, publishToken):
                await stream?.encodedMediaPipelineDidEnd(
                    publishToken: publishToken,
                    codecEpoch: codecEpoch,
                    lastDeliverySequence: lastDeliverySequence
                )
            }
        }
    }

    private func takeNextWork() -> Work? {
        let state: (
            next: Work?,
            waiters: [CheckedContinuation<Void, Never>]
        ) = lock.withLock {
            guard !work.isEmpty else {
                workerTask = nil
                let waiters = idleWaiters
                idleWaiters.removeAll()
                return (nil, waiters)
            }
            return (work.removeFirst(), [])
        }
        state.waiters.forEach {
            $0.resume()
        }
        return state.next
    }

    private func reportFailureIfNeeded(
        _ error: any Swift.Error,
        pipeline: EncodedMediaPipeline,
        codecEpoch: UUID,
        publishToken: RTMPPublishSessionState.Token
    ) {
        let shouldReport = lock.withLock {
            guard
                self.publishToken == publishToken,
                !didReportFailure else {
                return false
            }
            didReportFailure = true
            acceptingSamples = false
            reportedFailureCount += 1
            return true
        }
        if shouldReport {
            pipeline.reportOutputFailure(error, codecEpoch: codecEpoch)
        }
    }
}
