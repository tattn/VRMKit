@_exported import VRMKit
@_exported import VRMKitRuntime

#if canImport(RealityKit)
import RealityKit

// MARK: - BlendShapeBindings

typealias BlendShapeBinding = VRMKitRuntime.BlendShapeBinding<Entity>
typealias ExpressionClip = VRMKitRuntime.ExpressionClip<Entity>

// MARK: - Humanoid

public typealias Humanoid = VRMKitRuntime.Humanoid<Entity>
#endif
