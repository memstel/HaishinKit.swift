import AVFoundation
import Foundation

package struct EncodedMediaReleasedDeliveryAccounting: Sendable, Equatable {
    package let totalCount: UInt64
    package let compactedCount: UInt64
    package let retainedRanges: [ClosedRange<UInt64>]

    package var retainedSequenceCount: UInt64 {
        retainedRanges.reduce(into: 0) { count, range in
            count += range.upperBound - range.lowerBound + 1
        }
    }
}

package struct EncodedMediaOutputFanoutTestHooks: Sendable {
    package let didEnqueueRemovalBarrier: @Sendable () -> Void
    package let didEnqueueSampleBeforeLifecycleUnlock: @Sendable () -> Void

    package init(
        didEnqueueRemovalBarrier: @escaping @Sendable () -> Void = {},
        didEnqueueSampleBeforeLifecycleUnlock:
            @escaping @Sendable () -> Void = {}
    ) {
        self.didEnqueueRemovalBarrier = didEnqueueRemovalBarrier
        self.didEnqueueSampleBeforeLifecycleUnlock =
            didEnqueueSampleBeforeLifecycleUnlock
    }
}

package final class EncodedMediaOutputFanout: @unchecked Sendable {
    package static let maximumRetainedReleasedRangeCount = 64

    private let codecEpoch: UUID
    private weak var pipeline: EncodedMediaPipeline?
    private let sampleByteCount: @Sendable (CMSampleBuffer) -> Int
    private let testHooks: EncodedMediaOutputFanoutTestHooks
    private let didOverflow: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var deliveries: [ObjectIdentifier: Delivery] = [:]
    private var deliverySequence: UInt64 = 0
    private var formatEpoch: UInt64 = 0
    private var formats: [CMFormatDescription.MediaType: CMFormatDescription] = [:]
    private var isFinished = false

    package init(
        codecEpoch: UUID,
        pipeline: EncodedMediaPipeline,
        sampleByteCount: @escaping @Sendable (CMSampleBuffer) -> Int = {
            CMSampleBufferGetTotalSampleSize($0)
        },
        testHooks: EncodedMediaOutputFanoutTestHooks = .init(),
        didOverflow: @escaping @Sendable (UUID) -> Void = { _ in }
    ) {
        self.codecEpoch = codecEpoch
        self.pipeline = pipeline
        self.sampleByteCount = sampleByteCount
        self.testHooks = testHooks
        self.didOverflow = didOverflow
    }

    package func addOutput(
        _ output: some EncodedMediaOutput,
        policy: EncodedMediaOutputIngressPolicy
    ) {
        lock.lock()
        defer { lock.unlock() }
        let identifier = ObjectIdentifier(output)
        guard deliveries[identifier] == nil, !isFinished else {
            return
        }
        deliveries[identifier] = Delivery(
            output: output,
            pipeline: pipeline,
            policy: policy,
            didEnqueueRemovalBarrier: testHooks.didEnqueueRemovalBarrier
        )
    }

    package func removeOutput(_ output: some EncodedMediaOutput) async {
        let delivery = lock.withLock {
            deliveries.removeValue(forKey: ObjectIdentifier(output))
        }
        await delivery?.cancelAndWait()
    }

    package func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if let formatDescription = sampleBuffer.formatDescription {
            let mediaType = formatDescription.mediaType
            if let previous = formats[mediaType] {
                if !CMFormatDescriptionEqual(previous, otherFormatDescription: formatDescription) {
                    formatEpoch += 1
                    formats[mediaType] = formatDescription
                }
            } else {
                formats[mediaType] = formatDescription
            }
        }
        deliverySequence += 1
        let sample = EncodedMediaSample(
            codecEpoch: codecEpoch,
            formatEpoch: formatEpoch,
            deliverySequence: deliverySequence,
            sampleBuffer: sampleBuffer
        )
        let byteCount = sampleByteCount(sampleBuffer)
        var shouldReportOverflow = false
        for delivery in deliveries.values {
            if delivery.enqueue(sample, byteCount: byteCount) {
                shouldReportOverflow = true
            }
        }
        testHooks.didEnqueueSampleBeforeLifecycleUnlock()
        lock.unlock()

        if shouldReportOverflow {
            didOverflow(codecEpoch)
        }
    }

    /// Returns the current global delivery sequence while this fanout is active.
    ///
    /// `nil` identifies a finished fanout. A value of `0` is a valid snapshot
    /// for an active fanout that has not accepted a sample yet.
    package func currentDeliverySequenceSnapshot() -> UInt64? {
        lock.withLock {
            guard !isFinished else {
                return nil
            }
            return deliverySequence
        }
    }

    package func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let lastDeliverySequence = deliverySequence
        for delivery in deliveries.values {
            delivery.finish(
                codecEpoch: codecEpoch,
                lastDeliverySequence: lastDeliverySequence
            )
        }
        lock.unlock()
    }

    package func finishAndWait() async {
        let state: (lastDeliverySequence: UInt64, deliveries: [Delivery])? = lock.withLock {
            guard !isFinished else {
                return nil
            }
            isFinished = true
            let activeDeliveries = Array(deliveries.values)
            for delivery in activeDeliveries {
                delivery.finish(
                    codecEpoch: codecEpoch,
                    lastDeliverySequence: deliverySequence
                )
            }
            return (deliverySequence, activeDeliveries)
        }
        guard let state else {
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for delivery in state.deliveries {
                group.addTask {
                    await delivery.waitForIdle()
                }
            }
        }
    }

    package func releasedDeliveryAccounting(
        for output: some EncodedMediaOutput
    ) -> EncodedMediaReleasedDeliveryAccounting {
        lock.lock()
        let delivery = deliveries[ObjectIdentifier(output)]
        lock.unlock()
        return delivery?.releasedDeliveryAccounting ?? .init(
            totalCount: 0,
            compactedCount: 0,
            retainedRanges: []
        )
    }

    package var retainedDeliveryCount: Int {
        lock.withLock {
            deliveries.count
        }
    }
}

