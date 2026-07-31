import AVFoundation
import Foundation

/// An object that provides a stream ingest feature.
package final class OutgoingStream: @unchecked Sendable {
    package struct MetadataSnapshot: @unchecked Sendable {
        package let audioInputFormat: CMFormatDescription?
        package let audioSettings: AudioCodecSettings
        package let videoInputFormat: CMFormatDescription?
        package let videoSettings: VideoCodecSettings
    }

    package var isRunning: Bool {
        lock.withLock {
            _isRunning
        }
    }

    /// The asynchronous sequence for audio output.
    package var audioOutputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)> {
        lock.withLock {
            audioCodec.outputStream
        }
    }

    /// Specifies the audio compression properties.
    package var audioSettings: AudioCodecSettings {
        get {
            lock.withLock {
                audioCodec.settings
            }
        }
        set {
            lock.withLock {
                audioCodec.settings = newValue
            }
        }
    }

    /// The audio input format.
    package var audioInputFormat: CMFormatDescription? {
        lock.withLock {
            _audioInputFormat
        }
    }

    /// The asynchronous sequence for video output.
    package var videoOutputStream: AsyncStream<CMSampleBuffer> {
        lock.withLock {
            videoCodec.outputStream
        }
    }

    package var videoTerminalFailureStream: AsyncStream<any Swift.Error> {
        lock.withLock {
            videoCodec.terminalFailureStream
        }
    }

    /// Specifies the video compression properties.
    package var videoSettings: VideoCodecSettings {
        get {
            lock.withLock {
                videoCodec.settings
            }
        }
        set {
            lock.withLock {
                videoCodec.settings = newValue
            }
        }
    }

    /// Specifies the video buffering count.
    package var videoInputBufferCounts: Int {
        get {
            lock.withLock {
                _videoInputBufferCounts
            }
        }
        set {
            lock.withLock {
                _videoInputBufferCounts = newValue
            }
        }
    }

    /// The asynchronous sequence for video input buffer.
    package var videoInputStream: AsyncStream<CMSampleBuffer> {
        let videoInputBufferCounts = self.videoInputBufferCounts
        if 0 < videoInputBufferCounts {
            return AsyncStream(
                CMSampleBuffer.self,
                bufferingPolicy: .bufferingNewest(videoInputBufferCounts)
            ) { continuation in
                self.replaceVideoInputContinuation(with: continuation)
            }
        } else {
            return AsyncStream { continuation in
                self.replaceVideoInputContinuation(with: continuation)
            }
        }
    }

    /// The video input format.
    package var videoInputFormat: CMFormatDescription? {
        lock.withLock {
            _videoInputFormat
        }
    }

    private let lock = NSLock()
    private var _isRunning = false
    private var _audioInputFormat: CMFormatDescription?
    private var _videoInputBufferCounts = -1
    private var _videoInputFormat: CMFormatDescription?
    private var audioCodec = AudioCodec()
    private var videoCodec = VideoCodec()
    private var videoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation?

    /// Create a new instance.
    package init() {
    }

    package var metadataSnapshot: MetadataSnapshot {
        lock.withLock {
            MetadataSnapshot(
                audioInputFormat: _audioInputFormat,
                audioSettings: audioCodec.settings,
                videoInputFormat: _videoInputFormat,
                videoSettings: videoCodec.settings
            )
        }
    }

    /// Appends a sample buffer for publish.
    package func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer {
            lock.unlock()
        }
        captureInputFormatLocked(sampleBuffer)
        switch sampleBuffer.formatDescription?.mediaType {
        case .audio:
            audioCodec.append(sampleBuffer)
        case .video:
            videoInputContinuation?.yield(sampleBuffer)
        default:
            break
        }
    }

    /// Appends a sample buffer for publish.
    package func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        lock.lock()
        defer {
            lock.unlock()
        }
        captureInputFormatLocked(audioBuffer)
        audioCodec.append(audioBuffer, when: when)
    }

    package func appendEncodedAudio(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        captureInputFormatLocked(audioBuffer)
        try audioCodec.appendOrThrow(audioBuffer, when: when)
    }

    /// Appends a video buffer.
    package func append(video sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            videoCodec.append(sampleBuffer)
        }
    }

    package func appendEncodedVideo(_ sampleBuffer: CMSampleBuffer) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        captureInputFormatLocked(sampleBuffer)
        try videoCodec.appendOrThrow(sampleBuffer)
    }

    package func captureInputFormat(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            captureInputFormatLocked(sampleBuffer)
        }
    }

    package func captureInputFormat(_ audioBuffer: AVAudioBuffer) {
        lock.withLock {
            captureInputFormatLocked(audioBuffer)
        }
    }

    package func applyAudioSettings(
        _ settings: AudioCodecSettings,
        allowingCodecRestart: Bool
    ) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        if
            !allowingCodecRestart,
            settings.invalidateConverter(audioCodec.settings) {
            throw EncodedMediaPipeline.Error.settingsChangeRequiresCodecRestart
        }
        audioCodec.settings = settings
    }

    package func applyVideoSettings(
        _ settings: VideoCodecSettings,
        allowingCodecRestart: Bool
    ) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        if
            !allowingCodecRestart,
            settings.invalidateSession(videoCodec.settings) {
            throw EncodedMediaPipeline.Error.settingsChangeRequiresCodecRestart
        }
        videoCodec.settings = settings
    }

    package func requestVideoKeyFrame() {
        lock.withLock {
            videoCodec.requestKeyFrame()
        }
    }

    package func finishVideoInput() {
        replaceVideoInputContinuation(with: nil)
    }

    package func stopRunningAndDrain() async throws {
        let stopResult: (
            oldVideoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation?,
            drainError: (any Swift.Error)?
        )? = lock.withLock {
            guard _isRunning else {
                return nil
            }
            _isRunning = false
            var drainError: (any Swift.Error)?
            do {
                try videoCodec.stopRunningAndDrain()
            } catch {
                drainError = error
            }
            do {
                try audioCodec.stopRunningAndDrain()
            } catch {
                if drainError == nil {
                    drainError = error
                }
            }
            let oldVideoInputContinuation = videoInputContinuation
            videoInputContinuation = nil
            return (oldVideoInputContinuation, drainError)
        }
        guard let stopResult else {
            return
        }
        stopResult.oldVideoInputContinuation?.finish()
        if let drainError = stopResult.drainError {
            throw drainError
        }
    }

    private func captureInputFormatLocked(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .audio:
            _audioInputFormat = sampleBuffer.formatDescription
        case .video:
            _videoInputFormat = sampleBuffer.formatDescription
        default:
            break
        }
    }

    private func captureInputFormatLocked(_ audioBuffer: AVAudioBuffer) {
        _audioInputFormat = audioBuffer.format.formatDescription
    }

    private func replaceVideoInputContinuation(
        with continuation: AsyncStream<CMSampleBuffer>.Continuation?
    ) {
        let previous = lock.withLock {
            let previous = videoInputContinuation
            videoInputContinuation = continuation
            return previous
        }
        previous?.finish()
    }
}

extension OutgoingStream: EncodedMediaPipelineOutgoing {
}

extension OutgoingStream: Runner {
    // MARK: Runner
    package func startRunning() {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !_isRunning else {
            return
        }
        videoCodec.startRunning()
        audioCodec.startRunning()
        _isRunning = true
    }

    package func stopRunning() {
        let oldVideoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation?
        lock.lock()
        guard _isRunning else {
            lock.unlock()
            return
        }
        _isRunning = false
        videoCodec.stopRunning()
        audioCodec.stopRunning()
        oldVideoInputContinuation = videoInputContinuation
        videoInputContinuation = nil
        lock.unlock()
        oldVideoInputContinuation?.finish()
    }
}
