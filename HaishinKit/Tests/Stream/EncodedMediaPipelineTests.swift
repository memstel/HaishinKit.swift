import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import HaishinKit

@Suite(.serialized) struct EncodedMediaPipelineTests {
    @Test func startEncodingThrowsWhilePreviousEpochIsStopping() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        try await pipeline.startEncoding()

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }

        do {
            try await pipeline.startEncoding()
            Issue.record("Expected startEncoding() to reject a new epoch while stopping")
        } catch {
            // Expected: a prior epoch still owns the controlled drain.
        }

        outgoing.completeVideoInputDrain()
        try await stopTask.value
    }

    @Test func concurrentStopCallersJoinTheSameDrainAndFailure() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.stopRunningError = ControlledOutgoing.Error.drainFailed
        let secondStopJoined = LockedFlag()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            testHooks: .init(
                didJoinStoppingTask: {
                    secondStopJoined.set()
                }
            )
        )
        let output = OutputSpy()
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()

        let firstStopTask = Task {
            await Self.stopResult(for: pipeline)
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }

        let secondStopFinished = LockedFlag()
        let secondStopTask = Task {
            let result = await Self.stopResult(for: pipeline)
            secondStopFinished.set()
            return result
        }
        try await Self.waitUntil {
            secondStopJoined.value
        }
        #expect(secondStopFinished.value == false)

        outgoing.completeVideoInputDrain()

        #expect(await firstStopTask.value == .drainFailed)
        #expect(await secondStopTask.value == .drainFailed)
        #expect(outgoing.stopRunningCallCount == 1)
        #expect(output.terminalEvents.count == 1)
    }

    @Test func outputAddedWhileStoppingJoinsOnlyTheNextCodecEpoch() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        guard let stoppingTail = Self.makeVideoSampleBuffer(
            presentationTimeStamp: .zero
        ) else {
            Issue.record("Expected a video sample for the stopping tail")
            return
        }
        outgoing.encodedVideoOutputOnStop = stoppingTail
        let stoppingBarrier = ControlledStoppingTaskBarrier()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            testHooks: .init(stoppingTaskBarrier: stoppingBarrier.wait)
        )
        try await pipeline.startEncoding()

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            stoppingBarrier.hasEntered
        }

        let nextEpochOutput = OutputSpy()
        await pipeline.addOutput(nextEpochOutput)
        stoppingBarrier.release()
        try await stopTask.value

        #expect(nextEpochOutput.samples.isEmpty)
        #expect(nextEpochOutput.terminalEvents.isEmpty)

        outgoing.encodedVideoOutputOnStop = nil
        try await pipeline.startEncoding()
        try await pipeline.stopEncoding()

        #expect(nextEpochOutput.samples.isEmpty)
        #expect(nextEpochOutput.terminalEvents.count == 1)
    }

    @Test func videoMixerCallbacksAdmittedBeforeStopDrainInOrderAndRejectPostClose() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            ingressConfiguration: .init(
                audioCapacity: 8,
                videoCapacity: 64
            )
        )
        try await pipeline.startEncoding()
        let mixer = MediaMixer()

        let sampleBuffers = try (0..<64).map { sequence in
            try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: CMTimeValue(sequence), timescale: 30)
            ))
        }
        await Task.detached(priority: .background) {
            for sampleBuffer in sampleBuffers {
                pipeline.mixer(mixer, didOutput: sampleBuffer)
            }
        }.value

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }
        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 999, timescale: 30)
            ))
        )

        outgoing.completeVideoInputDrain()
        try await stopTask.value

        #expect(outgoing.appendedVideoPresentationTimeStamps == (0..<64).map {
            CMTime(value: CMTimeValue($0), timescale: 30)
        })
    }

    @Test func videoIngressOverflowDrainsAcceptedPrefixAndTerminatesEpoch() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        outgoing.blockNextEncodedVideoAppend()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            ingressConfiguration: .init(
                audioCapacity: 8,
                videoCapacity: 1
            )
        )
        try await pipeline.startEncoding()
        let mixer = MediaMixer()
        let attemptedCount = 3

        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 0, timescale: 30)
            ))
        )
        try await Self.waitUntil {
            outgoing.isEncodedVideoAppendBlocked
        }
        for sequence in 1..<attemptedCount {
            pipeline.mixer(
                mixer,
                didOutput: try #require(Self.makeVideoSampleBuffer(
                    presentationTimeStamp: CMTime(
                        value: CMTimeValue(sequence),
                        timescale: 30
                    )
                ))
            )
        }
        outgoing.releaseBlockedEncodedVideoAppend()

        try await Self.waitUntil {
            outgoing.didStopRunning
        }
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected bounded video ingress overflow to terminate the epoch")
        } catch EncodedMediaPipeline.Error.videoIngressOverflow {
            let accepted = outgoing.appendedVideoPresentationTimeStamps
            #expect(accepted.isEmpty == false)
            #expect(accepted.count < attemptedCount)
            #expect(accepted == (0..<accepted.count).map {
                CMTime(value: CMTimeValue($0), timescale: 30)
            })
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func blockedVideoCodecCannotBeBypassedBySecondUnboundedQueue() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        outgoing.deferVideoInputUntilFinish = true
        outgoing.blockNextEncodedVideoAppend()
        let scheduler = ControlledAsyncOperationScheduler()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            ingressConfiguration: .init(
                audioCapacity: 8,
                videoCapacity: 1
            ),
            overflowFailureScheduler: scheduler.schedule
        )
        try await pipeline.startEncoding()
        let mixer = MediaMixer()

        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: .zero
            ))
        )
        try await Self.waitUntil {
            outgoing.isEncodedVideoAppendBlocked || outgoing.queuedVideoInputCount == 1
        }
        for sequence in 1...2 {
            pipeline.mixer(
                mixer,
                didOutput: try #require(Self.makeVideoSampleBuffer(
                    presentationTimeStamp: CMTime(
                        value: CMTimeValue(sequence),
                        timescale: 30
                    )
                ))
            )
        }
        try await Self.waitUntil {
            scheduler.pendingCount == 1 || outgoing.queuedVideoInputCount == 3
        }

        let delayedFailure = scheduler.takeFirst()
        #expect(outgoing.queuedVideoInputCount == 0)
        #expect(delayedFailure != nil)
        outgoing.releaseBlockedEncodedVideoAppend()

        if let delayedFailure {
            await delayedFailure()
            try await Self.waitUntil {
                outgoing.didStopRunning
            }
            do {
                try await pipeline.stopEncoding()
                Issue.record("Expected bounded video ingress overflow")
            } catch EncodedMediaPipeline.Error.videoIngressOverflow {
                #expect(
                    outgoing.appendedVideoPresentationTimeStamps
                        == [CMTime(value: 0, timescale: 30), CMTime(value: 1, timescale: 30)]
                )
            }
        } else {
            try await pipeline.stopEncoding()
            Issue.record("Video input bypassed bounded ingress through a second queue")
        }
    }

    @Test func authoritativeOutputOverflowFailsThePipelineWhileOptionalOutputsRemainBounded() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        let scheduler = ControlledAsyncOperationScheduler()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            overflowFailureScheduler: scheduler.schedule
        )
        try await pipeline.startEncoding()

        let codecEpoch = try #require(await pipeline.activeCodecEpochForTesting)
        pipeline.reportOutputFailure(
            EncodedMediaPipeline.Error.outputIngressOverflow,
            codecEpoch: codecEpoch
        )
        try await Self.waitUntil {
            scheduler.pendingCount > 0
        }
        let delayedFailure = try #require(scheduler.takeFirst())
        await delayedFailure()

        try await Self.waitUntil {
            outgoing.didStopRunning
        }
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected authoritative output overflow to fail the pipeline")
        } catch EncodedMediaPipeline.Error.outputIngressOverflow {
            // Expected: RTMP-like authoritative delivery must fail explicitly.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func delayedAuthoritativeOverflowFromPreviousCodecEpochCannotStopRestartedEpoch() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        let scheduler = ControlledAsyncOperationScheduler()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            overflowFailureScheduler: scheduler.schedule
        )
        try await pipeline.startEncoding()

        let codecEpoch = try #require(await pipeline.activeCodecEpochForTesting)
        pipeline.reportOutputFailure(
            EncodedMediaPipeline.Error.outputIngressOverflow,
            codecEpoch: codecEpoch
        )
        try await Self.waitUntil {
            scheduler.pendingCount > 0
        }
        let delayedFailure = try #require(scheduler.takeFirst())

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected epoch A to retain its authoritative overflow")
        } catch EncodedMediaPipeline.Error.outputIngressOverflow {
            // Expected: the synchronous latch belongs to epoch A.
        } catch {
            Issue.record("Unexpected epoch A terminal error: \(error)")
        }

        try await pipeline.startEncoding()
        await delayedFailure()
        try await pipeline.stopEncoding()

        #expect(outgoing.stopRunningCallCount == 2)
    }

    @Test func videoOverflowSurvivesStopBeforeDelayedActorNotification() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        outgoing.blockNextEncodedVideoAppend()
        let scheduler = ControlledAsyncOperationScheduler()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            ingressConfiguration: .init(
                audioCapacity: 8,
                videoCapacity: 1
            ),
            overflowFailureScheduler: scheduler.schedule
        )
        try await pipeline.startEncoding()
        let mixer = MediaMixer()

        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: .zero
            ))
        )
        try await Self.waitUntil {
            outgoing.isEncodedVideoAppendBlocked
        }
        for sequence in 1...2 {
            pipeline.mixer(
                mixer,
                didOutput: try #require(Self.makeVideoSampleBuffer(
                    presentationTimeStamp: CMTime(
                        value: CMTimeValue(sequence),
                        timescale: 30
                    )
                ))
            )
        }
        let delayedFailure = try #require(scheduler.takeFirst())
        outgoing.releaseBlockedEncodedVideoAppend()
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected the stopping epoch to retain its video ingress overflow")
        } catch EncodedMediaPipeline.Error.videoIngressOverflow {
            // Expected: overflow belongs to the epoch even before actor notification runs.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }

        try await pipeline.startEncoding()
        await delayedFailure()
        try await pipeline.stopEncoding()

        #expect(outgoing.stopRunningCallCount == 2)
    }

    @Test func audioOverflowSurvivesStopBeforeDelayedActorNotification() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        outgoing.blockNextAudioAppend()
        let scheduler = ControlledAsyncOperationScheduler()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            ingressConfiguration: .init(
                audioCapacity: 1,
                videoCapacity: 3
            ),
            overflowFailureScheduler: scheduler.schedule
        )
        try await pipeline.startEncoding()
        let mixer = MediaMixer()
        let buffer = try #require(AVAudioPCMBufferFactory.makeSinWave())

        pipeline.mixer(
            mixer,
            didOutput: buffer,
            when: AVAudioTime(sampleTime: 0, atRate: 44_100)
        )
        try await Self.waitUntil {
            outgoing.isAudioAppendBlocked
        }
        for sequence in 1...2 {
            pipeline.mixer(
                mixer,
                didOutput: buffer,
                when: AVAudioTime(
                    sampleTime: AVAudioFramePosition(sequence * 1_024),
                    atRate: 44_100
                )
            )
        }
        let delayedFailure = try #require(scheduler.takeFirst())
        outgoing.releaseBlockedAudioAppend()
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected the stopping epoch to retain its audio ingress overflow")
        } catch EncodedMediaPipeline.Error.audioIngressOverflow {
            // Expected: overflow belongs to the epoch even before actor notification runs.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }

        try await pipeline.startEncoding()
        await delayedFailure()
        try await pipeline.stopEncoding()

        #expect(outgoing.stopRunningCallCount == 2)
    }

    @Test func audioMixerCallbacksAdmittedBeforeStopDrainInOrderAndRejectPostClose() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            ingressConfiguration: .init(
                audioCapacity: 64,
                videoCapacity: 3
            )
        )
        try await pipeline.startEncoding()
        let mixer = MediaMixer()
        let buffers = try (0..<64).map { _ in
            try #require(AVAudioPCMBufferFactory.makeSinWave())
        }
        await Task.detached(priority: .background) {
            for (sequence, buffer) in buffers.enumerated() {
                pipeline.mixer(
                    mixer,
                    didOutput: buffer,
                    when: AVAudioTime(
                        sampleTime: AVAudioFramePosition(sequence * 1_024),
                        atRate: 44_100
                    )
                )
            }
        }.value

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }
        pipeline.mixer(
            mixer,
            didOutput: try #require(AVAudioPCMBufferFactory.makeSinWave()),
            when: AVAudioTime(sampleTime: 999_999, atRate: 44_100)
        )

        outgoing.completeVideoInputDrain()
        try await stopTask.value

        #expect(outgoing.appendedAudioSampleTimes == (0..<64).map {
            AVAudioFramePosition($0 * 1_024)
        })
    }

    @Test func audioIngressOverflowDrainsAcceptedPrefixAndTerminatesEpoch() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        outgoing.blockNextAudioAppend()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            ingressConfiguration: .init(
                audioCapacity: 1,
                videoCapacity: 3
            )
        )
        try await pipeline.startEncoding()
        let mixer = MediaMixer()
        let buffer = try #require(AVAudioPCMBufferFactory.makeSinWave())
        let attemptedCount = 3

        pipeline.mixer(
            mixer,
            didOutput: buffer,
            when: AVAudioTime(sampleTime: 0, atRate: 44_100)
        )
        try await Self.waitUntil {
            outgoing.isAudioAppendBlocked
        }
        for sequence in 1..<attemptedCount {
            pipeline.mixer(
                mixer,
                didOutput: buffer,
                when: AVAudioTime(
                    sampleTime: AVAudioFramePosition(sequence * 1_024),
                    atRate: 44_100
                )
            )
        }
        outgoing.releaseBlockedAudioAppend()

        try await Self.waitUntil {
            outgoing.didStopRunning
        }
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected bounded audio ingress overflow to terminate the epoch")
        } catch EncodedMediaPipeline.Error.audioIngressOverflow {
            let accepted = outgoing.appendedAudioSampleTimes
            #expect(accepted.isEmpty == false)
            #expect(accepted.count < attemptedCount)
            #expect(accepted == (0..<accepted.count).map {
                AVAudioFramePosition($0 * 1_024)
            })
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func rejectsVideoSettingsThatRequireSessionRecreationWhileRunning() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        var changedSettings = outgoing.videoSettings
        changedSettings.videoSize = .init(width: 1_280, height: 720)
        try await pipeline.startEncoding()

        do {
            try await pipeline.setVideoSettings(changedSettings)
            Issue.record("Expected a running codec to reject session-recreating settings")
        } catch {
            // Expected: the active codec epoch cannot recreate its session.
        }

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }
        outgoing.completeVideoInputDrain()
        try await stopTask.value
    }

    @Test func rejectsVideoSettingsChangesWhileStopping() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        let originalSettings = outgoing.videoSettings
        var changedSettings = originalSettings
        changedSettings.videoSize = .init(width: 1_280, height: 720)
        try await pipeline.startEncoding()

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }
        do {
            try await pipeline.setVideoSettings(changedSettings)
            Issue.record("Expected video settings to be rejected while stopping")
        } catch {
            #expect(outgoing.videoSettings.videoSize == originalSettings.videoSize)
        }

        outgoing.completeVideoInputDrain()
        try await stopTask.value
    }

    @Test func rejectsAudioSampleRateChangeThatRequiresConverterRecreationWhileRunning() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        let currentSettings = outgoing.audioSettings
        let changedSettings = AudioCodecSettings(
            bitRate: currentSettings.bitRate,
            downmix: currentSettings.downmix,
            channelMap: currentSettings.channelMap,
            sampleRate: 48_000,
            format: currentSettings.format
        )
        try await pipeline.startEncoding()

        do {
            try await pipeline.setAudioSettings(changedSettings)
            Issue.record("Expected a running codec to reject converter-recreating settings")
        } catch {
            // Expected: the active codec epoch cannot recreate its converter.
        }

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }
        outgoing.completeVideoInputDrain()
        try await stopTask.value
    }

    @Test func rejectsAudioSettingsChangesWhileStopping() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        let originalSettings = outgoing.audioSettings
        let changedSettings = AudioCodecSettings(
            bitRate: originalSettings.bitRate,
            downmix: originalSettings.downmix,
            channelMap: originalSettings.channelMap,
            sampleRate: 48_000,
            format: originalSettings.format
        )
        try await pipeline.startEncoding()

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }
        do {
            try await pipeline.setAudioSettings(changedSettings)
            Issue.record("Expected audio settings to be rejected while stopping")
        } catch {
            #expect(outgoing.audioSettings.sampleRate == originalSettings.sampleRate)
        }

        outgoing.completeVideoInputDrain()
        try await stopTask.value
    }

    @Test func stopEncodingPropagatesTerminalCodecDrainFailure() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.stopRunningError = ControlledOutgoing.Error.drainFailed
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        try await pipeline.startEncoding()
        outgoing.completeVideoInputDrain()

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected stopEncoding() to propagate the codec drain failure")
        } catch ControlledOutgoing.Error.drainFailed {
            // Expected terminal failure.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func stopEncodingDeliversCompressedOutputProducedDuringCodecDrainBeforeTerminal() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        let output = OutputSpy()
        let drainSample = try #require(Self.makeCompressedVideoSampleBuffer(
            presentationTimeStamp: CMTime(value: 1, timescale: 30)
        ))
        outgoing.encodedVideoOutputOnStop = drainSample
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()
        outgoing.completeVideoInputDrain()

        try await pipeline.stopEncoding()

        #expect(output.samples.count == 1)
        #expect(output.samples.first?.sampleBuffer === drainSample)
        #expect(output.terminalEvents == [
            .init(
                codecEpoch: try #require(output.samples.first?.codecEpoch),
                lastDeliverySequence: 1
            )
        ])
    }

    @Test func stopEncodingPropagatesFailureRecordedDuringAcceptedInputDrain() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.deferEncodedVideoFailureUntilDrain = true
        outgoing.encodedVideoError = ControlledOutgoing.Error.conversionFailed
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        try await pipeline.startEncoding()

        pipeline.mixer(
            MediaMixer(),
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 1, timescale: 30)
            ))
        )
        try await Self.waitUntil {
            outgoing.appendedVideoPresentationTimeStamps.count == 1
        }

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected a failure recorded during drain to be propagated")
        } catch ControlledOutgoing.Error.conversionFailed {
            // Expected: the accepted pre-close sample failed while draining.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func asynchronousVideoCodecFailureTerminatesAndPropagatesFromPipeline() async throws {
        let outgoing = ControlledOutgoing()
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        try await pipeline.startEncoding()

        outgoing.emitVideoTerminalFailure(.failedToConvert(status: -12_903))

        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }
        outgoing.completeVideoInputDrain()
        try await Self.waitUntil {
            outgoing.didStopRunning
        }

        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected the asynchronous VideoToolbox failure to propagate")
        } catch let error as VTSessionError {
            guard case let .failedToConvert(status) = error else {
                Issue.record("Expected a VideoToolbox conversion failure")
                return
            }
            #expect(status == -12_903)
        }
    }

    @Test func compressedAudioSampleBufferCreationFailureTerminatesPipeline() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            audioSampleBufferFactory: { _, _ in nil }
        )
        try await pipeline.startEncoding()

        outgoing.emitEncodedAudioOutput(try #require(Self.makeCompressedAudioBuffer()))

        try await Self.waitUntil {
            outgoing.didStopRunning
        }
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected AAC sample-buffer creation failure to terminate the epoch")
        } catch EncodedMediaPipeline.Error.failedToCreateCompressedAudioSampleBuffer {
            // Expected terminal failure.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func nonCompressedAudioOutputTerminatesPipeline() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        try await pipeline.startEncoding()

        outgoing.emitEncodedAudioOutput(try #require(
            AVAudioPCMBufferFactory.makeSinWave()
        ))

        try await Self.waitUntil {
            outgoing.didStopRunning
        }
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected non-compressed audio output to terminate the epoch")
        } catch EncodedMediaPipeline.Error.encodedAudioOutputIsNotCompressed {
            // Expected terminal failure.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func unexpectedVideoCodecFailureEndsEpochWithoutManualStop() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        outgoing.encodedVideoError = ControlledOutgoing.Error.conversionFailed
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        let output = OutputSpy()
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()

        pipeline.mixer(
            MediaMixer(),
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 1, timescale: 30)
            ))
        )
        try await Self.waitUntil {
            outgoing.didStopRunning && output.terminalEvents.count == 1
        }

        #expect(output.terminalEvents.count == 1)
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected the completed epoch to retain its terminal failure")
        } catch ControlledOutgoing.Error.conversionFailed {
            // Expected terminal failure.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func unexpectedAudioCodecFailureEndsEpochWithoutManualStop() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        outgoing.encodedAudioError = ControlledOutgoing.Error.conversionFailed
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        let output = OutputSpy()
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()

        pipeline.mixer(
            MediaMixer(),
            didOutput: try #require(AVAudioPCMBufferFactory.makeSinWave()),
            when: AVAudioTime(sampleTime: 0, atRate: 44_100)
        )
        try await Self.waitUntil {
            outgoing.didStopRunning && output.terminalEvents.count == 1
        }

        #expect(output.terminalEvents.count == 1)
        do {
            try await pipeline.stopEncoding()
            Issue.record("Expected the completed epoch to retain its terminal failure")
        } catch ControlledOutgoing.Error.conversionFailed {
            // Expected terminal failure.
        } catch {
            Issue.record("Unexpected terminal error: \(error)")
        }
    }

    @Test func startsWithoutRTMPAndEmitsH264AACBeforeTerminalEvent() async throws {
        let pipeline = EncodedMediaPipeline(
            outgoing: OutgoingStream(),
            ingressConfiguration: .init(
                audioCapacity: 16,
                videoCapacity: 8
            )
        )
        let output = OutputSpy()
        try await pipeline.setVideoSettings(Self.videoSettings)
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()

        let mixer = MediaMixer()
        for frame in 0..<4 {
            let sampleBuffer = try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 30)
            ))
            pipeline.mixer(mixer, didOutput: sampleBuffer)
        }
        for packet in 0..<12 {
            let buffer = try #require(AVAudioPCMBufferFactory.makeSinWave())
            pipeline.mixer(
                mixer,
                didOutput: buffer,
                when: AVAudioTime(sampleTime: AVAudioFramePosition(packet * 1_024), atRate: 44_100)
            )
        }

        try await Self.waitUntil {
            output.mediaTypes.contains(.video) && output.mediaTypes.contains(.audio)
        }
        try await pipeline.stopEncoding()

        let samples = output.samples
        let video = try #require(samples.first { $0.sampleBuffer.formatDescription?.mediaType == .video })
        let audio = try #require(samples.first { $0.sampleBuffer.formatDescription?.mediaType == .audio })
        #expect(video.sampleBuffer.formatDescription?.mediaSubType == .h264)
        #expect(audio.sampleBuffer.formatDescription?.mediaSubType == .mpeg4AAC)
        #expect(video.sampleBuffer.isNotSync == false)
        #expect(Set(samples.map(\.codecEpoch)).count == 1)
        #expect(samples.map(\.deliverySequence) == Array(1...UInt64(samples.count)))
        #expect(output.terminalEvents == [
            .init(
                codecEpoch: video.codecEpoch,
                lastDeliverySequence: samples.last?.deliverySequence ?? 0
            )
        ])
    }

    @Test func addingAndRemovingOutputDoesNotRestartCodecEpoch() async throws {
        let pipeline = EncodedMediaPipeline()
        let first = OutputSpy()
        let second = OutputSpy()
        try await pipeline.setVideoSettings(Self.videoSettings)
        await pipeline.addOutput(first)
        try await pipeline.startEncoding()

        let mixer = MediaMixer()
        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 1, timescale: 30)
            ))
        )
        try await Self.waitUntil { first.videoSamples.count == 1 }
        let codecEpoch = try #require(first.samples.first?.codecEpoch)

        await pipeline.addOutput(second)
        await pipeline.requestVideoKeyFrame()
        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 2, timescale: 30)
            ))
        )
        try await Self.waitUntil { second.videoSamples.count == 1 }
        #expect(second.samples.first?.codecEpoch == codecEpoch)

        await pipeline.removeOutput(second)
        let removedCount = second.samples.count
        let retainedCount = first.samples.count
        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 3, timescale: 30)
            ))
        )
        try await Self.waitUntil {
            first.samples.count == retainedCount + 1
        }
        #expect(second.samples.count == removedCount)
        try await pipeline.stopEncoding()
    }

    @Test func removeOutputDuringStopAwaitsStoppingFanoutBarrier() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        let removalBarrierEnqueued = LockedFlag()
        let pipeline = EncodedMediaPipeline(
            outgoing: outgoing,
            fanoutTestHooks: .init(
                didEnqueueRemovalBarrier: {
                    removalBarrierEnqueued.set()
                }
            )
        )
        let output = OutputSpy(blocksSampleDelivery: true)
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()

        outgoing.emitEncodedVideoOutput(try #require(Self.makeVideoSampleBuffer(
            presentationTimeStamp: .zero
        )))
        try await Self.waitUntil {
            output.callbackInvocationCount == 1
        }

        let stopTask = Task {
            try await pipeline.stopEncoding()
        }
        try await Self.waitUntil {
            outgoing.didRequestVideoInputFinish
        }

        let removalFinished = LockedFlag()
        let removalTask = Task {
            await pipeline.removeOutput(output)
            removalFinished.set()
        }
        try await Self.waitUntil {
            removalBarrierEnqueued.value
        }
        #expect(removalFinished.value == false)

        output.releaseBlockedSampleDelivery()
        await removalTask.value
        #expect(removalFinished.value)
        try await stopTask.value

        #expect(output.terminalEvents.isEmpty)
    }

    @Test func keyFrameRequestAppliesToNextAcceptedVideoFrame() async throws {
        let pipeline = EncodedMediaPipeline()
        let output = OutputSpy()
        var settings = Self.videoSettings
        settings.maxKeyFrameIntervalDuration = 30
        try await pipeline.setVideoSettings(settings)
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()

        let mixer = MediaMixer()
        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 1, timescale: 30)
            ))
        )
        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 2, timescale: 30)
            ))
        )
        try await Self.waitUntil { output.videoSamples.count == 2 }
        #expect(output.videoSamples[0].sampleBuffer.isNotSync == false)
        #expect(output.videoSamples[1].sampleBuffer.isNotSync == true)

        await pipeline.requestVideoKeyFrame()
        pipeline.mixer(
            mixer,
            didOutput: try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: 3, timescale: 30)
            ))
        )
        try await Self.waitUntil { output.videoSamples.count == 3 }
        #expect(output.videoSamples[2].sampleBuffer.isNotSync == false)
        try await pipeline.stopEncoding()
    }

    @Test func keyFrameFenceIsUnavailableWhenIdleOrStopping() async throws {
        let idlePipeline = EncodedMediaPipeline(outgoing: ControlledOutgoing())
        do {
            _ = try await idlePipeline.requestVideoKeyFrameAndCaptureDeliverySequence()
            Issue.record("Expected an idle pipeline to reject a key-frame fence request")
        } catch EncodedMediaPipeline.Error.keyFrameFenceUnavailable {
            // Expected: there is no active fanout in the idle lifecycle.
        } catch {
            Issue.record("Unexpected idle fence error: \(error)")
        }

        let stoppingOutgoing = ControlledOutgoing()
        stoppingOutgoing.automaticallyCompleteVideoInputOnFinish = true
        let stoppingBarrier = ControlledStoppingTaskBarrier()
        let stoppingPipeline = EncodedMediaPipeline(
            outgoing: stoppingOutgoing,
            testHooks: .init(stoppingTaskBarrier: stoppingBarrier.wait)
        )
        try await stoppingPipeline.startEncoding()
        let stopTask = Task {
            try await stoppingPipeline.stopEncoding()
        }
        try await Self.waitUntil { stoppingBarrier.hasEntered }

        do {
            _ = try await stoppingPipeline.requestVideoKeyFrameAndCaptureDeliverySequence()
            Issue.record("Expected a stopping pipeline to reject a key-frame fence request")
        } catch EncodedMediaPipeline.Error.keyFrameFenceUnavailable {
            // Expected: the stopping fanout is no longer admitted for new requests.
        } catch {
            Issue.record("Unexpected stopping fence error: \(error)")
        }

        stoppingBarrier.release()
        try await stopTask.value
    }

    @Test func keyFrameFenceEndsBeforeTheNextAcceptedOutput() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        let output = OutputSpy()
        await pipeline.addOutput(output)
        try await pipeline.startEncoding()

        let sampleCount = 3
        for sequence in 1...sampleCount {
            outgoing.emitEncodedVideoOutput(try #require(Self.makeVideoSampleBuffer(
                presentationTimeStamp: CMTime(value: CMTimeValue(sequence), timescale: 30)
            )))
        }
        try await Self.waitUntil { output.videoSamples.count == sampleCount }

        guard let requestedSample = Self.makeVideoSampleBuffer(
            presentationTimeStamp: CMTime(
                value: CMTimeValue(sampleCount + 1),
                timescale: 30
            )
        ) else {
            Issue.record("Expected a requested key-frame sample")
            return
        }
        outgoing.encodedVideoOutputOnKeyFrameRequest = requestedSample
        let fence = try await pipeline.requestVideoKeyFrameAndCaptureDeliverySequence()
        #expect(fence == UInt64(sampleCount))
        #expect(outgoing.videoKeyFrameRequestCount == 1)

        try await Self.waitUntil { output.videoSamples.count == sampleCount + 1 }

        let deliveredSample = try #require(output.videoSamples.last)
        #expect(deliveredSample.deliverySequence == fence + 1)
        #expect(deliveredSample.sampleBuffer.isNotSync == false)
        try await pipeline.stopEncoding()
    }

    @Test func voidKeyFrameRequestStillDelegatesWhileRunning() async throws {
        let outgoing = ControlledOutgoing()
        outgoing.automaticallyCompleteVideoInputOnFinish = true
        let pipeline = EncodedMediaPipeline(outgoing: outgoing)
        try await pipeline.startEncoding()

        await pipeline.requestVideoKeyFrame()

        #expect(outgoing.videoKeyFrameRequestCount == 1)
        try await pipeline.stopEncoding()
    }

    private static var videoSettings: VideoCodecSettings {
        .init(
            videoSize: .init(width: 64, height: 64),
            maxKeyFrameIntervalDuration: 1,
            allowFrameReordering: false,
            isHardwareAcceleratedEnabled: false,
            expectedFrameRate: 30
        )
    }

    private struct TerminalEvent: Equatable {
        let codecEpoch: UUID
        let lastDeliverySequence: UInt64
    }

    private enum StopResult: Equatable {
        case success
        case drainFailed
        case unexpectedFailure
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = false

        var value: Bool {
            lock.withLock {
                storedValue
            }
        }

        func set() {
            lock.withLock {
                storedValue = true
            }
        }
    }

    private final class ControlledAsyncOperationScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var operations: [@Sendable () async -> Void] = []

        var schedule: @Sendable (@escaping @Sendable () async -> Void) -> Void {
            { [weak self] operation in
                guard let self else {
                    return
                }
                lock.withLock {
                    operations.append(operation)
                }
            }
        }

        var pendingCount: Int {
            lock.withLock {
                operations.count
            }
        }

        func takeFirst() -> (@Sendable () async -> Void)? {
            lock.withLock {
                guard operations.isEmpty == false else {
                    return nil
                }
                return operations.removeFirst()
            }
        }
    }

    private final class OutputSpy: EncodedMediaOutput, @unchecked Sendable {
        private let lock = NSLock()
        private let sampleDeliveryGate: DispatchSemaphore?
        private var storedSamples: [EncodedMediaSample] = []
        private var storedTerminalEvents: [TerminalEvent] = []
        private var storedCallbackInvocationCount = 0
        private var storedShouldBlockSampleDelivery: Bool

        init(blocksSampleDelivery: Bool = false) {
            sampleDeliveryGate = blocksSampleDelivery ? DispatchSemaphore(value: 0) : nil
            storedShouldBlockSampleDelivery = blocksSampleDelivery
        }

        var samples: [EncodedMediaSample] {
            lock.lock()
            defer { lock.unlock() }
            return storedSamples
        }

        var videoSamples: [EncodedMediaSample] {
            samples.filter { $0.sampleBuffer.formatDescription?.mediaType == .video }
        }

        var mediaTypes: Set<CMFormatDescription.MediaType> {
            Set(samples.compactMap { $0.sampleBuffer.formatDescription?.mediaType })
        }

        var terminalEvents: [TerminalEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storedTerminalEvents
        }

        var callbackInvocationCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedCallbackInvocationCount
        }

        func releaseBlockedSampleDelivery() {
            sampleDeliveryGate?.signal()
        }

        func encodedMediaPipeline(
            _ pipeline: EncodedMediaPipeline,
            didOutput sample: EncodedMediaSample
        ) {
            lock.lock()
            storedCallbackInvocationCount += 1
            let shouldBlock = storedShouldBlockSampleDelivery
            storedShouldBlockSampleDelivery = false
            lock.unlock()
            if shouldBlock {
                sampleDeliveryGate?.wait()
            }
            lock.lock()
            storedSamples.append(sample)
            lock.unlock()
        }

        func encodedMediaPipeline(
            _ pipeline: EncodedMediaPipeline,
            didEndCodecEpoch codecEpoch: UUID,
            lastDeliverySequence: UInt64
        ) {
            lock.lock()
            storedTerminalEvents.append(.init(
                codecEpoch: codecEpoch,
                lastDeliverySequence: lastDeliverySequence
            ))
            lock.unlock()
        }
    }

    private final class ControlledOutgoing: EncodedMediaPipelineOutgoing, @unchecked Sendable {
        enum Error: Swift.Error {
            case conversionFailed
            case drainFailed
        }

        private let lock = NSLock()
        private var storedDidRequestVideoInputFinish = false
        private var storedDidStopRunning = false
        private var storedStopRunningCallCount = 0
        private var storedShouldBlockNextAudioAppend = false
        private var storedIsAudioAppendBlocked = false
        private var storedShouldBlockNextEncodedVideoAppend = false
        private var storedIsEncodedVideoAppendBlocked = false
        private var storedQueuedVideoInputCount = 0
        private var storedAppendedAudioSampleTimes: [AVAudioFramePosition] = []
        private var storedAppendedVideoPresentationTimeStamps: [CMTime] = []
        private var deferredVideoInput: [CMSampleBuffer] = []
        private let blockedAudioAppendSemaphore = DispatchSemaphore(value: 0)
        private let blockedEncodedVideoAppendSemaphore = DispatchSemaphore(value: 0)
        private let completeVideoInputDrainGate = AsyncGate()
        private let audioOutputContinuation: AsyncStream<(AVAudioBuffer, AVAudioTime)>.Continuation
        private let videoOutputContinuation: AsyncStream<CMSampleBuffer>.Continuation
        private let videoTerminalFailureContinuation: AsyncStream<any Swift.Error>.Continuation
        private let videoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation

        let audioOutputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)>
        let videoOutputStream: AsyncStream<CMSampleBuffer>
        let videoTerminalFailureStream: AsyncStream<any Swift.Error>
        let videoInputStream: AsyncStream<CMSampleBuffer>
        var audioSettings: AudioCodecSettings = .default
        var videoSettings: VideoCodecSettings = .default
        var automaticallyCompleteVideoInputOnFinish = false
        var deferVideoInputUntilFinish = false
        var deferEncodedVideoFailureUntilDrain = false
        var encodedAudioError: (any Swift.Error)?
        var encodedVideoError: (any Swift.Error)?
        var encodedVideoOutputOnStop: CMSampleBuffer?
        var encodedVideoOutputOnKeyFrameRequest: CMSampleBuffer?
        var stopRunningError: (any Swift.Error)?

        private var storedVideoKeyFrameRequestCount = 0

        var didRequestVideoInputFinish: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedDidRequestVideoInputFinish
        }

        var didStopRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedDidStopRunning
        }

        var stopRunningCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedStopRunningCallCount
        }

        var videoKeyFrameRequestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedVideoKeyFrameRequestCount
        }

        var isAudioAppendBlocked: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedIsAudioAppendBlocked
        }

        var isEncodedVideoAppendBlocked: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storedIsEncodedVideoAppendBlocked
        }

        var queuedVideoInputCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedQueuedVideoInputCount
        }

        var appendedVideoPresentationTimeStamps: [CMTime] {
            lock.lock()
            defer { lock.unlock() }
            return storedAppendedVideoPresentationTimeStamps
        }

        var appendedAudioSampleTimes: [AVAudioFramePosition] {
            lock.lock()
            defer { lock.unlock() }
            return storedAppendedAudioSampleTimes
        }

        init() {
            var audioOutputContinuation: AsyncStream<(AVAudioBuffer, AVAudioTime)>.Continuation!
            audioOutputStream = AsyncStream {
                audioOutputContinuation = $0
            }
            self.audioOutputContinuation = audioOutputContinuation

            var videoOutputContinuation: AsyncStream<CMSampleBuffer>.Continuation!
            videoOutputStream = AsyncStream {
                videoOutputContinuation = $0
            }
            self.videoOutputContinuation = videoOutputContinuation

            var videoTerminalFailureContinuation: AsyncStream<any Swift.Error>.Continuation!
            videoTerminalFailureStream = AsyncStream {
                videoTerminalFailureContinuation = $0
            }
            self.videoTerminalFailureContinuation = videoTerminalFailureContinuation

            var videoInputContinuation: AsyncStream<CMSampleBuffer>.Continuation!
            videoInputStream = AsyncStream {
                videoInputContinuation = $0
            }
            self.videoInputContinuation = videoInputContinuation
        }

        func append(_ sampleBuffer: CMSampleBuffer) {
            lock.lock()
            storedQueuedVideoInputCount += 1
            storedAppendedVideoPresentationTimeStamps.append(sampleBuffer.presentationTimeStamp)
            let shouldDefer = deferVideoInputUntilFinish
            if shouldDefer {
                deferredVideoInput.append(sampleBuffer)
            }
            lock.unlock()
            if !shouldDefer {
                videoInputContinuation.yield(sampleBuffer)
            }
        }

        func appendEncodedAudio(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) throws {
            if let encodedAudioError {
                throw encodedAudioError
            }
            lock.lock()
            storedAppendedAudioSampleTimes.append(when.sampleTime)
            let shouldBlock = storedShouldBlockNextAudioAppend
            storedShouldBlockNextAudioAppend = false
            storedIsAudioAppendBlocked = shouldBlock
            lock.unlock()
            if shouldBlock {
                blockedAudioAppendSemaphore.wait()
                lock.lock()
                storedIsAudioAppendBlocked = false
                lock.unlock()
            }
        }

        func blockNextAudioAppend() {
            lock.lock()
            storedShouldBlockNextAudioAppend = true
            lock.unlock()
        }

        func releaseBlockedAudioAppend() {
            blockedAudioAppendSemaphore.signal()
        }

        func append(video sampleBuffer: CMSampleBuffer) {
        }

        func appendEncodedVideo(_ sampleBuffer: CMSampleBuffer) throws {
            lock.lock()
            storedAppendedVideoPresentationTimeStamps.append(
                sampleBuffer.presentationTimeStamp
            )
            let shouldDefer = deferEncodedVideoFailureUntilDrain
            if shouldDefer {
                deferredVideoInput.append(sampleBuffer)
            }
            let shouldBlock = storedShouldBlockNextEncodedVideoAppend
            storedShouldBlockNextEncodedVideoAppend = false
            storedIsEncodedVideoAppendBlocked = shouldBlock
            lock.unlock()
            if shouldDefer {
                return
            }
            if let encodedVideoError {
                throw encodedVideoError
            }
            if shouldBlock {
                blockedEncodedVideoAppendSemaphore.wait()
                lock.lock()
                storedIsEncodedVideoAppendBlocked = false
                lock.unlock()
            }
        }

        func blockNextEncodedVideoAppend() {
            lock.lock()
            storedShouldBlockNextEncodedVideoAppend = true
            lock.unlock()
        }

        func releaseBlockedEncodedVideoAppend() {
            blockedEncodedVideoAppendSemaphore.signal()
        }

        func requestVideoKeyFrame() {
            let sampleBuffer = lock.withLock {
                storedVideoKeyFrameRequestCount += 1
                return encodedVideoOutputOnKeyFrameRequest
            }
            if let sampleBuffer {
                videoOutputContinuation.yield(sampleBuffer)
            }
        }

        func completeVideoInputDrain() {
            completeVideoInputDrainGate.signal()
        }

        func emitVideoTerminalFailure(_ failure: VTSessionError) {
            videoTerminalFailureContinuation.yield(failure)
        }

        func emitEncodedVideoOutput(_ sampleBuffer: CMSampleBuffer) {
            videoOutputContinuation.yield(sampleBuffer)
        }

        func emitEncodedAudioOutput(
            _ audioBuffer: AVAudioBuffer,
            when: AVAudioTime = .init(sampleTime: 0, atRate: 44_100)
        ) {
            audioOutputContinuation.yield((audioBuffer, when))
        }

        func startRunning() {
        }

        func stopRunningAndDrain() async throws {
            let shouldComplete = lock.withLock {
                storedDidRequestVideoInputFinish = true
                return automaticallyCompleteVideoInputOnFinish
                    || deferVideoInputUntilFinish
                    || deferEncodedVideoFailureUntilDrain
            }
            if shouldComplete {
                completeVideoInputDrainGate.signal()
            }
            await completeVideoInputDrainGate.wait()
            if let encodedVideoOutputOnStop {
                videoOutputContinuation.yield(encodedVideoOutputOnStop)
            }
            audioOutputContinuation.finish()
            videoOutputContinuation.finish()
            videoTerminalFailureContinuation.finish()
            let hasDeferredVideoInput = lock.withLock {
                storedDidStopRunning = true
                storedStopRunningCallCount += 1
                let hasDeferredVideoInput = deferredVideoInput.isEmpty == false
                deferredVideoInput.removeAll()
                return hasDeferredVideoInput
            }
            if hasDeferredVideoInput, let encodedVideoError {
                throw encodedVideoError
            }
            if let stopRunningError {
                throw stopRunningError
            }
        }
    }

    private final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var permits = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    if permits > 0 {
                        permits -= 1
                        return true
                    }
                    waiters.append(continuation)
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }

        func signal() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                if waiters.isEmpty {
                    permits += 1
                    return nil
                }
                return waiters.removeFirst()
            }
            waiter?.resume()
        }
    }

    private final class ControlledStoppingTaskBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = AsyncGate()
        private var didEnter = false

        var hasEntered: Bool {
            lock.withLock {
                didEnter
            }
        }

        var wait: @Sendable () async -> Void {
            { [self] in
                let shouldWait = lock.withLock {
                    guard !didEnter else {
                        return false
                    }
                    didEnter = true
                    return true
                }
                if shouldWait {
                    await gate.wait()
                }
            }
        }

        func release() {
            gate.signal()
        }
    }

    private static func waitUntil(
        timeout: TimeInterval = 5,
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

    private enum WaitError: Error {
        case timedOut
    }

    private static func stopResult(
        for pipeline: EncodedMediaPipeline
    ) async -> StopResult {
        do {
            try await pipeline.stopEncoding()
            return .success
        } catch ControlledOutgoing.Error.drainFailed {
            return .drainFailed
        } catch {
            return .unexpectedFailure
        }
    }

    private static func makeCompressedVideoSampleBuffer(
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 64,
            height: 64,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }
        let data = Data([0, 0, 0, 2, 0x65, 0x88])
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else {
            return nil
        }
        let replaceStatus = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard replaceStatus == noErr else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
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
            sampleSizeArray: [data.count],
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func makeCompressedAudioBuffer() -> AVAudioCompressedBuffer? {
        guard
            let input = AVAudioPCMBufferFactory.makeSinWave(),
            let outputFormat = AudioCodecSettings.Format.aac.makeOutputAudioFormat(
                input.format,
                sampleRate: 0,
                channelMap: nil
            ) else {
            return nil
        }
        return AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: 1_024
        )
    }

    private static func makeVideoSampleBuffer(
        presentationTimeStamp: CMTime
    ) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, 0x40, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

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
            presentationTimeStamp: presentationTimeStamp,
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
