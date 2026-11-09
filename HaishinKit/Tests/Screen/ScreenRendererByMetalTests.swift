import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import HaishinKit

/// `ScreenRendererByMetal` must give Core Image's picture: the same scene goes through a screen on each backend and
/// both pixel buffers (4:2:0 video range, as the screen's pool makes them) are compared plane by plane. Measured on an
/// M-series Mac (2026-11-09): at most 1 level apart in luma and 2 in chroma, a mean below 0.08 (rounding); a misplaced
/// layer or a wrong matrix is tens of levels. `HK_SCREEN_DUMP=<dir>` writes both lumas and prints the differences.
@ScreenActor
@Suite struct ScreenRendererByMetalTests {
    nonisolated private static let width = 192
    nonisolated private static let height = 108

    /// The planes of two renders: the largest and the mean difference of the luma and the chroma.
    private struct Difference: CustomStringConvertible {
        var lumaMax = 0
        var lumaMean = 0.0
        var chromaMax = 0
        var chromaMean = 0.0

        var description: String {
            "luma max \(lumaMax) mean \(String(format: "%.3f", lumaMean)), "
                + "chroma max \(chromaMax) mean \(String(format: "%.3f", chromaMean))"
        }
    }

    // MARK: - Scenes

    @Test func cameraFormatsGiveCoreImagesColours() throws {
        let cases: [(OSType, CFString?)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVImageBufferYCbCrMatrix_ITU_R_601_4),
            (kCVPixelFormatType_32BGRA, nil)
        ]
        for (format, matrix) in cases {
            let difference = try compare { _ in } camera: { Self.camera(format: format, matrix: matrix) }
            #expect(difference.lumaMax <= 2 && difference.chromaMax <= 2 && difference.chromaMean < 0.1,
                    "\(format) \((matrix as String?) ?? "no matrix"): \(difference)")
        }
    }

    @Test func overlaysStripsEffectsAndCornersLandWhereCoreImagePutsThem() throws {
        let difference = try compare { screen in
            try Self.addOverlays(to: screen, stripOffset: 37)
        } camera: { Self.camera(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2) }
        #expect(difference.lumaMax <= 2 && difference.lumaMean < 0.1, "\(difference)")
        #expect(difference.chromaMax <= 2 && difference.chromaMean < 0.1, "\(difference)")
    }

    @Test func aStripMovedByAFractionIsResampledAsCoreImageDoes() throws {
        let difference = try compare { screen in
            try Self.addOverlays(to: screen, stripOffset: 37.5)
        } camera: { Self.camera(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2) }
        #expect(difference.lumaMax <= 2 && difference.lumaMean < 0.1, "\(difference)")
        #expect(difference.chromaMax <= 2 && difference.chromaMean < 0.1, "\(difference)")
    }

    @Test func otherEffectsGoThroughCoreImage() throws {
        let difference = try compare { screen in
            _ = screen.registerVideoEffect(MonochromeEffect())
            _ = screen.registerVideoEffect(BadgeEffect())
        } camera: { Self.camera(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2) }
        #expect(difference.lumaMax <= 2 && difference.chromaMax <= 2, "\(difference)")
    }

    @Test func laterFramesFollowTheObjectsChanges() throws {
        let core = Screen(), metal = Screen()
        metal.renderingBackend = .metal
        #expect(metal.isRenderingWithMetal)
        var strips: [StripObject] = []
        var images: [ImageScreenObject] = []
        for screen in [core, metal] {
            prepare(screen)
            let objects = try Self.addOverlays(to: screen, stripOffset: 0)
            strips.append(objects.strip)
            images.append(objects.image)
        }
        for frame in 0..<4 {
            for index in 0..<2 {
                // The strip moves every frame; the image changes on the third.
                strips[index].offset = Double(frame) * 11
                strips[index].invalidateLayout()
                if frame == 2 {
                    images[index].ciImage = CIImage(cgImage: Self.overlayImage(width: 40, height: 24, seed: 3))
                }
            }
            let difference = try render([core, metal], frame: frame) {
                Self.camera(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2, shift: frame * 5)
            }
            #expect(difference.lumaMax <= 2 && difference.chromaMax <= 2, "frame \(frame): \(difference)")
        }
    }

    // MARK: - Driving two screens

    private func prepare(_ screen: Screen) {
        screen.size = .init(width: Self.width, height: Self.height)
        screen.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private func compare(_ build: (Screen) throws -> Void,
                         camera: () -> CVPixelBuffer) throws -> Difference {
        let core = Screen(), metal = Screen()
        metal.renderingBackend = .metal
        #expect(metal.isRenderingWithMetal)
        for screen in [core, metal] {
            prepare(screen)
            try build(screen)
        }
        return try render([core, metal], frame: 0, camera: camera)
    }

    private func render(_ screens: [Screen], frame: Int, camera: () -> CVPixelBuffer) throws -> Difference {
        let time = CMTime(value: CMTimeValue(100 + frame), timescale: 60)
        var outputs: [CVPixelBuffer] = []
        for screen in screens {
            let input = try #require(Self.sampleBuffer(camera(), time: time))
            screen.append(0, buffer: input)
            let output = try #require(Self.sampleBuffer(Self.pixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange), time: time))
            outputs.append(try #require(screen.render(output).imageBuffer))
        }
        if let directory = ProcessInfo.processInfo.environment["HK_SCREEN_DUMP"] {
            for (index, output) in outputs.enumerated() {
                Self.dumpLuma(output, to: "\(directory)/\(frame)-\(index).pgm")
            }
        }
        let difference = Self.difference(outputs[0], outputs[1])
        if ProcessInfo.processInfo.environment["HK_SCREEN_DUMP"] != nil {
            print("SCREEN_DIFF frame \(frame): \(difference)")
        }
        return difference
    }

    private static func dumpLuma(_ buffer: CVPixelBuffer, to path: String) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        var data = Data("P5 \(width) \(height) 255\n".utf8)
        for y in 0..<height {
            data.append(base + y * row, count: width)
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Scene parts

    final class StripObject: ScreenObject, ScreenObjectImageRegionProviding {
        let strip: CGImage
        var offset: Double = 0

        init(strip: CGImage) {
            self.strip = strip
            super.init()
        }

        func imageRegion() -> ScreenObjectImageRegion? {
            ScreenObjectImageRegion(image: strip, region: CGRect(x: offset, y: 0, width: bounds.width, height: bounds.height))
        }

        override func makeImage(_ renderer: some ScreenRenderer) -> CIImage? {
            CIImage(cgImage: strip)
                .transformed(by: CGAffineTransform(translationX: -offset, y: 0))
                .cropped(to: CGRect(origin: .zero, size: bounds.size))
        }
    }

    /// Lays a badge over the video, in the video's coordinates.
    final class BadgeEffect: VideoOverlayEffect {
        let badge = CIImage(cgImage: ScreenRendererByMetalTests.overlayImage(width: 30, height: 18, seed: 5))
            .transformed(by: CGAffineTransform(translationX: 12.25, y: 61.5))

        func overlayImage(over extent: CGRect) -> CIImage? {
            badge
        }

        func execute(_ image: CIImage) -> CIImage {
            badge.composited(over: image)
        }
    }

    final class MonochromeEffect: VideoEffect {
        func execute(_ image: CIImage) -> CIImage {
            image.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: 0.7, green: 0.6, blue: 0.5),
                kCIInputIntensityKey: 0.8
            ])
        }
    }

    @discardableResult
    private static func addOverlays(to screen: Screen, stripOffset: Double) throws
        -> (strip: StripObject, image: ImageScreenObject) {
        _ = screen.registerVideoEffect(BadgeEffect())

        // Below the others: a strip along the bottom, moved left.
        let strip = StripObject(strip: overlayImage(width: Self.width * 2, height: 14, seed: 1))
        strip.offset = stripOffset
        strip.size = .init(width: Double(Self.width), height: 14)
        strip.verticalAlignment = .bottom
        try screen.addChild(strip)

        // An image at a fractional place.
        let image = ImageScreenObject()
        image.ciImage = CIImage(cgImage: overlayImage(width: 40, height: 24, seed: 2))
        image.size = .init(width: 40, height: 24)
        image.layoutMargin = .init(top: 9.5, left: 131.25, bottom: 0, right: 0)
        try screen.addChild(image)

        // Rounded corners.
        let rounded = ImageScreenObject()
        rounded.ciImage = CIImage(cgImage: overlayImage(width: 50, height: 30, seed: 4))
        rounded.size = .init(width: 50, height: 30)
        rounded.cornerRadius = 8
        rounded.layoutMargin = .init(top: 40, left: 60, bottom: 0, right: 0)
        try screen.addChild(rounded)

        // At the origin and shorter than the screen: Core Image's renderer draws it at the bottom (not flipped).
        let corner = ImageScreenObject()
        corner.ciImage = CIImage(cgImage: overlayImage(width: 20, height: 16, seed: 6))
        corner.size = .init(width: 20, height: 16)
        try screen.addChild(corner)
        return (strip, image)
    }

    /// A picture with soft and hard edges, colours and partial transparency.
    nonisolated static func overlayImage(width: Int, height: Int, seed: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.75))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<max(3, width / 12) {
            let hue = Double((index * 7 + seed * 13) % 17) / 17
            context.setFillColor(CGColor(srgbRed: hue, green: 1 - hue, blue: Double((index + seed) % 3) / 2, alpha: 1))
            let x = Double(index * 12 + seed % 5)
            context.fillEllipse(in: CGRect(x: x, y: Double(height) * 0.2, width: 9, height: Double(height) * 0.6))
        }
        // A marker at the top left, so a flip shows.
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 4, width: 6, height: 4))
        return context.makeImage()!
    }

    /// A camera frame: soft gradients with a few hard edges, in the given format.
    nonisolated static func camera(format: OSType, matrix: CFString?, shift: Int = 0) -> CVPixelBuffer {
        let buffer = pixelBuffer(format)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if format == kCVPixelFormatType_32BGRA {
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = base + y * row + x * 4
                    pixel[0] = UInt8((x * 255 / width + shift) % 256)
                    pixel[1] = UInt8(y * 255 / height)
                    pixel[2] = (x / 24 + y / 24) % 2 == 0 ? 200 : 60
                    pixel[3] = 255
                }
            }
        } else {
            let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let edge = (x / 32) % 2 == 0 ? 0 : 40
                    luma[y * lumaRow + x] = UInt8(30 + (x + shift) % width * 150 / width + edge)
                }
            }
            let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<(height / 2) {
                for x in 0..<(width / 2) {
                    chroma[y * chromaRow + x * 2] = UInt8(90 + x * 80 / (width / 2))
                    chroma[y * chromaRow + x * 2 + 1] = (y / 12) % 2 == 0 ? 170 : 100
                }
            }
            if let matrix {
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
            }
        }
        return buffer
    }

    nonisolated static func pixelBuffer(_ format: OSType) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &buffer)
        return buffer!
    }

    nonisolated static func sampleBuffer(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    private static func difference(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Difference {
        CVPixelBufferLockBaseAddress(lhs, .readOnly)
        CVPixelBufferLockBaseAddress(rhs, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
            CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
        }
        var result = Difference()
        for plane in 0..<2 {
            let width = CVPixelBufferGetWidthOfPlane(lhs, plane) * (plane == 0 ? 1 : 2)
            let height = CVPixelBufferGetHeightOfPlane(lhs, plane)
            let leftRow = CVPixelBufferGetBytesPerRowOfPlane(lhs, plane)
            let rightRow = CVPixelBufferGetBytesPerRowOfPlane(rhs, plane)
            let left = CVPixelBufferGetBaseAddressOfPlane(lhs, plane)!.assumingMemoryBound(to: UInt8.self)
            let right = CVPixelBufferGetBaseAddressOfPlane(rhs, plane)!.assumingMemoryBound(to: UInt8.self)
            var maximum = 0, total = 0
            for y in 0..<height {
                for x in 0..<width {
                    let delta = abs(Int(left[y * leftRow + x]) - Int(right[y * rightRow + x]))
                    maximum = max(maximum, delta)
                    total += delta
                }
            }
            let mean = Double(total) / Double(width * height)
            if plane == 0 {
                result.lumaMax = maximum
                result.lumaMean = mean
            } else {
                result.chromaMax = maximum
                result.chromaMean = mean
            }
        }
        return result
    }
}
