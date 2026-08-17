#if canImport(RealityKit)
import Foundation
import Metal

enum MToonShaderLibraryLoaderError: Error {
    case noMetalDevice
    case unsupportedPlatform
    case resourceMissing(String)
    case loadFailed(String, Error)
    case requiredFunctionsMissing(Set<String>)
}

/// Loads the precompiled platform-specific MToon Metal library bundled as a
/// package resource.
///
/// The metallibs are built offline by scripts/build-mtoon-metallibs.sh so that
/// nothing depends on the consumer's build system compiling the package's
/// .metal source, which `swift build` does not support.
@MainActor
enum MToonShaderLibraryLoader {
    static let requiredFunctions: Set<String> = [
        "mtoonSurface",
        "mtoonOutlineSurface",
        "mtoonOutlineGeometry"
    ]

    static var resourceName: String? {
#if os(macOS) && !targetEnvironment(macCatalyst)
        return "MToon-macos"
#elseif os(iOS) && targetEnvironment(simulator)
        return "MToon-iossim"
#elseif os(iOS) && !targetEnvironment(macCatalyst)
        return "MToon-ios"
#else
        // No precompiled MToon library is bundled for this platform
        // (e.g. Mac Catalyst, visionOS); MToon rendering falls back to UnlitMaterial.
        return nil
#endif
    }

    /// The bundle the precompiled metallibs ship in.
    static var resourceBundle: Bundle { .module }

    // Both success and failure are cached so repeated material creation does
    // not recreate Metal devices or re-attempt a load that cannot succeed.
    private static var cachedResult: Result<MTLLibrary, Error>?

    static func loadDefault() throws -> MTLLibrary {
        if let cachedResult {
            return try cachedResult.get()
        }
        let result = Result { () throws -> MTLLibrary in
            // Check the statically-known failure before creating a device.
            guard resourceName != nil else {
                throw MToonShaderLibraryLoaderError.unsupportedPlatform
            }
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw MToonShaderLibraryLoaderError.noMetalDevice
            }
            return try load(device: device)
        }
        cachedResult = result
        return try result.get()
    }

    static func load(device: MTLDevice) throws -> MTLLibrary {
        guard let resourceName else {
            throw MToonShaderLibraryLoaderError.unsupportedPlatform
        }
        guard let libraryURL = resourceBundle.url(forResource: resourceName, withExtension: "metallib") else {
            throw MToonShaderLibraryLoaderError.resourceMissing(resourceName)
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(URL: libraryURL)
        } catch {
            throw MToonShaderLibraryLoaderError.loadFailed(resourceName, error)
        }

        let missing = requiredFunctions.subtracting(Set(library.functionNames))
        guard missing.isEmpty else {
            throw MToonShaderLibraryLoaderError.requiredFunctionsMissing(missing)
        }
        return library
    }
}
#endif
