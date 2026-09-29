import CoreMedia
import Foundation
import Testing

@testable import HaishinKit

/// Offscreen output timing across a passthrough → offscreen re-entry, e.g. a
/// broadcast that falls back to preview after a failed connect and resumes.
@ScreenActor
@Suite struct ScreenTimingTests {
    private static let frameInterval = 1.0 / 60.0

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    private func frame(at timestamp: Double) -> DisplayLinkTime {
        DisplayLinkTime(timestamp: timestamp, targetTimestamp: timestamp + Self.frameInterval)
    }

    @Test func restartDoesNotMeasureCaptureLatencyAgainstThePreviousSession() throws {
        let screen = Screen()
        // Last offscreen frame before the mixer went to passthrough at t=100.
        _ = try #require(screen.makeSampleBuffer(frame(at: 100)))

        // Offscreen restarts five seconds later; a camera frame arrives before
        // the first new render.
        screen.resetTiming()
        screen.setVideoCaptureLatency(time(104.99))
        let first = try #require(screen.makeSampleBuffer(frame(at: 105)))

        // A stale target would give a latency of about -5 s and a PTS near 110.
        #expect(abs(first.presentationTimeStamp.seconds - 105) < 0.001)
    }

    @Test func latencyIsMeasuredAgainstTheFirstRenderAfterRestart() throws {
        let screen = Screen()
        _ = try #require(screen.makeSampleBuffer(frame(at: 100)))

        screen.resetTiming()
        _ = try #require(screen.makeSampleBuffer(frame(at: 105)))
        // The camera frame lags the new render target by ~26.7 ms.
        screen.setVideoCaptureLatency(time(105 + Self.frameInterval - 0.0267))
        let next = try #require(screen.makeSampleBuffer(frame(at: 105 + 2 * Self.frameInterval)))

        let expected = 105 + 2 * Self.frameInterval - 0.0267
        #expect(abs(next.presentationTimeStamp.seconds - expected) < 0.001)
    }

    @Test func outputStaysMonotonicAcrossRestart() throws {
        let screen = Screen()
        let before = try #require(screen.makeSampleBuffer(frame(at: 100)))

        screen.resetTiming()
        let after = try #require(screen.makeSampleBuffer(frame(at: 100.5)))

        #expect(after.presentationTimeStamp > before.presentationTimeStamp)
    }
}
