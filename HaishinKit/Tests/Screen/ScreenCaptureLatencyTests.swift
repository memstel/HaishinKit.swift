import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

/// The offscreen screen stamps a frame with its display tick minus the camera's capture latency. The latency is
/// measured on every camera frame against the last rendered tick, so a camera frame that arrives just before or just
/// after a render measures a whole frame apart. The stamps must still be one display frame apart.
@ScreenActor
@Suite struct ScreenCaptureLatencyTests {
    private static let frame = 1.0 / 60
    private static let start = 100.0

    /// SplitMix64: the same order of arrivals on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Renders `tick` and returns its frame's stamp, or nil when the screen dropped the frame.
    @discardableResult
    private func render(_ screen: Screen, tick: Int) -> Double? {
        let time = DisplayLinkTime(
            timestamp: Self.start + Double(tick) * Self.frame,
            targetTimestamp: Self.start + Double(tick + 1) * Self.frame
        )
        return screen.makeSampleBuffer(time)?.presentationTimeStamp.seconds
    }

    private func capture(_ tick: Int, latency: Double) -> CMTime {
        CMTime(seconds: Self.start + Double(tick) * Self.frame - latency, preferredTimescale: 1_000_000_000)
    }

    @Test func cameraFramesAroundTheTickKeepTheStampsOneFrameApart() {
        let screen = Screen()
        screen.size = .init(width: 32, height: 18)
        var generator = SeededGenerator(state: 7)
        // As on a device, the first frames go out before the first camera frame is measured (latency 0); the first
        // frame with the measured latency then stamps earlier than they did and is dropped. Counted from tick 3 on.
        var stamps: [Int: Double] = [:]
        render(screen, tick: 0)
        for tick in 1...300 {
            // Captured 4 ms before its tick; measured against this tick's or the previous tick's target.
            let camera = capture(tick, latency: 0.004)
            if Bool.random(using: &generator) {
                screen.setVideoCaptureLatency(camera)
                stamps[tick] = render(screen, tick: tick)
            } else {
                stamps[tick] = render(screen, tick: tick)
                screen.setVideoCaptureLatency(camera)
            }
        }
        for tick in 3...300 {
            #expect(stamps[tick] != nil, "tick \(tick): no frame is dropped for a stamp that went back")
        }
        for tick in 4...300 {
            guard let stamp = stamps[tick], let previous = stamps[tick - 1] else { continue }
            #expect(abs(stamp - previous - Self.frame) < 0.001, "tick \(tick): \((stamp - previous) * 1000) ms apart")
        }
        // Between the two measurements (4 ms and 4 ms + a frame).
        #expect(screen.videoCaptureLatency > 0.004 && screen.videoCaptureLatency < 0.004 + Self.frame)
    }

    @Test func aNewCaptureLatencyIsTakenAtOnce() {
        let screen = Screen()
        screen.size = .init(width: 32, height: 18)
        render(screen, tick: 0)
        screen.setVideoCaptureLatency(capture(0, latency: -Self.frame + 0.004))
        #expect(abs(screen.videoCaptureLatency - 0.004) < 0.0002, "the first measurement")
        // A camera restarted with half a second of latency.
        screen.setVideoCaptureLatency(capture(0, latency: -Self.frame + 0.5))
        #expect(abs(screen.videoCaptureLatency - 0.5) < 0.0002, "a large change is not averaged in")
    }
}
