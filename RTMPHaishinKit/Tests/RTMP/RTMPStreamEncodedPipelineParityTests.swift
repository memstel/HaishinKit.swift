import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import HaishinKit
@testable import RTMPHaishinKit

@Suite struct RTMPStreamEncodedPipelineParityTests {
    @Test
    func encodedEnvelopePreservesLegacyCallbackIdentityTimingAndPayloadFingerprint() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let observer = LegacyObserver()
        let messageProbe = MessageProbe()
        await stream.addEncodedOutput(observer)
        await stream.setOutputMessageHandlerForTesting { _, timestamp, payload in
            messageProbe.record(timestamp: timestamp, payload: payload)
        }

        let first = try #require(Self.makeCompressedVideoSampleBuffer(
            payload: [0, 0, 0, 2, 0x65, 0x88],
            presentationTimeStamp: CMTime(value: 30, timescale: 30),
            decodeTimeStamp: CMTime(value: 27, timescale: 30)
        ))
        let second = try #require(Self.makeCompressedVideoSampleBuffer(
            payload: [0, 0, 0, 2, 0x41, 0x99],
            presentationTimeStamp: CMTime(value: 60, timescale: 30),
            decodeTimeStamp: CMTime(value: 57, timescale: 30)
        ))
        let epoch = UUID()

        try await stream.deliverEncodedMediaSampleForTesting(.init(
            codecEpoch: epoch,
            formatEpoch: 0,
            deliverySequence: 1,
            sampleBuffer: first
        ))
        try await stream.deliverEncodedMediaSampleForTesting(.init(
            codecEpoch: epoch,
            formatEpoch: 0,
            deliverySequence: 2,
            sampleBuffer: second
        ))

        #expect(observer.samples.count == 2)
        #expect(observer.samples[0] === first)
        #expect(observer.samples[1] === second)
        #expect(observer.samples.map(\.presentationTimeStamp) == [
            first.presentationTimeStamp,
            second.presentationTimeStamp
        ])
        #expect(observer.samples.map(\.decodeTimeStamp) == [
            first.decodeTimeStamp,
            second.decodeTimeStamp
        ])

        let messages = messageProbe.messages
        #expect(messages.count == 3)
        #expect(messages.map(\.timestamp) == [0, 0, 999])
        #expect(messages[0].payloadFingerprint.count > 5)
        #expect(messages[1].payloadFingerprint.suffix(
            Self.payloadFingerprint(first).count
        ) == Self.payloadFingerprint(first))
        #expect(messages[2].payloadFingerprint.suffix(
            Self.payloadFingerprint(second).count
        ) == Self.payloadFingerprint(second))
    }

    @Test
    func compressedDirectAppendKeepsLegacyCallbackCompatibilityAndDoesNotRequirePipelineLifecycle() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let observer = LegacyObserver()
        await stream.addEncodedOutput(observer)

        let sample = try #require(Self.makeCompressedVideoSampleBuffer(
            payload: [0, 0, 0, 2, 0x65, 0x42],
            presentationTimeStamp: CMTime(value: 1, timescale: 1),
            decodeTimeStamp: .invalid
        ))
        await stream.append(sample)

        #expect(observer.samples.count == 1)
        #expect(observer.samples[0] === sample)
        #expect(await stream.readyState == .idle)
    }

    @Test
    func rawVideoBeforePublishStillCapturesInputFormatForRTMPMetadata() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let sample = try #require(Self.makeRawVideoSampleBuffer())

        await stream.append(sample)

        #expect(await stream.outgoing.videoInputFormat != nil)
        #expect(await stream.readyState == .idle)
    }

    @Test
    func mixerCapturesVideoInputFormatSynchronouslyBeforeIdlePipelineCanDropSample() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let sample = try #require(Self.makeRawVideoSampleBuffer())

        stream.mixer(MediaMixer(), didOutput: sample)

        #expect(await stream.outgoing.videoInputFormat == sample.formatDescription)
        #expect(await stream.readyState == .idle)
    }

    @Test
    func mixerCapturesAudioInputFormatSynchronouslyBeforeIdlePipelineCanDropBuffer() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 1_024
        ))

        stream.mixer(
            MediaMixer(),
            didOutput: buffer,
            when: AVAudioTime(sampleTime: 0, atRate: format.sampleRate)
        )

        #expect(
            await stream.outgoing.audioInputFormat?.audioStreamBasicDescription?
                .mSampleRate == format.sampleRate
        )
        #expect(await stream.readyState == .idle)
    }

    @Test
    func closeCancellationBeforeStartReservationPreventsLatePipelineStart() {
        var state = RTMPPublishSessionState()
        let token = state.begin()

        #expect(state.cancel(token, expectsPipelineTerminal: true) == .noReservedStart)
        #expect(state.reservePipelineStart(token) == false)
        #expect(state.permitsProgress(token) == false)
    }

    @Test
    func closeCancellationAfterStartReservationRequiresJoiningReservedStart() {
        var state = RTMPPublishSessionState()
        let token = state.begin()

        let didReservePipelineStart = state.reservePipelineStart(token)
        #expect(didReservePipelineStart)
        #expect(state.isLifecycleTransitionInProgress)
        #expect(state.cancel(token, expectsPipelineTerminal: true) == .joinReservedStart)
        #expect(state.permitsProgress(token) == false)
    }

    @Test
    func stalePublishGenerationCannotAffectNextSession() {
        var state = RTMPPublishSessionState()
        let firstToken = state.begin()
        state.finish(firstToken)
        let secondToken = state.begin()

        #expect(firstToken != secondToken)
        #expect(state.reservePipelineStart(firstToken) == false)
        #expect(state.handlePipelineTerminal(firstToken) == false)
        #expect(state.permitsProgress(secondToken))
    }

    @Test
    func teardownGenerationBlocksPublishUntilCompletionAndRejectsStaleCompletion() {
        var teardown = RTMPTeardownState()
        let firstClose = teardown.begin(.close)

        #expect(firstClose != nil)
        #expect(teardown.begin(.close) == nil)

        let firstToken = firstClose!
        #expect(teardown.matches(firstToken))
        let didFinishFirstClose = teardown.finish(firstToken)
        #expect(didFinishFirstClose)

        let secondClose = teardown.begin(.close)
        #expect(secondClose != nil)
        #expect(teardown.matches(firstToken) == false)
        let didFinishStaleClose = teardown.finish(firstToken)
        #expect(didFinishStaleClose == false)
        #expect(teardown.matches(secondClose!))
    }

    @Test
    func deleteTeardownUsesTheSamePublishGateAsClose() {
        var teardown = RTMPTeardownState()
        let deleteToken = teardown.begin(.delete)

        #expect(deleteToken != nil)
        #expect(teardown.begin(.close) == nil)
        #expect(teardown.matches(deleteToken!))
        let didFinishDelete = teardown.finish(deleteToken!)
        #expect(didFinishDelete)
        #expect(teardown.begin(.close) != nil)
    }

    @Test
    func publishIsBlockedUntilCloseGenerationCompletesAndStaleStatusCannotFinishIt() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let closeToken = try #require(await stream.beginTeardownForTesting(.close))

        do {
            _ = try await stream.publish("publish-B")
            Issue.record("Expected publish B to be blocked by close A")
        } catch RTMPStream.Error.invalidState {
            // Expected: the close generation owns the stream until completion.
        } catch {
            Issue.record("Unexpected publish error: \(error)")
        }

        let staleStatus = RTMPCommandMessage(
            streamId: 0,
            transactionId: 0,
            objectEncoding: .amf0,
            commandName: "onStatus",
            commandObject: nil,
            arguments: [[
                "code": RTMPStream.Code.unpublishSuccess.rawValue,
                "level": "status",
                "description": "stale"
            ]]
        )
        await stream.dispatch(staleStatus, type: .zero)
        #expect(await stream.hasActiveTeardownForTesting)

        await stream.finishTeardownForTesting(closeToken)
        #expect(await stream.hasActiveTeardownForTesting == false)
    }

    @Test
    func stalePublishTimeoutCannotAffectNextPublishGeneration() async {
        let stream = RTMPStream(connection: RTMPConnection())
        let firstToken = await stream.beginPendingPublishSessionForTesting()
        await stream.finishPublishSessionForTesting(firstToken)
        let secondToken = await stream.beginPendingPublishSessionForTesting()

        await stream.timeoutPublishRequestForTesting(firstToken)

        #expect(await stream.hasActivePublishSessionForTesting)
        #expect(await stream.readyState == .publish)
        await stream.finishPublishSessionForTesting(secondToken)
    }

    @Test
    func publishTimeoutMakesWireSessionNonReusableAndLateStartCannotSatisfyAnotherRequest() async throws {
        let stream = RTMPStream(connection: RTMPConnection(requestTimeout: 20))
        let publishTask = Task {
            try await stream.publish("publish-A")
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }

        do {
            _ = try await publishTask.value
            Issue.record("Expected publish A to time out")
        } catch RTMPStream.Error.requestTimedOut {
            // Expected: response provenance is now uncertain.
        } catch {
            Issue.record("Unexpected publish A error: \(error)")
        }
        #expect(await stream.isWireSessionReusableForTesting == false)

        do {
            _ = try await stream.publish("publish-B")
            Issue.record("Expected publish B to require a fresh RTMP stream/session")
        } catch RTMPStream.Error.invalidState {
            // Expected: a late Publish.Start from A cannot be correlated to B.
        } catch {
            Issue.record("Unexpected publish B error: \(error)")
        }

        await Self.dispatchStatus(.publishStart, to: stream)
        #expect(await stream.hasPendingCommandForTesting == false)
    }

    @Test
    func cancellingPendingPublishKeepsRealContinuationIsolatedFromLatePublishStart() async throws {
        let stream = RTMPStream(connection: RTMPConnection(requestTimeout: 1_000))
        let publishTask = Task {
            try await stream.publish("publish-A")
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }

        let closeTask = Task {
            try await stream.close()
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingTeardownResponseForTesting
        }
        await Self.dispatchStatus(.unpublishSuccess, to: stream)

        do {
            _ = try await publishTask.value
            Issue.record("Expected pending publish A to be cancelled")
        } catch RTMPStream.Error.invalidState {
            // Expected: close owns the cancelled publish generation.
        } catch {
            Issue.record("Unexpected publish A cancellation error: \(error)")
        }
        _ = try await closeTask.value
        #expect(await stream.isWireSessionReusableForTesting == false)

        await Self.dispatchStatus(.publishStart, to: stream)
        do {
            _ = try await stream.publish("publish-B")
            Issue.record("Expected publish B to require a fresh RTMP stream/session")
        } catch RTMPStream.Error.invalidState {
            // Expected: Publish.Start provenance remains uncertain.
        } catch {
            Issue.record("Unexpected publish B error: \(error)")
        }
    }

    @Test
    func successfulPauseTimeoutCannotResumeLaterPublishContinuation() async throws {
        let stream = RTMPStream(connection: RTMPConnection(requestTimeout: 100))
        let playTask = Task {
            try await stream.play("play-A")
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }
        await Self.dispatchStatus(.playStart, to: stream)
        _ = try await playTask.value

        let pauseTask = Task {
            try await stream.pause(false)
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }
        try await Task.sleep(nanoseconds: 70_000_000)
        await Self.dispatchStatus(.unpauseNotify, to: stream)
        _ = try await pauseTask.value

        let closePlayTask = Task {
            try await stream.close()
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingTeardownResponseForTesting
        }
        await Self.dispatchStatus(.playStop, to: stream)
        _ = try await closePlayTask.value

        let publishTask = Task {
            try await stream.publish("publish-B")
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await stream.hasPendingCommandForTesting)

        await Self.dispatchStatus(.publishStart, to: stream)
        _ = try await publishTask.value
        #expect(await stream.isWireSessionReusableForTesting)

        let closePublishTask = Task {
            try await stream.close()
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingTeardownResponseForTesting
        }
        await Self.dispatchStatus(.unpublishSuccess, to: stream)
        _ = try await closePublishTask.value
    }

    @Test
    func firstPauseAndUnpauseWaitForTheirRequestedTokenScopedStatus() async throws {
        let stream = RTMPStream(connection: RTMPConnection(requestTimeout: 1_000))
        let playTask = Task {
            try await stream.play("play-A")
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }
        await Self.dispatchStatus(.playStart, to: stream)
        _ = try await playTask.value

        let pauseTask = Task {
            try await stream.pause(true)
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }
        await Self.dispatchStatus(.unpauseNotify, to: stream)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await stream.hasPendingCommandForTesting)
        await Self.dispatchStatus(.pauseNotify, to: stream)
        _ = try await pauseTask.value

        let unpauseTask = Task {
            try await stream.pause(false)
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }
        await Self.dispatchStatus(.pauseNotify, to: stream)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await stream.hasPendingCommandForTesting)
        await Self.dispatchStatus(.unpauseNotify, to: stream)
        _ = try await unpauseTask.value

        let closeTask = Task {
            try await stream.close()
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingTeardownResponseForTesting
        }
        await Self.dispatchStatus(.playStop, to: stream)
        _ = try await closeTask.value
    }

    @Test
    func pendingPlayBlocksPublishWhileHoldingARealContinuation() async throws {
        let stream = RTMPStream(connection: RTMPConnection(requestTimeout: 1_000))
        let playTask = Task {
            try await stream.play("play-A")
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingCommandForTesting
        }

        do {
            _ = try await stream.publish("publish-B")
            Issue.record("Expected pending play to block publish")
        } catch RTMPStream.Error.invalidState {
            // Expected: one typed command request owns the stream.
        } catch {
            Issue.record("Unexpected publish error: \(error)")
        }

        await Self.dispatchStatus(.playStart, to: stream)
        _ = try await playTask.value
        let closeTask = Task {
            try await stream.close()
        }
        try await Self.waitUntilAsync {
            await stream.hasPendingTeardownResponseForTesting
        }
        await Self.dispatchStatus(.playStop, to: stream)
        _ = try await closeTask.value
    }

    @Test
    func teardownTimeoutMakesWireSessionNonReusableBeforeLateUnpublishResponse() async throws {
        let stream = RTMPStream(connection: RTMPConnection(requestTimeout: 20))
        let token = await stream.beginPublishSessionForTesting()

        do {
            _ = try await stream.close()
            Issue.record("Expected close teardown to time out")
        } catch RTMPStream.Error.requestTimedOut {
            // Expected: late Unpublish.Success has unknown generation provenance.
        } catch {
            Issue.record("Unexpected close error: \(error)")
        }
        #expect(await stream.isWireSessionReusableForTesting == false)
        await Self.dispatchStatus(.unpublishSuccess, to: stream)

        do {
            _ = try await stream.publish("publish-B")
            Issue.record("Expected publish B to require a fresh RTMP stream/session")
        } catch RTMPStream.Error.invalidState {
            // Expected.
        } catch {
            Issue.record("Unexpected publish B error: \(error)")
        }
        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func publishIsBlockedUntilDeleteGenerationCompletes() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let deleteToken = try #require(await stream.beginTeardownForTesting(.delete))

        do {
            _ = try await stream.publish("publish-B")
            Issue.record("Expected publish B to be blocked by delete")
        } catch RTMPStream.Error.invalidState {
            // Expected: delete owns the stream until remote cleanup completes.
        } catch {
            Issue.record("Unexpected publish error: \(error)")
        }

        await stream.finishTeardownForTesting(deleteToken)
    }

    @Test
    func pendingPublishRejectsCodecRestartSettingsUntilPipelineStartCompletes() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let token = await stream.beginPendingPublishSessionForTesting()
        var settings = await stream.videoSettings
        settings.videoSize = .init(width: 1_280, height: 720)

        do {
            try await stream.setVideoSettings(settings)
            Issue.record("Expected pending publish to reject codec restart settings")
        } catch EncodedMediaPipeline.Error.lifecycleTransitionInProgress {
            // Expected: publish start and pipeline start share one lifecycle gate.
        } catch {
            Issue.record("Unexpected settings error: \(error)")
        }

        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func rtmpEncodedOutputUsesAuthoritativeOverflowPolicy() {
        #expect(
            RTMPStream.encodedMediaOutputIngressPolicy.overflowDisposition
                == .failPipeline
        )
    }

    @Test
    func publishingRTMPSettingsAllowAdaptiveChangesAndRejectCodecRestarts() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let token = await stream.beginPublishSessionForTesting()

        var adaptiveVideoSettings = await stream.videoSettings
        adaptiveVideoSettings.bitRate += 128_000
        try await stream.setVideoSettings(adaptiveVideoSettings)
        #expect(await stream.videoSettings.bitRate == adaptiveVideoSettings.bitRate)

        var restartingVideoSettings = adaptiveVideoSettings
        restartingVideoSettings.videoSize = .init(width: 1_280, height: 720)
        do {
            try await stream.setVideoSettings(restartingVideoSettings)
            Issue.record("Expected publishing RTMP video settings to reject codec restart")
        } catch EncodedMediaPipeline.Error.settingsChangeRequiresCodecRestart {
            #expect(await stream.videoSettings.videoSize == adaptiveVideoSettings.videoSize)
        } catch {
            Issue.record("Unexpected video settings error: \(error)")
        }

        let currentAudioSettings = await stream.audioSettings
        let adaptiveAudioSettings = AudioCodecSettings(
            bitRate: currentAudioSettings.bitRate + 16_000,
            downmix: currentAudioSettings.downmix,
            channelMap: currentAudioSettings.channelMap,
            sampleRate: currentAudioSettings.sampleRate,
            format: currentAudioSettings.format
        )
        try await stream.setAudioSettings(adaptiveAudioSettings)
        #expect(await stream.audioSettings.bitRate == adaptiveAudioSettings.bitRate)

        let restartingAudioSettings = AudioCodecSettings(
            bitRate: adaptiveAudioSettings.bitRate,
            downmix: adaptiveAudioSettings.downmix,
            channelMap: adaptiveAudioSettings.channelMap,
            sampleRate: 48_000,
            format: adaptiveAudioSettings.format
        )
        do {
            try await stream.setAudioSettings(restartingAudioSettings)
            Issue.record("Expected publishing RTMP audio settings to reject codec restart")
        } catch EncodedMediaPipeline.Error.settingsChangeRequiresCodecRestart {
            #expect(await stream.audioSettings.sampleRate == adaptiveAudioSettings.sampleRate)
        } catch {
            Issue.record("Unexpected audio settings error: \(error)")
        }

        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func unexpectedPipelineTerminalFailsPublishingSessionButExpectedTerminalDoesNot() async {
        let unexpectedStream = RTMPStream(connection: RTMPConnection())
        let unexpectedStatus = await unexpectedStream.status
        let unexpectedToken = await unexpectedStream.beginPublishSessionForTesting()

        await unexpectedStream.deliverPipelineTerminalForTesting(unexpectedToken)

        #expect(await unexpectedStream.readyState == .idle)
        var statusIterator = unexpectedStatus.makeAsyncIterator()
        let status = await statusIterator.next()
        #expect(status?.code == RTMPStream.Code.failed.rawValue)
        #expect(status?.level == "error")
        #expect(await unexpectedStream.isWireSessionReusableForTesting == false)
        do {
            _ = try await unexpectedStream.publish("publish-B")
            Issue.record("Expected unexpected terminal to require a fresh stream/session")
        } catch RTMPStream.Error.invalidState {
            // Expected: remote close is fire-and-forget.
        } catch {
            Issue.record("Unexpected publish B error: \(error)")
        }

        let expectedStream = RTMPStream(connection: RTMPConnection())
        let expectedToken = await expectedStream.beginPublishSessionForTesting()
        await expectedStream.markPipelineTerminalExpectedForTesting(expectedToken)

        await expectedStream.deliverPipelineTerminalForTesting(expectedToken)

        #expect(await expectedStream.readyState == .publishing)
        await expectedStream.finishPublishSessionForTesting(expectedToken)
    }

    @Test
    func encodedAudioEnvelopePreservesIdentityAndUsesExistingAACMessagePayloadPath() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let observer = LegacyObserver()
        let messageProbe = MessageProbe()
        await stream.addEncodedOutput(observer)
        await stream.setOutputMessageHandlerForTesting { _, timestamp, payload in
            messageProbe.record(timestamp: timestamp, payload: payload)
        }

        let first = try #require(Self.makeCompressedAudioSampleBuffer(
            payload: [0x11, 0x22, 0x33],
            presentationTimeStamp: CMTime(value: 44_100, timescale: 44_100)
        ))
        let second = try #require(Self.makeCompressedAudioSampleBuffer(
            payload: [0x44, 0x55, 0x66],
            presentationTimeStamp: CMTime(value: 45_124, timescale: 44_100)
        ))
        let epoch = UUID()

        try await stream.deliverEncodedMediaSampleForTesting(.init(
            codecEpoch: epoch,
            formatEpoch: 0,
            deliverySequence: 1,
            sampleBuffer: first
        ))
        try await stream.deliverEncodedMediaSampleForTesting(.init(
            codecEpoch: epoch,
            formatEpoch: 0,
            deliverySequence: 2,
            sampleBuffer: second
        ))

        #expect(observer.samples.count == 2)
        #expect(observer.samples[0] === first)
        #expect(observer.samples[1] === second)
        let rawAudioMessages = messageProbe.messages.filter {
            $0.payloadFingerprint.count > 2 && $0.payloadFingerprint[1] == 1
        }
        #expect(rawAudioMessages.map(\.timestamp) == [0, 23])
        let firstMessage = try #require(rawAudioMessages.first)
        let secondMessage = try #require(rawAudioMessages.dropFirst().first)
        #expect(Data(firstMessage.payloadFingerprint.dropFirst(2)) == Data([0x11, 0x22, 0x33]))
        #expect(Data(secondMessage.payloadFingerprint.dropFirst(2)) == Data([0x44, 0x55, 0x66]))
    }

    @Test
    func directAndPipelineAACSamplesShareOneOutboundTimestampTimeline() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let messageProbe = MessageProbe()
        await stream.setOutputMessageHandlerForTesting { _, timestamp, payload in
            messageProbe.record(timestamp: timestamp, payload: payload)
        }
        let directBuffer = try #require(Self.makeCompressedAudioBuffer())
        let directTime = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1.0))

        await stream.append(directBuffer, when: directTime)
        let encoded = try #require(Self.makeCompressedAudioSampleBuffer(
            payload: [0x44, 0x55, 0x66],
            presentationTimeStamp: CMTime(value: 45_123, timescale: 44_100)
        ))
        try await stream.deliverEncodedMediaSampleForTesting(.init(
            codecEpoch: UUID(),
            formatEpoch: 0,
            deliverySequence: 1,
            sampleBuffer: encoded
        ))

        let audioMessages = messageProbe.messages.filter {
            $0.payloadFingerprint.count > 2 && $0.payloadFingerprint[1] == 1
        }
        #expect(audioMessages.map(\.timestamp) == [0, 23])
    }

    @Test
    func boundedRTMPAdapterBacklogFailsPipelineWithoutRetainingUnboundedTasks() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let gate = AsyncGate()
        await stream.setEncodedMediaDeliveryBarrierForTesting(gate.wait)
        let token = await stream.beginPublishSessionForTesting()
        let pipeline = await stream.encodedMediaPipelineForTesting
        let output = await stream.encodedMediaOutputForTesting
        try await pipeline.startEncoding()
        let codecEpoch = try #require(await pipeline.activeCodecEpochForTesting)
        let sampleBuffer = try #require(Self.makeCompressedVideoSampleBuffer(
            payload: [0, 0, 0, 2, 0x65, 0x88],
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        ))

        for sequence in 1...513 {
            output.encodedMediaPipeline(
                pipeline,
                didOutput: .init(
                    codecEpoch: codecEpoch,
                    formatEpoch: 0,
                    deliverySequence: UInt64(sequence),
                    sampleBuffer: sampleBuffer
                )
            )
        }
        try await Self.waitUntil {
            output.pendingSampleCountForTesting == 512
                && output.isAcceptingSamplesForTesting == false
        }

        #expect(output.maximumObservedPendingSampleCountForTesting == 512)
        gate.signal()
        await output.waitForIdle()
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected bounded authoritative RTMP ingress to fail the pipeline")
        } catch EncodedMediaPipeline.Error.outputIngressOverflow {
            // Expected: no sample was silently discarded as successfully delivered.
        } catch {
            Issue.record("Unexpected pipeline failure: \(error)")
        }
        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func videoTimestampFailureFromRTMPAdapterTerminatesPipelineExactlyOnce() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let token = await stream.beginPublishSessionForTesting()
        let pipeline = await stream.encodedMediaPipelineForTesting
        let output = await stream.encodedMediaOutputForTesting
        try await pipeline.startEncoding()
        let codecEpoch = try #require(await pipeline.activeCodecEpochForTesting)
        let sampleBuffer = try #require(Self.makeCompressedVideoSampleBuffer(
            payload: [0, 0, 0, 2, 0x65, 0x88],
            presentationTimeStamp: CMTime(value: 1, timescale: 30),
            decodeTimeStamp: .invalid
        ))

        for sequence in 1...2 {
            output.encodedMediaPipeline(
                pipeline,
                didOutput: .init(
                    codecEpoch: codecEpoch,
                    formatEpoch: 0,
                    deliverySequence: UInt64(sequence),
                    sampleBuffer: sampleBuffer
                )
            )
        }
        await output.waitForIdle()

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected duplicate video timestamp to terminate the pipeline")
        } catch RTMPEncodedMediaOutputError.invalidVideoTimestamp {
            // Expected.
        } catch {
            Issue.record("Unexpected video output error: \(error)")
        }
        #expect(output.reportedFailureCountForTesting == 1)
        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func audioTimestampFailureFromRTMPAdapterTerminatesPipelineExactlyOnce() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let token = await stream.beginPublishSessionForTesting()
        let pipeline = await stream.encodedMediaPipelineForTesting
        let output = await stream.encodedMediaOutputForTesting
        try await pipeline.startEncoding()
        let codecEpoch = try #require(await pipeline.activeCodecEpochForTesting)
        let sampleBuffer = try #require(Self.makeCompressedAudioSampleBuffer(
            payload: [0x11, 0x22, 0x33],
            presentationTimeStamp: CMTime(value: 44_100, timescale: 44_100)
        ))

        for sequence in 1...2 {
            output.encodedMediaPipeline(
                pipeline,
                didOutput: .init(
                    codecEpoch: codecEpoch,
                    formatEpoch: 0,
                    deliverySequence: UInt64(sequence),
                    sampleBuffer: sampleBuffer
                )
            )
        }
        await output.waitForIdle()

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected duplicate audio timestamp to terminate the pipeline")
        } catch RTMPEncodedMediaOutputError.invalidAudioTimestamp {
            // Expected.
        } catch {
            Issue.record("Unexpected audio output error: \(error)")
        }
        #expect(output.reportedFailureCountForTesting == 1)
        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func changedVideoFormatHeaderFactoryFailureTerminatesPipelineExactlyOnce() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        await stream.setEncodedPipelineVideoHeaderFactoryForTesting { _, _, _ in
            nil
        }
        let token = await stream.beginPublishSessionForTesting()
        let pipeline = await stream.encodedMediaPipelineForTesting
        let output = await stream.encodedMediaOutputForTesting
        try await pipeline.startEncoding()
        let codecEpoch = try #require(await pipeline.activeCodecEpochForTesting)
        let sampleBuffer = try #require(Self.makeCompressedVideoSampleBuffer(
            payload: [0, 0, 0, 2, 0x65, 0x88],
            presentationTimeStamp: CMTime(value: 1, timescale: 30),
            decodeTimeStamp: .invalid
        ))

        output.encodedMediaPipeline(
            pipeline,
            didOutput: .init(
                codecEpoch: codecEpoch,
                formatEpoch: 0,
                deliverySequence: 1,
                sampleBuffer: sampleBuffer
            )
        )
        await output.waitForIdle()

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected changed video format header failure")
        } catch RTMPEncodedMediaOutputError.failedToCreateVideoSequenceHeader {
            // Expected.
        } catch {
            Issue.record("Unexpected video header error: \(error)")
        }
        #expect(output.reportedFailureCountForTesting == 1)
        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func changedAudioFormatHeaderFactoryFailureTerminatesPipelineExactlyOnce() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        await stream.setEncodedPipelineAudioHeaderFactoryForTesting { _, _, _ in
            nil
        }
        let token = await stream.beginPublishSessionForTesting()
        let pipeline = await stream.encodedMediaPipelineForTesting
        let output = await stream.encodedMediaOutputForTesting
        try await pipeline.startEncoding()
        let codecEpoch = try #require(await pipeline.activeCodecEpochForTesting)
        let sampleBuffer = try #require(Self.makeCompressedAudioSampleBuffer(
            payload: [0x11, 0x22, 0x33],
            presentationTimeStamp: CMTime(value: 44_100, timescale: 44_100)
        ))

        output.encodedMediaPipeline(
            pipeline,
            didOutput: .init(
                codecEpoch: codecEpoch,
                formatEpoch: 0,
                deliverySequence: 1,
                sampleBuffer: sampleBuffer
            )
        )
        await output.waitForIdle()

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected changed audio format header failure")
        } catch RTMPEncodedMediaOutputError.failedToCreateAudioSequenceHeader {
            // Expected.
        } catch {
            Issue.record("Unexpected audio header error: \(error)")
        }
        #expect(output.reportedFailureCountForTesting == 1)
        await stream.finishPublishSessionForTesting(token)
    }

    @Test
    func compressedPrePublishInputsPopulateMetadataSnapshot() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let video = try #require(Self.makeCompressedVideoSampleBuffer(
            payload: [0, 0, 0, 2, 0x65, 0x88],
            presentationTimeStamp: CMTime(value: 1, timescale: 30),
            decodeTimeStamp: .invalid
        ))
        let audio = try #require(Self.makeCompressedAudioBuffer())

        await stream.append(video)
        await stream.append(
            audio,
            when: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1.0))
        )

        let metadata = await stream.makeMetadataForTesting()
        #expect(metadata["width"] != nil)
        #expect(metadata["height"] != nil)
        #expect(metadata["videocodecid"] != nil)
        #expect(metadata["audiocodecid"] != nil)
        #expect(metadata["audiosamplerate"] != nil)
    }

    @Test
    func mixerRawVideoNotificationsRemainInIngressOrder() async throws {
        let stream = RTMPStream(connection: RTMPConnection())
        let output = RawOutputSpy()
        await stream.addOutput(output)
        let first = try #require(Self.makeRawVideoSampleBuffer())
        let second = try #require(Self.makeRawVideoSampleBuffer())

        stream.mixer(MediaMixer(), didOutput: first)
        stream.mixer(MediaMixer(), didOutput: second)
        try await Self.waitUntil { output.videoSamples.count == 2 }

        #expect(output.videoSamples[0] === first)
        #expect(output.videoSamples[1] === second)
        await stream.removeOutput(output)
    }

    private final class LegacyObserver: RTMPEncodedStreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var storedSamples: [CMSampleBuffer] = []

        var samples: [CMSampleBuffer] {
            lock.withLock { storedSamples }
        }

        func stream(_ stream: RTMPStream, didOutputEncoded sampleBuffer: CMSampleBuffer) {
            lock.withLock {
                storedSamples.append(sampleBuffer)
            }
        }
    }

    private final class MessageProbe: @unchecked Sendable {
        struct Message: Sendable {
            let timestamp: UInt32
            let payloadFingerprint: Data
        }

        private let lock = NSLock()
        private var storedMessages: [Message] = []

        var messages: [Message] {
            lock.withLock { storedMessages }
        }

        func record(timestamp: UInt32, payload: Data) {
            lock.withLock {
                storedMessages.append(.init(
                    timestamp: timestamp,
                    payloadFingerprint: payload
                ))
            }
        }
    }

    private final class RawOutputSpy: StreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var storedVideoSamples: [CMSampleBuffer] = []

        var videoSamples: [CMSampleBuffer] {
            lock.withLock { storedVideoSamples }
        }

        func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        }

        func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
            lock.withLock {
                storedVideoSamples.append(video)
            }
        }
    }

    private final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var permits = 0

        var wait: @Sendable () async -> Void {
            { [self] in
                await withCheckedContinuation { continuation in
                    let shouldResume = lock.withLock {
                        if permits > 0 {
                            permits -= 1
                            return true
                        }
                        waiter = continuation
                        return false
                    }
                    if shouldResume {
                        continuation.resume()
                    }
                }
            }
        }

        func signal() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                if let waiter = self.waiter {
                    self.waiter = nil
                    return waiter
                }
                permits += 1
                return nil
            }
            waiter?.resume()
        }
    }

    private static func payloadFingerprint(_ sampleBuffer: CMSampleBuffer) -> Data {
        (try? sampleBuffer.dataBuffer?.dataBytes()) ?? Data()
    }

    private static func makeCompressedVideoSampleBuffer(
        payload: [UInt8],
        presentationTimeStamp: CMTime,
        decodeTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1e, 0xe9, 0x01, 0x40, 0x7b, 0x20]
        let pps: [UInt8] = [0x68, 0xce, 0x3c, 0x80]
        var formatDescription: CMFormatDescription?
        let formatStatus = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                let parameterSetPointers = [
                    spsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                ]
                let parameterSetSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSetPointers.count,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
            }
        }
        guard formatStatus == noErr, let formatDescription else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }
        guard payload.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }) == noErr else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: decodeTimeStamp
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [payload.count],
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func makeCompressedAudioSampleBuffer(
        payload: [UInt8],
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }
        guard payload.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }) == noErr else {
            return nil
        }

        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 1024,
            mDataByteSize: UInt32(payload.count)
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: &packetDescription,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func makeCompressedAudioBuffer() -> AVAudioCompressedBuffer? {
        guard
            let inputFormat = AVAudioFormat(
                standardFormatWithSampleRate: 44_100,
                channels: 1
            ),
            let outputFormat = AudioCodecSettings.Format.aac.makeOutputAudioFormat(
                inputFormat,
                sampleRate: 0,
                channelMap: nil
            ) else {
            return nil
        }
        let buffer = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: 1_024
        )
        let payload = [UInt8](arrayLiteral: 0x11, 0x22, 0x33)
        payload.withUnsafeBytes {
            buffer.data.copyMemory(from: $0.baseAddress!, byteCount: payload.count)
        }
        buffer.byteLength = UInt32(payload.count)
        buffer.packetCount = 1
        buffer.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 1_024,
            mDataByteSize: UInt32(payload.count)
        )
        return buffer
    }

    private static func makeRawVideoSampleBuffer() -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
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

    private static func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw WaitError.timedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func waitUntilAsync(
        timeout: TimeInterval = 2,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else {
                throw WaitError.timedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func dispatchStatus(
        _ code: RTMPStream.Code,
        level: String = "status",
        to stream: RTMPStream
    ) async {
        let message = RTMPCommandMessage(
            streamId: 0,
            transactionId: 0,
            objectEncoding: .amf0,
            commandName: "onStatus",
            commandObject: nil,
            arguments: [[
                "code": code.rawValue,
                "level": level,
                "description": code.rawValue
            ]]
        )
        await stream.dispatch(message, type: .zero)
    }

    private enum WaitError: Error {
        case timedOut
    }
}
