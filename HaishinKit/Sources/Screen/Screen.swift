import AVFoundation
import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// An interface a screen uses to inform its delegate.
public protocol ScreenDelegate: AnyObject {
    /// Tells the receiver to screen object layout phase.
    func screen(_ screen: Screen, willLayout time: CMTime)
}

/// How a screen composes its objects.
public enum ScreenRenderingBackend: Sendable {
    /// Core Image renders the whole picture every frame (`ScreenRendererByGPU`).
    case coreImage
    /// Metal composes textures of the objects; Core Image renders an object only when it hands a new image
    /// (`ScreenRendererByMetal`). SDR only; elsewhere the screen keeps Core Image.
    case metal
}

/// An object that manages offscreen rendering a foundation.
public final class Screen: ScreenObjectContainerConvertible {
    /// The default screen size.
    public static let size = CGSize(width: 1280, height: 720)

    private static let lockFlags = CVPixelBufferLockFlags(rawValue: 0)
    private static let preferredTimescale: CMTimeScale = 1000000000
    /// The capture latency is measured again on every camera frame against the last rendered display tick. Camera and
    /// display are not in phase, so near their phase boundary the measurement flips by a whole frame from one camera
    /// frame to the next; applied as it came, each flip moved a frame's stamp by a frame (two stamps almost equal, then
    /// a two-frame gap), which players show as a stutter of the whole picture. Changes this small are averaged in;
    /// a larger one (a new capture setup) is taken at once.
    static let videoCaptureLatencySmoothing = 0.05
    static let videoCaptureLatencyJump: TimeInterval = 0.05

    /// The total of child counts.
    public var childCounts: Int {
        return root.childCounts
    }

    /// Specifies the delegate object.
    public weak var delegate: (any ScreenDelegate)?

    /// Specifies the video size to use when output a video.
    public var size: CGSize = Screen.size {
        didSet {
            guard size != oldValue else {
                return
            }
            renderer.bounds = .init(origin: .zero, size: size)
            CVPixelBufferPoolCreate(nil, nil, dynamicRangeMode.makePixelBufferAttributes(size), &pixelBufferPool)
        }
    }

    #if os(macOS)
    /// Specifies the background color.
    public var backgroundColor: CGColor = NSColor.black.cgColor {
        didSet {
            guard backgroundColor != oldValue else {
                return
            }
            renderer.backgroundColor = backgroundColor
        }
    }
    #else
    /// Specifies the background color.
    public var backgroundColor: CGColor = UIColor.black.cgColor {
        didSet {
            guard backgroundColor != oldValue else {
                return
            }
            renderer.backgroundColor = backgroundColor
        }
    }
    #endif

    var synchronizationClock: CMClock? {
        get {
            return renderer.synchronizationClock
        }
        set {
            renderer.synchronizationClock = newValue
        }
    }
    var dynamicRangeMode: DynamicRangeMode = .sdr {
        didSet {
            guard dynamicRangeMode != oldValue else {
                return
            }
            renderer = makeRenderer()
            CVPixelBufferPoolCreate(nil, nil, dynamicRangeMode.makePixelBufferAttributes(size), &pixelBufferPool)
        }
    }

    /// How the screen composes its objects. `.metal` falls back to Core Image where Metal is missing or not SDR.
    public var renderingBackend: ScreenRenderingBackend = .coreImage {
        didSet {
            guard renderingBackend != oldValue else {
                return
            }
            renderer = makeRenderer()
        }
    }

    /// Whether the screen composes with Metal now.
    public var isRenderingWithMetal: Bool {
        renderer is ScreenRendererByMetal
    }
    private(set) var renderer: (any ScreenRenderer) = ScreenRendererByGPU(dynamicRangeMode: .sdr) {
        didSet {
            renderer.bounds = oldValue.bounds
            renderer.backgroundColor = oldValue.backgroundColor
            renderer.synchronizationClock = oldValue.synchronizationClock
        }
    }
    private(set) var targetTimestamp: TimeInterval = 0.0
    private(set) var videoTrackScreenObject = VideoScreenObject()
    private(set) var videoCaptureLatency: TimeInterval = 0.0
    private var hasVideoCaptureLatency = false
    private(set) var root: ScreenObjectContainer = .init()
    private var outputFormat: CMFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool? {
        didSet {
            outputFormat = nil
        }
    }
    private var presentationTimeStamp: CMTime = .zero

