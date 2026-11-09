import AVFoundation
import CoreImage
import Metal

/// Composes the screen with Metal (opt in: `Screen.renderingBackend = .metal`, SDR only).
///
/// `ScreenRendererByGPU` builds one Core Image graph of every layer and renders it on every frame: Core Image fuses the
/// layers into one kernel that runs for every pixel of the picture, and its per-render CPU cost (graph, cache lookups,
/// a synchronous render into a locked pixel buffer) comes on top of the GPU work. This renderer keeps each layer as a
/// texture and draws them over each other with one quad each:
/// - the camera's pixel buffer is sampled as it is (no copy); its YCbCr is converted in the shader with the matrix and
///   range Core Image would use (the buffer's matrix attachment; without one 601 for full range, 709 for video range);
/// - an image a screen object hands over (`makeImage`) is rendered into a texture by Core Image only when it is a new
///   image (layout runs only for invalidated objects, and an unchanged object keeps its texture), so a still overlay
///   costs Core Image once, not once per frame;
/// - an object that shows a part of one still image (`ScreenObjectImageRegionProviding`, a ticker) uploads the image
///   once and then only moves the part it samples;
/// - a video effect that only lays an image over the video (`VideoOverlayEffect`) is drawn as a layer right above the
///   video; other effects make that video object go through Core Image (`makeImage`), as before.
/// The layers are composed as Core Image composes them (premultiplied source-over, in the working colour space with
/// its transfer function, in half floats) and the result is written as 4:2:0 video range with the 709 matrix, as Core
/// Image writes the screen's pixel buffers. Positions follow `ScreenRendererByGPU.draw` exactly, its quirk included
/// (an object at the origin is not flipped).
final class ScreenRendererByMetal: ScreenRenderer {
    /// How a layer is drawn this frame.
    private enum Layer {
        /// The video's pixel buffer filling `frame` (top-left pixels), then its overlay effects' images.
        case video(pixelBuffer: CVPixelBuffer, frame: CGRect, overlays: [Raster])
        /// `region` (texture pixels) of a still image's texture filling `frame`.
        case region(image: CGImage, region: CGRect, frame: CGRect)
        /// An image rendered by Core Image.
        case raster(Raster)
    }

    /// An image placed on the canvas, rendered into its own texture by Core Image when it changes.
    private final class Raster {
        /// The image the object handed over: a new one means new content.
        let image: CIImage
        /// `image` moved to its place on the canvas (what is rendered).
        let placed: CIImage
        /// Where the image's pixels go: whole pixels, top-left origin, inside the canvas.
        let frame: CGRect
        /// The same rectangle in Core Image's coordinates (bottom-left origin).
        let sourceRect: CGRect
        var texture: (any MTLTexture)?
        var needsRender = true

        init(image: CIImage, placed: CIImage, frame: CGRect, sourceRect: CGRect) {
            self.image = image
            self.placed = placed
            self.frame = frame
            self.sourceRect = sourceRect
        }

        func matches(_ image: CIImage, sourceRect: CGRect) -> Bool {
            self.image === image && self.sourceRect == sourceRect
        }
    }

    private struct Entry {
        weak var object: ScreenObject?
        var layer: Layer?
    }

    private struct QuadUniforms {
        var destination: SIMD4<Float>
        var source: SIMD4<Float>
        var canvasSize: SIMD2<Float>
    }

    private struct YCbCrUniforms {
        var lumaOffset: Float
        var lumaScale: Float
        var chromaScale: Float
        var redFromCr: Float
        var greenFromCb: Float
        var greenFromCr: Float
        var blueFromCb: Float
    }

