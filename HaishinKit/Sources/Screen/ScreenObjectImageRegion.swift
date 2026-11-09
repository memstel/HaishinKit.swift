import CoreGraphics

/// A part of one still image that fills a screen object's bounds.
public struct ScreenObjectImageRegion {
    /// The image.
    public let image: CGImage
    /// The part shown, in the image's pixels, origin top left.
    public let region: CGRect

    /// Creates a region.
    public init(image: CGImage, region: CGRect) {
        self.image = image
        self.region = region
    }
}

/// A screen object that shows a part of one still image, such as a ticker that moves a long strip.
///
/// `ScreenRendererByMetal` uploads the image once and then only moves the part it samples, so the object costs no Core
/// Image render per frame. `makeImage` must return the same picture (the Core Image renderer keeps using it).
@ScreenActor
public protocol ScreenObjectImageRegionProviding: AnyObject {
    /// What fills the bounds now; nil makes the renderer use `makeImage`.
    func imageRegion() -> ScreenObjectImageRegion?
}
