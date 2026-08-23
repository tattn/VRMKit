import Foundation

public extension VRM0.MaterialProperty {
    var vrmShader: Shader? {
        return Shader(rawValue: shader)
    }

    enum Shader: String {
        case mToon = "VRM/MToon"
        case unlitTransparent = "VRM/UnlitTransparent"
        /// Render the glTF material as it is, which is what a material VRM 0.x
        /// has nothing of its own to say about is written as.
        case gltfShader = "VRM_USE_GLTFSHADER"
    }
}