private extension EncodedMediaOutputFanout {
    final class Delivery: @unchecked Sendable {
        private enum Event: @unchecked Sendable {
            case sample(EncodedMediaSample, byteCount: Int)
            case terminal(codecEpoch: UUID, lastDeliverySequence: UInt64)
        }

        private let output: any EncodedMediaOutput
        private weak var pipeline: EncodedMediaPipeline?
        private let policy: EncodedMediaOutputIngressPolicy
        private let didEnqueueRemovalBarrier: @Sendable () -> Void
        private let lock = NSLock()
        private let queue = DispatchQueue(
            label: "com.haishinkit.encoded-media-output",
            qos: .userInitiated
        )
        private var active = true
        private var accepting = true
        private var pendingSampleCount = 0
        private var pendingByteCount = 0
        private var hasReportedOverflow = false
        private var releasedDeliveryLedger = ReleasedDeliveryLedger()

        init(
            output: any EncodedMediaOutput,
            pipeline: EncodedMediaPipeline?,
            policy: EncodedMediaOutputIngressPolicy,
            didEnqueueRemovalBarrier: @escaping @Sendable () -> Void
        ) {
            self.output = output
            self.pipeline = pipeline
            self.policy = policy
            self.didEnqueueRemovalBarrier = didEnqueueRemovalBarrier
        }

        var releasedDeliveryAccounting: EncodedMediaReleasedDeliveryAccounting {
            lock.lock()
            defer { lock.unlock() }
            return .init(
                totalCount: releasedDeliveryLedger.totalCount,
                compactedCount: releasedDeliveryLedger.compactedCount,
                retainedRanges: releasedDeliveryLedger.retainedRanges
            )
        }

        func enqueue(_ sample: EncodedMediaSample, byteCount: Int) -> Bool {
            lock.lock()
            guard active, accepting else {
                releasedDeliveryLedger.record(sample.deliverySequence)
                lock.unlock()
                return false
            }
            guard
                0 <= byteCount,
                byteCount <= policy.maximumByteCount,
                pendingSampleCount < policy.maximumSampleCount,
                pendingByteCount <= policy.maximumByteCount - byteCount else {
                releasedDeliveryLedger.record(sample.deliverySequence)
                let shouldReportOverflow =
                    policy.overflowDisposition == .failPipeline && !hasReportedOverflow
                if shouldReportOverflow {
                    hasReportedOverflow = true
                    accepting = false
                }
                lock.unlock()
                return shouldReportOverflow
            }
            pendingSampleCount += 1
            pendingByteCount += byteCount
            dispatch(.sample(sample, byteCount: byteCount))
            lock.unlock()
            return false
        }

        func finish(codecEpoch: UUID, lastDeliverySequence: UInt64) {
            lock.withLock {
                guard active else {
                    return
                }
                dispatch(.terminal(
                    codecEpoch: codecEpoch,
                    lastDeliverySequence: lastDeliverySequence
                ))
            }
        }

        func waitForIdle() async {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume()
                }
            }
        }

        func cancelAndWait() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    active = false
                    accepting = false
                    queue.async {
                        continuation.resume()
                    }
                }
                didEnqueueRemovalBarrier()
            }
        }

        private func dispatch(_ event: Event) {
            queue.async { [weak self] in
                self?.deliver(event)
            }
        }

        private func deliver(_ event: Event) {
            switch event {
            case let .sample(sample, byteCount):
                lock.lock()
                let shouldDeliver = active
                if !shouldDeliver {
                    releasedDeliveryLedger.record(sample.deliverySequence)
                }
                let pipeline = pipeline
                lock.unlock()
                if shouldDeliver, let pipeline {
                    output.encodedMediaPipeline(pipeline, didOutput: sample)
                }
                lock.lock()
                pendingSampleCount -= 1
                pendingByteCount -= byteCount
                lock.unlock()
            case let .terminal(codecEpoch, lastDeliverySequence):
                lock.lock()
                let shouldDeliver = active
                let pipeline = pipeline
                lock.unlock()
                if shouldDeliver, let pipeline {
                    output.encodedMediaPipeline(
                        pipeline,
                        didEndCodecEpoch: codecEpoch,
                        lastDeliverySequence: lastDeliverySequence
                    )
                }
            }
        }
    }

    struct ReleasedDeliveryLedger {
        private(set) var totalCount: UInt64 = 0
        private(set) var compactedCount: UInt64 = 0
        private(set) var retainedRanges: [ClosedRange<UInt64>] = []

        mutating func record(_ sequence: UInt64) {
            totalCount += 1
            if
                let last = retainedRanges.last,
                last.upperBound < UInt64.max,
                last.upperBound + 1 == sequence {
                retainedRanges[retainedRanges.count - 1] = last.lowerBound...sequence
            } else {
                retainedRanges.append(sequence...sequence)
            }
            if retainedRanges.count > EncodedMediaOutputFanout.maximumRetainedReleasedRangeCount {
                let compacted = retainedRanges.removeFirst()
                compactedCount += compacted.upperBound - compacted.lowerBound + 1
            }
        }
    }
}
