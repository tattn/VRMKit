#if canImport(RealityKit)
import CoreGraphics
import Foundation
import VRMKit
import simd

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension GLTFSceneBuilder {
    /// Whether the MASK material at `index` draws opaque: its base color alpha reaches the
    /// cutoff at every texel its triangles sample, so the cutout draw would discard
    /// nothing and only lose the GPU's rejection of hidden fragments.
    ///
    /// Decided once per document and kept with the resources, since it reads the geometry
    /// against the image. The prepare pass decides every drawn MASK material off the
    /// actor; a material asked for before that is decided on the spot. False for a
    /// material that is not MASK or that cannot be told.
    func drawsCutoutOpaque(materialIndex index: Int) -> Bool {
        if let decided = resources.cutoutsDrawnOpaque[index] { return decided }
        var decided = false
        if let work = try? cutoutCoverageWork(forMaterialIndex: index) {
            let plane = try? work.imageIndex.map { try image(withImageIndex: $0) }.flatMap(GLTFCutoutCoverage.AlphaPlane.init)
            decided = work.decide(plane: plane)
        }
        resources.cutoutsDrawnOpaque[index] = decided
        return decided
    }

    /// Decides every drawn MASK material not yet decided, in parallel off the actor. An
    /// image shared by several materials is read once.
    func prepareCutoutCoverage() async throws {
        var work: [CutoutCoverageWork] = []
        for index in try drawnMaterialIndices().sorted() where resources.cutoutsDrawnOpaque[index] == nil {
            if let item = try cutoutCoverageWork(forMaterialIndex: index) {
                work.append(item)
            } else {
                resources.cutoutsDrawnOpaque[index] = false
            }
        }
        guard !work.isEmpty else { return }
        var images: [Int: CGImage] = [:]
        for imageIndex in Set(work.compactMap(\.imageIndex)) {
            images[imageIndex] = try image(withImageIndex: imageIndex)
        }
        let planes = try await withThrowingTaskGroup(of: (Int, GLTFCutoutCoverage.AlphaPlane?).self) { group in
            for (imageIndex, image) in images {
                let read = ImageRead(image: image)
                group.addTask {
                    try Task.checkCancellation()
                    return (imageIndex, GLTFCutoutCoverage.AlphaPlane(read.image))
                }
            }
            var planes: [Int: GLTFCutoutCoverage.AlphaPlane?] = [:]
            for try await (imageIndex, plane) in group {
                planes[imageIndex] = plane
            }
            return planes
        }
        let decided = try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for item in work {
                let plane = item.imageIndex.flatMap { planes[$0] ?? nil }
                group.addTask {
                    try Task.checkCancellation()
                    return (item.materialIndex, item.decide(plane: plane))
                }
            }
            var results: [(Int, Bool)] = []
            results.reserveCapacity(work.count)
            for try await result in group {
                results.append(result)
            }
            return results
        }
        for (index, draws) in decided {
            resources.cutoutsDrawnOpaque[index] = draws
        }
    }

    /// An image handed to a task: immutable once decoded.
    private struct ImageRead: @unchecked Sendable {
        let image: CGImage
    }

    /// What deciding one MASK material reads, gathered on the actor so the decision can
    /// run off it.
    private struct CutoutCoverageWork: Sendable {
        struct Primitive: Sendable {
            /// In glTF UV space, the top of the image at v = 0.
            let texcoords: [SIMD2<Float>]
            let indices: [UInt32]
        }

        let materialIndex: Int
        /// The base color image, or nil for a material with no base color texture.
        let imageIndex: Int?
        let primitives: [Primitive]
        let sampling: GLTFCutoutCoverage.Sampling
        let alphaFactor: Float
        let cutoff: Float
        /// A material scrolling or rotating its UVs samples the whole image over time.
        let animatesUV: Bool

        /// - Parameter plane: The base color image's alpha, nil for one without alpha.
        func decide(plane: GLTFCutoutCoverage.AlphaPlane?) -> Bool {
            if animatesUV {
                return GLTFCutoutCoverage.isOpaqueEverywhere(plane, alphaFactor: alphaFactor, cutoff: cutoff) ?? false
            }
            guard !primitives.isEmpty else { return false }
            return primitives.allSatisfy {
                GLTFCutoutCoverage.samplesOnlyOpaqueTexels(of: plane,
                                                           texcoords: $0.texcoords,
                                                           indices: $0.indices,
                                                           sampling: sampling,
                                                           alphaFactor: alphaFactor,
                                                           cutoff: cutoff) == true
            }
        }
    }

    /// Nil for a material that is not MASK as authored.
    private func cutoutCoverageWork(forMaterialIndex index: Int) throws -> CutoutCoverageWork? {
        let context = try makeMaterialShaderContext(withMaterialIndex: index)
        guard context.authoredAlphaMode == .MASK else { return nil }
        let material = context.material
        let baseTexture: GLTFSampledTexture?
        let alphaFactor: Float
        let cutoff: Float
        let transform: GLTFUVTransform
        let animatesUV: Bool
        if let mtoon = try mtoonDescriptor(withMaterialIndex: index) {
            baseTexture = mtoon.baseColorTexture
            alphaFactor = mtoon.baseColorFactor.w
            cutoff = mtoon.alphaCutoff
            transform = selectedUVTransform(withMaterialIndex: index, textures: mtoon.uvAccessedTextures)
            animatesUV = mtoon.uvAnimationScrollXSpeedFactor != 0 || mtoon.uvAnimationScrollYSpeedFactor != 0
                || mtoon.uvAnimationRotationSpeedFactor != 0
        } else {
            baseTexture = material.pbrMetallicRoughness?.baseColorTexture.map { GLTFSampledTexture($0) }
            alphaFactor = material.pbrMetallicRoughness?.baseColorFactor.w ?? 1
            cutoff = material.alphaCutoff
            transform = selectedUVTransform(withMaterialIndex: index, textures: sampledTextures(of: material))
            animatesUV = false
        }
        var sampling = GLTFCutoutCoverage.Sampling(transform: transform)
        var imageIndex: Int?
        if let baseTexture {
            imageIndex = try gltf.imageIndex(ofTextureAt: baseTexture.index)
            if let sampler = try gltfSampler(withTextureIndex: baseTexture.index) {
                sampling.wrapS = sampler.wrapS
                sampling.wrapT = sampler.wrapT
            }
        }
        return CutoutCoverageWork(materialIndex: index,
                                  imageIndex: imageIndex,
                                  primitives: try primitivesDrawing(materialIndex: index),
                                  sampling: sampling,
                                  alphaFactor: alphaFactor,
                                  cutoff: cutoff,
                                  animatesUV: animatesUV)
    }

    /// The UVs and triangles of every drawn primitive using the material, from the
    /// prepared geometry or decoded on the spot. One mesh drawn through several skins
    /// reads the same UVs, so each primitive counts once.
    private func primitivesDrawing(materialIndex index: Int) throws -> [CutoutCoverageWork.Primitive] {
        var primitives: [CutoutCoverageWork.Primitive] = []
        var seen: Set<[Int]> = []
        for drawn in try drawnMeshes() {
            for (primitiveIndex, primitive) in resolvedPrimitives(of: drawn.mesh).enumerated()
            where primitive.material == index {
                guard seen.insert([drawn.meshIndex, primitiveIndex]).inserted else { continue }
                let key = PrimitiveGeometryKey(meshIndex: drawn.meshIndex,
                                               primitiveIndex: primitiveIndex,
                                               skinIndex: drawn.skinIndex)
                let geometry: GLTFPrimitiveGeometry?
                if let prepared = prepared.primitives[key] {
                    geometry = prepared?.geometry
                } else {
                    geometry = try geometryDecoder().decode(primitive, skinIndex: drawn.skinIndex)
                }
                guard let geometry, !geometry.texcoords.isEmpty else { continue }
                // The decoder flips V for RealityKit; the shader flips it back before sampling.
                primitives.append(.init(texcoords: geometry.texcoords.map { SIMD2($0.x, 1 - $0.y) },
                                        indices: geometry.indices))
            }
        }
        return primitives
    }
}
#endif
