#if canImport(RealityKit)
import CoreGraphics
import Foundation
import ImageIO
import Metal
import RealityKit
import UniformTypeIdentifiers
import VRMKit
import simd

/// How ``GLTFEntity/snapshot(_:)`` frames and lights what it draws.
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public struct GLTFSnapshotOptions: Sendable {
    public var width: Int
    public var height: Int
    public var fieldOfViewInDegrees: Float
    /// Where the camera sits, relative to what it looks at. Nil uses
    /// ``GLTFEntity/frontDirection``.
    public var direction: SIMD3<Float>?
    /// How much wider than the model the frame is. 1 fits it exactly.
    public var margin: Float
    /// What the model is drawn against. Nil leaves it transparent.
    public var background: CGColor?
    /// A directional light beside the camera, for the materials RealityKit shades
    /// itself. 0 leaves the scene unlit. MToon takes its light from the entity
    /// instead, see ``mtoonLitFromCamera``.
    public var lightIntensity: Float
    /// Lights MToon materials from the camera rather than from the entity's own
    /// light direction, so a model looked at head-on is lit for that view.
    public var mtoonLitFromCamera: Bool

    public init(width: Int = 1024,
                height: Int = 1024,
                fieldOfViewInDegrees: Float = 40,
                direction: SIMD3<Float>? = nil,
                margin: Float = 1.05,
                background: CGColor? = nil,
                lightIntensity: Float = 1000,
                mtoonLitFromCamera: Bool = true) {
        self.width = width
        self.height = height
        self.fieldOfViewInDegrees = fieldOfViewInDegrees
        self.direction = direction
        self.margin = margin
        self.background = background
        self.lightIntensity = lightIntensity
        self.mtoonLitFromCamera = mtoonLitFromCamera
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
public enum GLTFSnapshotError: Error {
    /// The machine has no Metal device to render with.
    case noMetalDevice
    case encodingFailed
    /// The entity draws nothing, so there is no frame to fit a camera to.
    case nothingToDraw
    /// An option describes no picture that can be taken, such as a frame with
    /// no pixels in it.
    case invalidOptions(String)
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFSnapshotOptions {
    /// The largest render target any current Metal GPU family will make, which also
    /// keeps the byte count of the buffer the pixels are read into inside an `Int`.
    static let maximumDimension = 16384

    /// Refuses options no camera can be built from, before anything is drawn.
    func validate() throws {
        guard width > 0, height > 0, width <= Self.maximumDimension, height <= Self.maximumDimension else {
            throw GLTFSnapshotError.invalidOptions(
                "a snapshot is between one and \(Self.maximumDimension) pixels on a side, "
                + "and this one is \(width)x\(height)"
            )
        }
        guard fieldOfViewInDegrees > 0, fieldOfViewInDegrees < 180 else {
            throw GLTFSnapshotError.invalidOptions("a snapshot's field of view is between 0 and 180 degrees")
        }
        guard margin.isFinite, margin > 0 else {
            throw GLTFSnapshotError.invalidOptions("a snapshot's margin is finite and greater than zero")
        }
        guard lightIntensity.isFinite, lightIntensity >= 0 else {
            throw GLTFSnapshotError.invalidOptions("a snapshot's light intensity is finite and nonnegative")
        }
        if let direction {
            guard direction.x.isFinite, direction.y.isFinite, direction.z.isFinite,
                  simd_length_squared(direction) > 0 else {
                throw GLTFSnapshotError.invalidOptions(
                    "a snapshot's direction points somewhere, so it is finite and not zero"
                )
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFEntity {
    /// Draws the entity offscreen and returns the image, so a model can be pictured
    /// without a view on screen.
    ///
    /// A copy is drawn, since `RealityRenderer` takes an entity out of whatever it is a
    /// child of. Only this entity is drawn, not the lights and props beside it in its
    /// scene, which ``GLTFSnapshotOptions/lightIntensity`` stands in for.
    @MainActor
    public func snapshot(_ options: GLTFSnapshotOptions = .init()) async throws -> CGImage {
        try options.validate()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw GLTFSnapshotError.noMetalDevice
        }
        let bounds = visualBounds(relativeTo: self)
        guard bounds.extents.max() > 0 else {
            throw GLTFSnapshotError.nothingToDraw
        }

        let camera = Self.makeCamera(bounds: bounds,
                                     direction: options.direction ?? frontDirection,
                                     options: options)
        // The vector MToon wants points from the surface toward the light, which for
        // a light beside the camera is the way the camera is offset.
        let towardCamera = simd_normalize(camera.position - bounds.center)

        // The render encodes on its own queue, so any rows the copy still shares
        // must be on the GPU before it does.
        waitForMToonParameterWrites()
        let subject = clone(recursive: true)
        // The bounds were measured in this entity's own space, so the copy goes there
        // too rather than wherever the entity stands in its scene.
        subject.transform = .identity
        if options.mtoonLitFromCamera {
            relightMToonMaterials(of: subject, towardLight: towardCamera)
        }

        let renderer = try RealityRenderer()
        renderer.entities.append(subject)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.cameraSettings.colorBackground = .color(options.background ?? CGColor(gray: 0, alpha: 0))

        if options.lightIntensity > 0 {
            let light = Entity()
            light.components.set(DirectionalLightComponent(color: .white, intensity: options.lightIntensity))
            light.look(at: bounds.center, from: camera.position, relativeTo: nil)
            renderer.entities.append(light)
        }

        let texture = try Self.makeTexture(device: device, options: options)
        // Awaited rather than waited on, so the main actor is free while the GPU works.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
                try renderer.updateAndRender(deltaTime: 0.01,
                                             cameraOutput: output,
                                             onComplete: { _ in continuation.resume() })
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return try await Self.makeImage(of: texture, device: device)
    }

    /// Gives the copy MToon parameter rows of its own, lit from `direction` and
    /// otherwise this entity's, so picturing a model neither relights the one on
    /// screen nor collides with another snapshot across its await.
    private func relightMToonMaterials(of subject: Entity, towardLight direction: SIMD3<Float>) {
#if !os(visionOS)
        var relit: [Int: CustomMaterial.Texture] = [:]
        for modelEntity in subject.modelEntitiesInHierarchy {
            guard let materialIndex = modelEntity.components[GLTFMaterialIndexComponent.self]?.materialIndex,
                  var component = modelEntity.components[ModelComponent.self] else { continue }
            let texture: CustomMaterial.Texture
            if let cached = relit[materialIndex] {
                texture = cached
            } else {
                guard let resource = mtoonState(forMaterialIndex: materialIndex)?
                    .relitParameterTexture(lightDirection: direction) else { continue }
                texture = CustomMaterial.Texture(resource)
                relit[materialIndex] = texture
            }
            // Only the rows are swapped: `custom.value` carries the mesh's outline
            // budget, which the light has nothing to do with.
            component.materials = component.materials.map { material in
                guard var material = material as? CustomMaterial else { return material }
                material.custom.texture = texture
                return material
            }
            modelEntity.components.set(component)
        }
#endif
    }

    /// ``snapshot(_:)`` encoded as a PNG, which is what a VRM thumbnail is
    /// written from.
    @MainActor
    public func snapshotPNGData(_ options: GLTFSnapshotOptions = .init()) async throws -> Data {
        try Self.encode(try await snapshot(options), as: .png)
    }

    /// A camera looking at `bounds` from `direction`, backed off until the box
    /// fits the frame. The distance is measured along the camera's own axes, so a
    /// model photographed from the side is fitted by the depth that is now width.
    private static func makeCamera(bounds: BoundingBox,
                                   direction: SIMD3<Float>,
                                   options: GLTFSnapshotOptions) -> PerspectiveCamera {
        // The near and far planes are left as RealityKit sets them, which is no far
        // plane at all, so a model of any size fits in front of the camera.
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = options.fieldOfViewInDegrees

        let offset = simd_length(direction) > .ulpOfOne ? simd_normalize(direction) : SIMD3(0, 0, 1)
        camera.look(at: bounds.center, from: bounds.center + offset, relativeTo: nil)
        let basis = float3x3(camera.orientation(relativeTo: nil))
        let right = basis.columns.0
        let up = basis.columns.1

        // The field of view is vertical, so a frame wider than it is tall sees more
        // of the model's width without seeing less of its height.
        let halfHeight = tan(options.fieldOfViewInDegrees / 2 * .pi / 180)
        let halfWidth = halfHeight * Float(options.width) / Float(options.height)

        var distance = camera.camera.near
        for corner in bounds.corners {
            let local = corner - bounds.center
            // How far the corner reaches towards the camera, which is distance the
            // frame does not get to spend on fitting it.
            let towardsCamera = simd_dot(local, offset)
            distance = max(distance,
                           abs(simd_dot(local, right)) * options.margin / halfWidth + towardsCamera,
                           abs(simd_dot(local, up)) * options.margin / halfHeight + towardsCamera,
                           camera.camera.near + towardsCamera)
        }
        camera.look(at: bounds.center, from: bounds.center + offset * distance, relativeTo: nil)
        return camera
    }

    private static func makeTexture(device: any MTLDevice, options: GLTFSnapshotOptions) throws -> any MTLTexture {
        // RealityKit writes the values it drew without encoding them, so an sRGB
        // target is what makes the hardware encode them on the way in.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                                  width: options.width,
                                                                  height: options.height,
                                                                  mipmapped: false)
        // A shader-writable sRGB texture is not something every GPU family makes,
        // and nothing writes to this one outside the render pass.
        descriptor.usage = [.renderTarget, .shaderRead]
        // Only Apple-family GPUs give a texture storage the CPU can read, so the
        // target is private and ``readPixels(of:device:)`` copies out of it.
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw GLTFSnapshotError.invalidOptions(
                "this GPU will not render into a \(options.width)x\(options.height) target"
            )
        }
        return texture
    }

    private static func makeImage(of texture: any MTLTexture, device: any MTLDevice) async throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let pixels = try await readPixels(of: texture, device: device)
        guard let provider = CGDataProvider(data: pixels as CFData),
              // The render target holds its alpha premultiplied.
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            throw GLTFSnapshotError.encodingFailed
        }
        return image
    }

    /// The drawn pixels, copied off the GPU into memory the CPU reads. Blitted into
    /// a buffer, which takes shared storage on every GPU family.
    private static func readPixels(of texture: any MTLTexture, device: any MTLDevice) async throws -> Data {
        let bytesPerRow = texture.width * 4
        let length = bytesPerRow * texture.height
        guard let queue = device.makeCommandQueue(),
              let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else {
            throw GLTFSnapshotError.encodingFailed
        }
        blit.copy(from: texture,
                  sourceSlice: 0,
                  sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer,
                  destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: length)
        blit.endEncoding()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commands.addCompletedHandler { _ in continuation.resume() }
            commands.commit()
        }
        guard commands.error == nil else { throw GLTFSnapshotError.encodingFailed }
        return Data(bytes: buffer.contents(), count: length)
    }

    static func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else {
            throw GLTFSnapshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw GLTFSnapshotError.encodingFailed
        }
        return encoded as Data
    }
}
@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
private extension BoundingBox {
    /// The eight corners of the box, which is what a camera has to fit rather than
    /// the extents, since it looks at the box from an angle of its own.
    var corners: [SIMD3<Float>] {
        (0..<8).map { corner in
            SIMD3(corner & 1 == 0 ? min.x : max.x,
                  corner & 2 == 0 ? min.y : max.y,
                  corner & 4 == 0 ? min.z : max.z)
        }
    }
}

#endif
