import AVFoundation
import CoreImage
import Foundation

/// An object that apply a video effect.
/// - seealso:[Processing an Image Using Built-in Filters](https://developer.apple.com/documentation/coreimage/processing_an_image_using_built-in_filters)
///
/// ## Example code:
/// ```swift
/// final class MonochromeEffect: VideoEffect {
///     let filter: CIFilter? = CIFilter(name: "CIColorMonochrome")
///
///     func execute(_ image: CIImage) -> CIImage {
///         guard let filter: CIFilter = filter else {
///             return image
///         }
///         filter.setValue(image, forKey: "inputImage")
///         filter.setValue(CIColor(red: 0.75, green: 0.75, blue: 0.75), forKey: "inputColor")
///         filter.setValue(1.0, forKey: "inputIntensity")
///         return filter.outputImage ?? image
///     }
/// }
/// ```
public protocol VideoEffect: AnyObject {
    /// Executes to apply a video effect.
    func execute(_ image: CIImage) -> CIImage
}

/// A video effect that only lays an image over the video: `execute(image)` is `overlayImage(over: image.extent)`
/// composited over `image` (source-over), or `image` itself when that is nil.
///
/// `ScreenRendererByMetal` draws the overlay as a layer of its own right above the video (rendered by Core Image only
/// when the effect hands a new image), instead of running the effect over the whole picture on every frame.
public protocol VideoOverlayEffect: VideoEffect {
    /// The image laid over a video image of `extent`, in the same coordinates; the same instance while it is unchanged.
    func overlayImage(over extent: CGRect) -> CIImage?
}