    private static let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))

    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadUniforms {
        float4 destination;
        float4 source;
        float2 canvasSize;
    };

    struct YCbCrUniforms {
        float lumaOffset;
        float lumaScale;
        float chromaScale;
        float redFromCr;
        float greenFromCb;
        float greenFromCr;
        float blueFromCb;
    };

    struct QuadVertex {
        float4 position [[position]];
        float2 coordinate;
    };

    vertex QuadVertex quadVertex(uint id [[vertex_id]], constant QuadUniforms &uniforms [[buffer(0)]]) {
        float2 corner = float2(float(id & 1), float(id >> 1));
        float2 pixel = uniforms.destination.xy + corner * uniforms.destination.zw;
        QuadVertex out;
        out.position = float4(pixel.x / uniforms.canvasSize.x * 2.0 - 1.0, 1.0 - pixel.y / uniforms.canvasSize.y * 2.0, 0.0, 1.0);
        out.coordinate = uniforms.source.xy + corner * uniforms.source.zw;
        return out;
    }

    fragment half4 textureFragment(QuadVertex in [[stage_in]], texture2d<half> texture [[texture(0)]], sampler linear [[sampler(0)]]) {
        return texture.sample(linear, in.coordinate);
    }

    fragment half4 colorFragment(QuadVertex in [[stage_in]], texture2d<half> texture [[texture(0)]], sampler linear [[sampler(0)]]) {
        return half4(texture.sample(linear, in.coordinate).rgb, 1.0h);
    }

    fragment half4 yCbCrFragment(QuadVertex in [[stage_in]],
                                 texture2d<float> luma [[texture(0)]],
                                 texture2d<float> chroma [[texture(1)]],
                                 sampler linear [[sampler(0)]],
                                 constant YCbCrUniforms &matrix [[buffer(0)]]) {
        float y = (luma.sample(linear, in.coordinate).r * 255.0 - matrix.lumaOffset) / matrix.lumaScale;
        float2 c = (chroma.sample(linear, in.coordinate).rg * 255.0 - 128.0) / matrix.chromaScale;
        float r = y + matrix.redFromCr * c.y;
        float g = y + matrix.greenFromCb * c.x + matrix.greenFromCr * c.y;
        float b = y + matrix.blueFromCb * c.x;
        return half4(half3(float3(r, g, b)), 1.0h);
    }

    // One thread per chroma sample: its 2x2 luma samples and their mean's chroma. Video range, 709 matrix.
    kernel void convertToYCbCr(texture2d<half, access::read> canvas [[texture(0)]],
                               texture2d<float, access::write> luma [[texture(1)]],
                               texture2d<float, access::write> chroma [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) {
            return;
        }
        const float3 toY = float3(0.2126, 0.7152, 0.0722);
        uint2 size = uint2(luma.get_width(), luma.get_height());
        float3 sum = float3(0.0);
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 p = min(gid * 2 + uint2(dx, dy), size - 1);
                float3 rgb = clamp(float3(canvas.read(p).rgb), 0.0, 1.0);
                if (gid.x * 2 + dx < size.x && gid.y * 2 + dy < size.y) {
                    luma.write(float4((16.0 + 219.0 * dot(rgb, toY)) / 255.0), p);
                }
                sum += rgb;
            }
        }
        float3 rgb = sum * 0.25;
        float y = dot(rgb, toY);
        float cb = (rgb.b - y) / 1.8556;
        float cr = (rgb.r - y) / 1.5748;
        chroma.write(float4((128.0 + 224.0 * cb) / 255.0, (128.0 + 224.0 * cr) / 255.0, 0.0, 0.0), gid);
    }
    """

    var bounds: CGRect = .init(origin: .zero, size: Screen.size)
    let imageOptions: [CIImageOption: Any]?
    var synchronizationClock: CMClock?
    var presentationTimeStamp: CMTime = .zero
    let context: CIContext

    var backgroundColor = CGColor(red: 0x00, green: 0x00, blue: 0x00, alpha: 0x00) {
        didSet {
            guard backgroundColor != oldValue else {
                return
            }
            clearColor = Self.clearColor(backgroundColor, in: colorSpace)
        }
    }

    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let colorSpace: CGColorSpace
    private let texturePipeline: any MTLRenderPipelineState
    private let colorPipeline: any MTLRenderPipelineState
    private let yCbCrPipeline: any MTLRenderPipelineState
    private let convertPipeline: any MTLComputePipelineState
    private let sampler: any MTLSamplerState
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    private var roundedRectangleFactory = RoundedRectangleFactory()
    private var target: CVPixelBuffer?
    private var canvas: (any MTLTexture)?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var drawOrder: [ObjectIdentifier] = []
    /// Still images uploaded for `ScreenObjectImageRegionProviding` objects, by image.
    private var imageTextures: [ObjectIdentifier: (image: CGImage, texture: any MTLTexture)] = [:]
    private var usedImageTextures: Set<ObjectIdentifier> = []

    /// A renderer, or nil where Metal is missing or the mode is not SDR (the screen then keeps Core Image).
    init?(dynamicRangeMode: DynamicRangeMode) {
        guard dynamicRangeMode == .sdr,
              let colorSpace = dynamicRangeMode.colorSpace,
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard let textureCache, let library = try? device.makeLibrary(source: Self.shaders, options: nil),
              let quadVertex = library.makeFunction(name: "quadVertex"),
              let convert = library.makeFunction(name: "convertToYCbCr"),
              let convertPipeline = try? device.makeComputePipelineState(function: convert) else {
            return nil
        }
        func pipeline(_ fragment: String) -> (any MTLRenderPipelineState)? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = quadVertex
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]
            attachment?.pixelFormat = .rgba16Float
            // Premultiplied source-over, as `CIImage.composited(over:)`.
            attachment?.isBlendingEnabled = true
            attachment?.rgbBlendOperation = .add
            attachment?.alphaBlendOperation = .add
            attachment?.sourceRGBBlendFactor = .one
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let texturePipeline = pipeline("textureFragment"),
              let colorPipeline = pipeline("colorFragment"),
              let yCbCrPipeline = pipeline("yCbCrFragment"),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
        self.colorSpace = colorSpace
        self.texturePipeline = texturePipeline
        self.colorPipeline = colorPipeline
        self.yCbCrPipeline = yCbCrPipeline
        self.convertPipeline = convertPipeline
        self.sampler = sampler
        imageOptions = [.colorSpace: colorSpace]
        // The screen's Core Image settings (`DynamicRangeMode.makeCIContext`), on this renderer's queue, so its renders
        // land in this renderer's command buffers in order.
        context = CIContext(mtlCommandQueue: commandQueue, options: [
            .workingFormat: CIFormat.RGBAh.rawValue,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace,
            .cacheIntermediates: false,
            .name: "ScreenRendererByMetal"
        ])
    }

    func setTarget(_ pixelBuffer: CVPixelBuffer?) {
        target = pixelBuffer
        drawOrder.removeAll(keepingCapacity: true)
    }

    func layout(_ screenObject: ScreenObject) {
        let id = ObjectIdentifier(screenObject)
        var entry = entries[id] ?? Entry(object: screenObject)
        entry.object = screenObject
        if let layer = makeLayer(screenObject, previous: entry.layer) {
            entry.layer = layer
        }
        entries[id] = entry
    }

    func draw(_ screenObject: ScreenObject) {
        drawOrder.append(ObjectIdentifier(screenObject))
    }

    func render() {
        guard let target, let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        let width = CVPixelBufferGetWidth(target), height = CVPixelBufferGetHeight(target)
        guard let canvas = canvasTexture(width: width, height: height),
              let luma = texture(target, plane: 0, format: .r8Unorm, writable: true),
              let chroma = texture(target, plane: 1, format: .rg8Unorm, writable: true) else {
            return
        }
        // The pixel buffers' textures stay alive until the GPU has used them.
        var keepAlive: [CVMetalTexture] = [luma.0, chroma.0]
        let layers = drawOrder.compactMap { entries[$0]?.layer }
        renderRasters(of: layers, into: commandBuffer)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = canvas
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setFragmentSamplerState(sampler, index: 0)
            let canvasSize = SIMD2(Float(width), Float(height))
            for layer in layers {
                switch layer {
                case let .video(pixelBuffer, frame, overlays):
                    if let textures = drawVideo(pixelBuffer, frame: frame, canvasSize: canvasSize, encoder: encoder) {
                        keepAlive += textures
                    }
                    for overlay in overlays {
                        drawRaster(overlay, canvasSize: canvasSize, encoder: encoder)
                    }
                case let .region(image, region, frame):
                    drawRegion(image, region: region, frame: frame, canvasSize: canvasSize, encoder: encoder)
                case let .raster(raster):
                    drawRaster(raster, canvasSize: canvasSize, encoder: encoder)
                }
            }
            encoder.endEncoding()
        }
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(convertPipeline)
            encoder.setTexture(canvas, index: 0)
            encoder.setTexture(luma.1, index: 1)
            encoder.setTexture(chroma.1, index: 2)
            let threads = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (chroma.1.width + 15) / 16, height: (chroma.1.height + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
            encoder.endEncoding()
        }
        withExtendedLifetime(keepAlive) {
            commandBuffer.commit()
            // The pixel buffer goes to the encoder (and the preview) right after this returns, as with Core Image's
            // synchronous render.
            commandBuffer.waitUntilCompleted()
        }
        pruneEntries()
    }

    // MARK: - Layers

    private func makeLayer(_ object: ScreenObject, previous: Layer?) -> Layer? {
        if let video = object as? VideoScreenObject, video.effectsAreOverlays {
            guard let pixelBuffer = video.dequeuePixelBuffer(self) else {
                return nil
            }
            let transform = video.videoGravity.scale(object.bounds.size, image: pixelBuffer.size)
            let videoRect = CGRect(origin: .zero, size: pixelBuffer.size).applying(transform)
            let translation = translation(of: object)
            var pool: [Raster] = []
            if case let .video(_, _, overlays)? = previous {
                pool = overlays
            }
            let overlays = video.overlayImages(over: videoRect).compactMap { image in
                raster(image, translation: translation, pool: &pool)
            }
            return .video(pixelBuffer: pixelBuffer, frame: topLeft(videoRect.offsetBy(dx: translation.x, dy: translation.y)),
                          overlays: overlays)
        }
        if let provider = object as? any ScreenObjectImageRegionProviding, let content = provider.imageRegion() {
            let translation = translation(of: object)
            let frame = CGRect(origin: CGPoint(x: translation.x, y: translation.y), size: object.bounds.size)
            return .region(image: content.image, region: content.region, frame: topLeft(frame))
        }
        guard var image = object.makeImage(self) else {
            return nil
        }
        if 0 < object.cornerRadius, let mask = roundedRectangleFactory.cornerRadius(
            object.bounds.size, cornerRadius: object.cornerRadius) {
            image = image.applyingFilter("CIBlendWithAlphaMask", parameters: ["inputMaskImage": mask])
        }
        var pool: [Raster] = []
        if case let .raster(raster)? = previous {
            pool = [raster]
        }
        guard let raster = raster(image, translation: translation(of: object), pool: &pool) else {
            // Nothing on the canvas (an empty image): draws nothing, as Core Image would.
            return .raster(Raster(image: image, placed: image, frame: .zero, sourceRect: .zero))
        }
        return .raster(raster)
    }

    /// `ScreenRendererByGPU.draw`'s translation, in Core Image's coordinates.
    private func translation(of object: ScreenObject) -> CGPoint {
        let origin = object.bounds.origin
        if origin.x == 0 && origin.y == 0 {
            return .zero
        }
        return CGPoint(x: origin.x, y: bounds.height - origin.y - object.bounds.height)
    }

    /// The image moved by `translation`, cut to whole pixels of the canvas: the previous raster (taken from `pool`)
    /// when it is the same image in the same place, else a new one that renders into a texture of the pool's when one
    /// has its size (the previous frame's GPU work is done).
    private func raster(_ image: CIImage, translation: CGPoint, pool: inout [Raster]) -> Raster? {
        let canvas = CGRect(origin: .zero, size: bounds.size)
        let placed = translation == .zero ? image : image.transformed(by: .init(translationX: translation.x, y: translation.y))
        let sourceRect = placed.extent.intersection(canvas).integral.intersection(canvas)
        guard !sourceRect.isNull, sourceRect.width >= 1, sourceRect.height >= 1 else {
            return nil
        }
        if let index = pool.firstIndex(where: { $0.matches(image, sourceRect: sourceRect) }) {
            return pool.remove(at: index)
        }
        // Over a clear image: rendered alone from a rectangle, Core Image folds a translation into the destination
        // and drops its fraction; over a background it samples between pixels, as on the screen's canvas.
        let backed = placed.composited(over: Self.clear.cropped(to: sourceRect))
        let raster = Raster(image: image, placed: backed, frame: topLeft(sourceRect), sourceRect: sourceRect)
        if let index = pool.firstIndex(where: { $0.frame.size == raster.frame.size }) {
            raster.texture = pool.remove(at: index).texture
        }
        return raster
    }

    /// A rectangle in Core Image's coordinates (origin bottom left) in the canvas's pixels (origin top left).
    private func topLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Rendering

    private func renderRasters(of layers: [Layer], into commandBuffer: any MTLCommandBuffer) {
        usedImageTextures.removeAll(keepingCapacity: true)
        for layer in layers {
            switch layer {
            case let .video(_, _, overlays):
                overlays.forEach { renderRaster($0, into: commandBuffer) }
            case let .raster(raster):
                renderRaster(raster, into: commandBuffer)
            case let .region(image, _, _):
                usedImageTextures.insert(ObjectIdentifier(image))
                if imageTextures[ObjectIdentifier(image)] == nil, let texture = upload(image, into: commandBuffer) {
                    imageTextures[ObjectIdentifier(image)] = (image, texture)
                }
            }
        }
    }

    private func renderRaster(_ raster: Raster, into commandBuffer: any MTLCommandBuffer) {
        guard raster.needsRender, raster.frame.width >= 1, raster.frame.height >= 1 else {
            return
        }
        let width = Int(raster.frame.width), height = Int(raster.frame.height)
        let texture: any MTLTexture
        if let existing = raster.texture, existing.width == width, existing.height == height {
            texture = existing
        } else if let made = makeTexture(width: width, height: height) {
            texture = made
        } else {
            return
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = colorSpace
        destination.isFlipped = true
        _ = try? context.startTask(toRender: raster.placed, from: raster.sourceRect, to: destination, at: .zero)
        raster.texture = texture
        raster.needsRender = false
    }

    private func upload(_ image: CGImage, into commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        guard let texture = makeTexture(width: image.width, height: image.height) else {
            return nil
        }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commandBuffer)
        destination.colorSpace = colorSpace
        destination.isFlipped = true
        let ciImage = CIImage(cgImage: image)
        _ = try? context.startTask(toRender: ciImage, from: ciImage.extent, to: destination, at: .zero)
        return texture
    }

    private func drawVideo(_ pixelBuffer: CVPixelBuffer, frame: CGRect, canvasSize: SIMD2<Float>,
                           encoder: any MTLRenderCommandEncoder) -> [CVMetalTexture]? {
        var uniforms = QuadUniforms(destination: Self.vector(frame), source: SIMD4(0, 0, 1, 1), canvasSize: canvasSize)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let luma = texture(pixelBuffer, plane: 0, format: .r8Unorm, writable: false),
                  let chroma = texture(pixelBuffer, plane: 1, format: .rg8Unorm, writable: false) else {
                return nil
            }
            var matrix = Self.yCbCrUniforms(pixelBuffer)
            encoder.setRenderPipelineState(yCbCrPipeline)
            encoder.setFragmentTexture(luma.1, index: 0)
            encoder.setFragmentTexture(chroma.1, index: 1)
            encoder.setFragmentBytes(&matrix, length: MemoryLayout<YCbCrUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return [luma.0, chroma.0]
        case kCVPixelFormatType_32BGRA:
            guard let color = texture(pixelBuffer, plane: nil, format: .bgra8Unorm, writable: false) else {
                return nil
            }
            encoder.setRenderPipelineState(colorPipeline)
            encoder.setFragmentTexture(color.1, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            return [color.0]
        default:
            return nil
        }
    }

    private func drawRegion(_ image: CGImage, region: CGRect, frame: CGRect, canvasSize: SIMD2<Float>,
                            encoder: any MTLRenderCommandEncoder) {
        guard let texture = imageTextures[ObjectIdentifier(image)]?.texture else {
            return
        }
        let size = CGSize(width: texture.width, height: texture.height)
        let source = CGRect(x: region.minX / size.width, y: region.minY / size.height,
                            width: region.width / size.width, height: region.height / size.height)
        drawTexture(texture, frame: frame, source: source, canvasSize: canvasSize, encoder: encoder)
    }

    private func drawRaster(_ raster: Raster, canvasSize: SIMD2<Float>, encoder: any MTLRenderCommandEncoder) {
        guard let texture = raster.texture, !raster.needsRender else {
            return
        }
        drawTexture(texture, frame: raster.frame, source: CGRect(x: 0, y: 0, width: 1, height: 1),
                    canvasSize: canvasSize, encoder: encoder)
    }

    private func drawTexture(_ texture: any MTLTexture, frame: CGRect, source: CGRect, canvasSize: SIMD2<Float>,
                             encoder: any MTLRenderCommandEncoder) {
        var uniforms = QuadUniforms(destination: Self.vector(frame), source: Self.vector(source), canvasSize: canvasSize)
        encoder.setRenderPipelineState(texturePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Resources

    private func canvasTexture(width: Int, height: Int) -> (any MTLTexture)? {
        if let canvas, canvas.width == width, canvas.height == height {
            return canvas
        }
        canvas = makeTexture(width: width, height: height)
        return canvas
    }

    private func makeTexture(width: Int, height: Int) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func texture(_ pixelBuffer: CVPixelBuffer, plane: Int?, format: MTLPixelFormat,
                         writable: Bool) -> (CVMetalTexture, any MTLTexture)? {
        let width = plane.map { CVPixelBufferGetWidthOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetWidth(pixelBuffer)
        let height = plane.map { CVPixelBufferGetHeightOfPlane(pixelBuffer, $0) } ?? CVPixelBufferGetHeight(pixelBuffer)
        var usage: MTLTextureUsage = [.shaderRead]
        if writable {
            usage.insert(.shaderWrite)
        }
        let attributes = [kCVMetalTextureUsage: NSNumber(value: usage.rawValue)] as CFDictionary
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, attributes, format, width, height, plane ?? 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return (cvTexture, texture)
    }

    /// Forgets the layers of objects that are gone, and still images no object shows any more.
    private func pruneEntries() {
        if entries.contains(where: { $0.value.object == nil }) {
            entries = entries.filter { $0.value.object != nil }
        }
        if imageTextures.count > usedImageTextures.count {
            imageTextures = imageTextures.filter { usedImageTextures.contains($0.key) }
        }
    }

    // MARK: - Colour

    /// What Core Image does with a YCbCr pixel buffer (`CIImage(cvPixelBuffer:)`): the buffer's matrix attachment, and
    /// without one 601 for full range and 709 for video range (measured, macOS 26 / iOS 18).
    private static func yCbCrUniforms(_ pixelBuffer: CVPixelBuffer) -> YCbCrUniforms {
        let fullRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let uses601: Bool
        if attachment == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
            || attachment == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String {
            uses601 = true
        } else if attachment == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String {
            uses601 = false
        } else {
            uses601 = fullRange
        }
        let kr: Float = uses601 ? 0.299 : 0.2126
        let kb: Float = uses601 ? 0.114 : 0.0722
        let kg = 1 - kr - kb
        return YCbCrUniforms(
            lumaOffset: fullRange ? 0 : 16,
            lumaScale: fullRange ? 255 : 219,
            chromaScale: fullRange ? 255 : 224,
            redFromCr: 2 * (1 - kr),
            greenFromCb: -2 * (1 - kb) * kb / kg,
            greenFromCr: -2 * (1 - kr) * kr / kg,
            blueFromCb: 2 * (1 - kb)
        )
    }

    /// The background as Core Image composes it: in the working colour space, premultiplied.
    private static func clearColor(_ color: CGColor, in colorSpace: CGColorSpace) -> MTLClearColor {
        guard let converted = color.converted(to: colorSpace, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4 else {
            return MTLClearColor(red: 0, green: 0, blue: 0, alpha: Double(color.alpha))
        }
        let alpha = Double(components[3])
        return MTLClearColor(red: Double(components[0]) * alpha, green: Double(components[1]) * alpha,
                             blue: Double(components[2]) * alpha, alpha: alpha)
    }

    private static func vector(_ rect: CGRect) -> SIMD4<Float> {
        SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
    }
}
