import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import HaishinKit

@Suite struct EncodedMediaOutputFanoutTests {
    @Test func labelsSamplesWithStableCodecEpochAndMonotonicDeliverySequence() async throws {
        let codecEpoch = UUID()
        let pipeline = EncodedMediaPipeline()
        let fanout = EncodedMediaOutputFanout(codecEpoch: codecEpoch, pipeline: pipeline)
        let output = OutputSpy()
        fanout.addOutput(output, policy: .init(maximumSampleCount: 8, maximumByteCount: 1_024))

        let first = try #require(Self.makeSampleBuffer(presentationTimeStamp: .zero))
        let second = try #require(Self.makeSampleBuffer(presentationTimeStamp: CMTime(value: 1, timescale: 30)))
        fanout.enqueue(first)
        fanout.enqueue(second)

        try await Self.waitUntil { output.samples.count == 2 }
        let samples = output.samples
        #expect(samples.map(\.codecEpoch) == [codecEpoch, codecEpoch])
        #expect(samples.map(\.deliverySequence) == [1, 2])
        #expect(samples.map(\.formatEpoch) == [0, 0])
        #expect(samples[0].sampleBuffer === first)
        #expect(samples[1].sampleBuffer === second)
    }

    @Test func incrementsFormatEpochBeforeDeliveringChangedFormat() async throws {
        let pipeline = EncodedMediaPipeline()
        let fanout = EncodedMediaOutputFanout(codecEpoch: UUID(), pipeline: pipeline)
        let output = OutputSpy()
        fanout.addOutput(output, policy: .init(maximumSampleCount: 8, maximumByteCount: 4_096))

        let first = try #require(Self.makeSampleBuffer(width: 16, height: 16))
        let initialAudio = try #require(CMAudioSampleBufferFactory.makeSilence(
            44_100,
            numSamples: 1_024,
            channels: 1
        ))
        let changed = try #require(Self.makeSampleBuffer(width: 32, height: 16))
        fanout.enqueue(first)
        fanout.enqueue(initialAudio)
        fanout.enqueue(changed)

        try await Self.waitUntil { output.samples.count == 3 }
        #expect(output.samples.map(\.formatEpoch) == [0, 0, 1])
    }

    @Test func slowBoundedOutputDoesNotBlockAnotherOutput() async throws {
        let pipeline = EncodedMediaPipeline()
        let fanout = EncodedMediaOutputFanout(codecEpoch: UUID(), pipeline: pipeline)
        let slow = OutputSpy(blocksSampleDelivery: true)
        let fast = OutputSpy()
        fanout.addOutput(slow, policy: .init(maximumSampleCount: 1, maximumByteCount: 1_024))
        fanout.addOutput(fast, policy: .init(maximumSampleCount: 8, maximumByteCount: 1_024))

        for sequence in 0..<4 {
            let sample = try #require(Self.makeSampleBuffer(
                presentationTimeStamp: CMTime(value: CMTimeValue(sequence), timescale: 30)
            ))
            fanout.enqueue(sample)
        }

        try await Self.waitUntil { fast.samples.count == 4 }
        try await Self.waitUntil { slow.callbackInvocationCount == 1 }
        #expect(fast.samples.map(\.deliverySequence) == [1, 2, 3, 4])
        #expect(slow.samples.count < fast.samples.count)
        #expect(fanout.releasedDeliveryAccounting(for: slow).totalCount > 0)
        slow.releaseBlockedSampleDelivery()
        await fanout.removeOutput(slow)
    }

    @Test func defaultOutputPolicyStillDropsNewestSamplesWithoutAffectingAnotherOutput() async throws {
        let pipeline = EncodedMediaPipeline()
        let bounded = OutputSpy(blocksSampleDelivery: true)
        let fast = OutputSpy()
        let fanout = EncodedMediaOutputFanout(codecEpoch: UUID(), pipeline: pipeline)
        fanout.addOutput(
            bounded,
            policy: .init(
                maximumSampleCount: 1,
                maximumByteCount: 1_024,
                overflowDisposition: .dropNewest
            )
        )
        fanout.addOutput(fast, policy: .default)

        for sequence in 0..<4 {
            fanout.enqueue(try #require(Self.makeSampleBuffer(
                presentationTimeStamp: CMTime(value: CMTimeValue(sequence), timescale: 30)
            )))
        }

        try await Self.waitUntil { fast.samples.count == 4 }
        #expect(fast.samples.map(\.deliverySequence) == [1, 2, 3, 4])
        #expect(fanout.releasedDeliveryAccounting(for: bounded).totalCount > 0)
        bounded.releaseBlockedSampleDelivery()
        await fanout.removeOutput(bounded)
    }

    @Test func removalReleasesPendingSamplesAndTerminalEventIsDeliveredOnce() async throws {
        let codecEpoch = UUID()
        let pipeline = EncodedMediaPipeline()
        let removalBarrierEnqueued = LockedFlag()
        let fanout = EncodedMediaOutputFanout(
            codecEpoch: codecEpoch,
            pipeline: pipeline,
            testHooks: .init(
                didEnqueueRemovalBarrier: {
                    removalBarrierEnqueued.set()
                }
            )
        )
        let removed = OutputSpy(blocksSampleDelivery: true)
        let retained = OutputSpy()
        fanout.addOutput(removed, policy: .init(maximumSampleCount: 8, maximumByteCount: 1_024))
        fanout.addOutput(retained, policy: .init(maximumSampleCount: 8, maximumByteCount: 1_024))

        for sequence in 0..<3 {
            let sample = try #require(Self.makeSampleBuffer(
                presentationTimeStamp: CMTime(value: CMTimeValue(sequence), timescale: 30)
            ))
            fanout.enqueue(sample)
        }
        try await Self.waitUntil {
            removed.callbackInvocationCount == 1
        }
        let removalFinished = LockedFlag()
        let removalTask = Task {
            await fanout.removeOutput(removed)
            removalFinished.set()
        }
        try await Self.waitUntil {
            removalBarrierEnqueued.value
        }
        #expect(removalFinished.value == false)
        removed.releaseBlockedSampleDelivery()
        await removalTask.value
        #expect(removalFinished.value)
        fanout.finish()
        fanout.finish()

        try await Self.waitUntil { retained.terminalEvents.count == 1 }
        #expect(retained.terminalEvents == [.init(codecEpoch: codecEpoch, lastDeliverySequence: 3)])
        #expect(removed.terminalEvents.isEmpty)
        #expect(fanout.retainedDeliveryCount == 1)
    }

    @Test func removalWaitsForDeliveryBarrierAndReleasesRetiredDeliveryState() async throws {
        let pipeline = EncodedMediaPipeline()
        let removalBarrierEnqueued = LockedFlag()
        let fanout = EncodedMediaOutputFanout(
            codecEpoch: UUID(),
            pipeline: pipeline,
            testHooks: .init(
                didEnqueueRemovalBarrier: {
                    removalBarrierEnqueued.set()
                }
            )
        )
        let output = OutputSpy(blocksSampleDelivery: true)
        fanout.addOutput(
            output,
            policy: .init(maximumSampleCount: 8, maximumByteCount: 1_024)
        )
        fanout.enqueue(try #require(Self.makeSampleBuffer()))
        try await Self.waitUntil {
            output.callbackInvocationCount == 1
        }

        let removalFinished = LockedFlag()
        let removalTask = Task {
            await fanout.removeOutput(output)
            removalFinished.set()
        }
        try await Self.waitUntil {
            removalBarrierEnqueued.value
        }
        #expect(removalFinished.value == false)

        output.releaseBlockedSampleDelivery()
        await removalTask.value
        #expect(removalFinished.value)
        #expect(fanout.retainedDeliveryCount == 0)
    }

    @Test func releasedDeliveryAccountingRemainsBoundedForLongSequenceStream() async throws {
        let pipeline = EncodedMediaPipeline()
        let fanout = EncodedMediaOutputFanout(
            codecEpoch: UUID(),
            pipeline: pipeline,
            sampleByteCount: { sampleBuffer in
                sampleBuffer.presentationTimeStamp == .zero ? 0 : 2
            }
        )
        let output = OutputSpy(blocksSampleDelivery: true)
        let releasedCount = 4_096
        fanout.addOutput(
            output,
            policy: .init(
                maximumSampleCount: releasedCount + 1,
                maximumByteCount: 1
            )
        )
        let acceptedSample = try #require(Self.makeSampleBuffer())
        let releasedSample = try #require(Self.makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 1, timescale: 30)
        ))
        fanout.enqueue(acceptedSample)
        try await Self.waitUntil {
            output.callbackInvocationCount == 1
        }

        for sequence in 1...(releasedCount * 2) {
            fanout.enqueue(sequence.isMultiple(of: 2) ? acceptedSample : releasedSample)
        }

        let accounting = fanout.releasedDeliveryAccounting(for: output)
        #expect(accounting.totalCount == UInt64(releasedCount))
        #expect(accounting.compactedCount > 0)
        #expect(
            accounting.retainedRanges.count
                == EncodedMediaOutputFanout.maximumRetainedReleasedRangeCount
        )
        #expect(
            accounting.compactedCount + accounting.retainedSequenceCount
                == accounting.totalCount
        )

        output.releaseBlockedSampleDelivery()
        await fanout.removeOutput(output)
    }

    @Test func pendingByteAccountingRejectsWithoutIntegerOverflow() async throws {
        let pipeline = EncodedMediaPipeline()
        let fanout = EncodedMediaOutputFanout(
            codecEpoch: UUID(),
            pipeline: pipeline,
            sampleByteCount: { sampleBuffer in
                sampleBuffer.presentationTimeStamp == .zero ? Int.max : 1
            }
        )
        let output = OutputSpy(blocksSampleDelivery: true)
        fanout.addOutput(
            output,
            policy: .init(maximumSampleCount: 2, maximumByteCount: Int.max)
        )
        fanout.enqueue(try #require(Self.makeSampleBuffer(
            presentationTimeStamp: .zero
        )))
        try await Self.waitUntil {
            output.callbackInvocationCount == 1
        }

        fanout.enqueue(try #require(Self.makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 1, timescale: 30)
        )))

        let accounting = fanout.releasedDeliveryAccounting(for: output)
        #expect(accounting.totalCount == 1)
        #expect(accounting.retainedRanges == [2...2])

        output.releaseBlockedSampleDelivery()
        await fanout.removeOutput(output)
    }

    @Test func authoritativeOverflowClosesAdmissionButDrainsAcceptedPrefix() async throws {
        let codecEpoch = UUID()
        let pipeline = EncodedMediaPipeline()
        let overflowCount = LockedCounter()
        let fanout = EncodedMediaOutputFanout(
            codecEpoch: codecEpoch,
            pipeline: pipeline,
            didOverflow: { reportedEpoch in
                if reportedEpoch == codecEpoch {
                    overflowCount.increment()
                }
            }
        )
        let output = OutputSpy(blocksSampleDelivery: true)
        fanout.addOutput(
            output,
            policy: .init(
                maximumSampleCount: 1,
                maximumByteCount: 1_024,
                overflowDisposition: .failPipeline
            )
        )

        fanout.enqueue(try #require(Self.makeSampleBuffer(
            presentationTimeStamp: .zero
        )))
        try await Self.waitUntil {
            output.callbackInvocationCount == 1
        }
        fanout.enqueue(try #require(Self.makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 1, timescale: 30)
        )))
        fanout.enqueue(try #require(Self.makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 2, timescale: 30)
        )))
        try await Self.waitUntil {
            overflowCount.value == 1
        }

        output.releaseBlockedSampleDelivery()
        try await Self.waitUntil {
            output.samples.count == 1
        }
        fanout.enqueue(try #require(Self.makeSampleBuffer(
            presentationTimeStamp: CMTime(value: 3, timescale: 30)
        )))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(output.samples.map(\.deliverySequence) == [1])
        #expect(overflowCount.value == 1)
        #expect(fanout.releasedDeliveryAccounting(for: output).totalCount == 3)
    }

    @Test func acceptedSampleAlwaysPrecedesTerminalWhenFinishRacesEnqueue() async throws {
        let hook = BlockingLifecycleHook()
        let codecEpoch = UUID()
        let pipeline = EncodedMediaPipeline()
        let fanout = EncodedMediaOutputFanout(
            codecEpoch: codecEpoch,
            pipeline: pipeline,
            testHooks: .init(
                didEnqueueSampleBeforeLifecycleUnlock: hook.pause
            )
        )
        let output = OrderedOutputSpy()
        fanout.addOutput(
            output,
            policy: .init(maximumSampleCount: 8, maximumByteCount: 1_024)
        )
        let sample = try #require(Self.makeSampleBuffer())

        let enqueueTask = Task.detached {
            fanout.enqueue(sample)
        }
        try await Self.waitUntil {
            hook.hasEntered
        }
        let finishTask = Task.detached {
            fanout.finish()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        hook.release()
        await enqueueTask.value
        await finishTask.value
        try await Self.waitUntil {
            output.events.count == 2
        }

        #expect(output.events == [
            .sample(sequence: 1),
            .terminal(codecEpoch: codecEpoch, lastDeliverySequence: 1)
        ])
    }

    private struct TerminalEvent: Equatable {
        let codecEpoch: UUID
        let lastDeliverySequence: UInt64
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

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = 0

        var value: Int {
            lock.withLock {
                storedValue
            }
        }

        func increment() {
            lock.withLock {
                storedValue += 1
            }
        }
    }

    private final class BlockingLifecycleHook: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var entered = false

        var hasEntered: Bool {
            lock.withLock {
                entered
            }
        }

        var pause: @Sendable () -> Void {
            { [self] in
                lock.withLock {
                    entered = true
                }
                gate.wait()
            }
        }

        func release() {
            gate.signal()
        }
    }

    private final class OrderedOutputSpy: EncodedMediaOutput, @unchecked Sendable {
        enum Event: Equatable {
            case sample(sequence: UInt64)
            case terminal(codecEpoch: UUID, lastDeliverySequence: UInt64)
        }

        private let lock = NSLock()
        private var storedEvents: [Event] = []

        var events: [Event] {
            lock.withLock {
                storedEvents
            }
        }

        func encodedMediaPipeline(
            _ pipeline: EncodedMediaPipeline,
            didOutput sample: EncodedMediaSample
        ) {
            lock.withLock {
                storedEvents.append(.sample(sequence: sample.deliverySequence))
            }
        }

        func encodedMediaPipeline(
            _ pipeline: EncodedMediaPipeline,
            didEndCodecEpoch codecEpoch: UUID,
            lastDeliverySequence: UInt64
        ) {
            lock.withLock {
                storedEvents.append(.terminal(
                    codecEpoch: codecEpoch,
                    lastDeliverySequence: lastDeliverySequence
                ))
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

        init(
            blocksSampleDelivery: Bool = false
        ) {
            sampleDeliveryGate = blocksSampleDelivery ? DispatchSemaphore(value: 0) : nil
            storedShouldBlockSampleDelivery = blocksSampleDelivery
        }

        var samples: [EncodedMediaSample] {
            lock.lock()
            defer { lock.unlock() }
            return storedSamples
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

    private enum WaitError: Error {
        case timedOut
    }

    private static func makeSampleBuffer(
        width: Int32 = 16,
        height: Int32 = 16,
        presentationTimeStamp: CMTime = .zero
    ) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: width,
            height: height,
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
}
