#if canImport(RealityKit)
#if os(macOS)
import AppKit
typealias VRMColor = NSColor
#else
import UIKit
typealias VRMColor = UIColor
#endif
#endif
