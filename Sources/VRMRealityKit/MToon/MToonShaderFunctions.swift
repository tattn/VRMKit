#if canImport(RealityKit)
import Metal

/// The Metal functions an ``MToonShader`` draws with; one left nil is the bundled one.
///
/// A replacement reads the material as the bundled function does, as laid out in
/// `Shaders/MToonRealityKit.h`. The layout is not a stable API, so build against the
/// header from the revision in use.
public struct MToonShaderFunctions {
    public struct Function {
        public var name: String
        public var library: any MTLLibrary

        public init(named name: String, in library: any MTLLibrary) {
            self.name = name
            self.library = library
        }
    }

    /// The surface shader of the material itself.
    public var surface: Function?
    /// The surface shader of the outline pass.
    public var outlineSurface: Function?
    /// The geometry modifier of the outline pass.
    public var outlineGeometry: Function?

    public init(surface: Function? = nil,
                outlineSurface: Function? = nil,
                outlineGeometry: Function? = nil) {
        self.surface = surface
        self.outlineSurface = outlineSurface
        self.outlineGeometry = outlineGeometry
    }

    /// Fills in the bundled functions and checks that each name exists, so a misspelt
    /// one fails once rather than per material.
    @MainActor
    func resolved() throws -> Resolved {
        func resolve(_ function: Function?, bundledName: String) throws -> Function {
            guard let function else {
                return Function(named: bundledName, in: try MToonShaderLibraryLoader.loadDefault())
            }
            guard function.library.functionNames.contains(function.name) else {
                throw MToonShaderLibraryLoaderError.requiredFunctionsMissing([function.name])
            }
            return function
        }
        return Resolved(surface: try resolve(surface, bundledName: "mtoonSurface"),
                        outlineSurface: try resolve(outlineSurface, bundledName: "mtoonOutlineSurface"),
                        outlineGeometry: try resolve(outlineGeometry, bundledName: "mtoonOutlineGeometry"))
    }

    struct Resolved {
        let surface: Function
        let outlineSurface: Function
        let outlineGeometry: Function
    }
}
#endif
