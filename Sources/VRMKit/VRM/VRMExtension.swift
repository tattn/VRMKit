import Foundation

public extension VRM0.MaterialProperty {
    var vrmShader: Shader? {
        return Shader(rawValue: shader)
    }

    enum Shader: String {
        case mToon = "VRM/MToon"
        case unlitTransparent = "VRM/UnlitTransparent"
    }
}