    /// Creates a screen object.
    public init() {
        try? addChild(videoTrackScreenObject)
        CVPixelBufferPoolCreate(nil, nil, dynamicRangeMode.makePixelBufferAttributes(size), &pixelBufferPool)
    }

    /// Adds the specified screen object as a child of the current screen object container.
    public func addChild(_ child: ScreenObject?) throws {
        try root.addChild(child)
    }

    /// Removes the specified screen object as a child of the current screen object container.
    public func removeChild(_ child: ScreenObject?) {
        root.removeChild(child)
    }

    /// Registers a video effect.
    public func registerVideoEffect(_ effect: some VideoEffect) -> Bool {
        return videoTrackScreenObject.registerVideoEffect(effect)
    }

    /// Unregisters a video effect.
    public func unregisterVideoEffect(_ effect: some VideoEffect) -> Bool {
        return videoTrackScreenObject.unregisterVideoEffect(effect)
    }

    public func findById(_ id: String) -> ScreenObject? {
        return root.findById(id)
    }

    func append(_ track: UInt8, buffer: CMSampleBuffer) {
        let screens: [VideoScreenObject] = root.getScreenObjects()
        for screen in screens where screen.track == track {
            screen.enqueue(buffer)
        }
    }

    func makeSampleBuffer(_ updateFrame: DisplayLinkTime) -> CMSampleBuffer? {
        defer {
            targetTimestamp = updateFrame.targetTimestamp
        }
        var pixelBuffer: CVPixelBuffer?
        pixelBufferPool?.createPixelBuffer(&pixelBuffer)
        guard let pixelBuffer else {
            return nil
        }
        if outputFormat == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &outputFormat
            )
        }
        guard let outputFormat else {
            return nil
        }
        if let dictionary = CVBufferCopyAttachments(pixelBuffer, .shouldNotPropagate) {
            CVBufferSetAttachments(pixelBuffer, dictionary, .shouldPropagate)
        }
        let presentationTimeStamp = CMTime(seconds: updateFrame.timestamp - videoCaptureLatency, preferredTimescale: Self.preferredTimescale)
        guard self.presentationTimeStamp <= presentationTimeStamp else {
            return nil
        }
        self.presentationTimeStamp = presentationTimeStamp
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(seconds: updateFrame.targetTimestamp - updateFrame.timestamp, preferredTimescale: Self.preferredTimescale),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: outputFormat,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        if let sampleBuffer {
            return render(sampleBuffer)
        } else {
            return nil
        }
    }

    func render(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        // Metal writes the buffer on the GPU only: no CPU lock (it would only make the IOSurface sync for the CPU).
        let locksBuffer = !(renderer is ScreenRendererByMetal)
        if locksBuffer {
            try? sampleBuffer.imageBuffer?.lockBaseAddress(Self.lockFlags)
        }
        defer {
            if locksBuffer {
                try? sampleBuffer.imageBuffer?.unlockBaseAddress(Self.lockFlags)
            }
        }
        renderer.presentationTimeStamp = sampleBuffer.presentationTimeStamp
        renderer.setTarget(sampleBuffer.imageBuffer)
        if let dimensions = sampleBuffer.formatDescription?.dimensions {
            root.size = dimensions.size
        }
        delegate?.screen(self, willLayout: sampleBuffer.presentationTimeStamp)
        root.layout(renderer)
        root.draw(renderer)
        renderer.render()
        return sampleBuffer
    }

    func setVideoCaptureLatency(_ presentationTimeStamp: CMTime) {
        guard 0 < targetTimestamp else {
            return
        }
        let hostPresentationTimeStamp = presentationTimeStamp.convertTime(from: synchronizationClock)
        let diff = ceil((targetTimestamp - hostPresentationTimeStamp.seconds) * 10000) / 10000
        guard hasVideoCaptureLatency, abs(diff - videoCaptureLatency) < Self.videoCaptureLatencyJump else {
            videoCaptureLatency = diff
            hasVideoCaptureLatency = true
            return
        }
        videoCaptureLatency += (diff - videoCaptureLatency) * Self.videoCaptureLatencySmoothing
    }

    private func makeRenderer() -> any ScreenRenderer {
        if renderingBackend == .metal, let renderer = ScreenRendererByMetal(dynamicRangeMode: dynamicRangeMode) {
            return renderer
        }
        return ScreenRendererByGPU(dynamicRangeMode: dynamicRangeMode)
    }

    func reset() {
        let screens: [VideoScreenObject] = root.getScreenObjects()
        for screen in screens {
            screen.reset()
        }
    }
}
