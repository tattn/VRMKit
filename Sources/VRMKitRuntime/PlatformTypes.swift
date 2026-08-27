#if os(macOS)
import AppKit
public typealias VRMImage = NSImage
public typealias VRMColor = NSColor
#else
import UIKit
public typealias VRMImage = UIImage
public typealias VRMColor = UIColor
#endif

#if os(macOS)
extension NSImage {
    public var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    public convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
#endif
