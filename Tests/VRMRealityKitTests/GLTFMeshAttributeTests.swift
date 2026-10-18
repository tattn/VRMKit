#if canImport(RealityKit)
import Foundation
import RealityKit
import Testing
import VRMKit
import VRMTestSupport
@testable import VRMRealityKit

/// What the loader makes of a primitive's vertex attributes: the tangent basis
/// it generates where a mesh states none, and the malformed accessors it refuses
/// rather than drawing from.
@Suite
@MainActor
struct GLTFMeshAttributeTests {
    /// Seed-san's normal-mapped materials have no glTF TANGENT attribute, so every basis
    /// checked here is the generated one.
    @Test
    func testGeneratedTangentBasis() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        var completeParts = 0
        var bitangents = (checked: 0, agreeing: 0)
        var handedMeshes = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            if let geometry = modelEntity.gltfMeshGeometry {
                completeParts += Self.checkTangentBasisIsComplete(geometry)
                let agreement = Self.bitangentsAgreeingWithTheImage(geometry)
                bitangents.checked += agreement.checked
                bitangents.agreeing += agreement.agreeing
            }
            if let mesh = modelEntity.deformedMesh, try Self.checkTangentFrameHandRidesInUV1(mesh) {
                handedMeshes += 1
            }
        }
        #expect(completeParts > 0)
        #expect(bitangents.checked > 0)
        // Vertices shared by triangles with opposing UV gradients average out, so
        // a few legitimately disagree; a flipped basis inverts the ratio entirely.
        #expect(Float(bitangents.agreeing) > Float(bitangents.checked) * 0.9)
        #expect(handedMeshes > 0)
    }

    /// Checks every slot that carries a tangent basis, and returns how many did.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func checkTangentBasisIsComplete(_ geometry: GLTFMeshGeometry) -> Int {
        guard !geometry.tangents.isEmpty else { return 0 }
        #expect(geometry.tangents.count == geometry.positions.count)
        #expect(geometry.bitangents.count == geometry.tangents.count)
        var checkedParts = 0
        // A slot whose material samples no normal map carries zero tangents; the
        // others must be complete, since MToon.metal falls back to the geometry
        // normal unless both buffers are present and non-degenerate.
        for slot in geometry.slots {
            let tangents = geometry.tangents[slot.vertexRange]
            let bitangents = geometry.bitangents[slot.vertexRange]
            guard tangents.contains(where: { simd_length_squared($0) > 0 }) else { continue }
            #expect(tangents.allSatisfy { simd_length_squared($0) > 0.5 })
            #expect(bitangents.allSatisfy { simd_length_squared($0) > 0.5 })
            checkedParts += 1
        }
        return checkedParts
    }

    /// A normal map's +Y points up the image, so the generated bitangent follows
    /// the stored v, which grows upward, as UniVRM's Unity-generated tangents do.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func bitangentsAgreeingWithTheImage(_ geometry: GLTFMeshGeometry) -> (checked: Int, agreeing: Int) {
        let bitangents = geometry.bitangents
        let texcoords = geometry.texcoords
        let positions = geometry.positions
        guard !bitangents.isEmpty, !texcoords.isEmpty else { return (0, 0) }
        var checked = 0
        var agreeing = 0
        for slot in geometry.slots.indices {
            let indices = Array(geometry.triangleIndices(ofSlot: slot))
            for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
                let i0 = Int(indices[triangle])
                let i1 = Int(indices[triangle + 1])
                let i2 = Int(indices[triangle + 2])
                let deltaUV1 = texcoords[i1] - texcoords[i0]
                let deltaUV2 = texcoords[i2] - texcoords[i0]
                let determinant = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y
                guard abs(determinant) > 1e-9 else { continue }
                let edge1 = positions[i1] - positions[i0]
                let edge2 = positions[i2] - positions[i0]
                let expected = (edge2 * deltaUV1.x - edge1 * deltaUV2.x) / determinant
                // A slot without a normal map has no basis to agree with.
                guard simd_length_squared(expected) > 1e-10,
                      simd_length_squared(bitangents[i0]) > 0.5 else { continue }
                checked += 1
                if simd_dot(simd_normalize(expected), bitangents[i0]) > 0 {
                    agreeing += 1
                }
            }
        }
        return (checked, agreeing)
    }

    /// RealityKit hands a surface shader the tangent of a right-handed frame, so each vertex's
    /// hand rides in uv1 for MToon to turn a mirrored tangent back; a mesh without tangents
    /// carries no uv1. Returns whether the mesh carried a hand to check.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private static func checkTangentFrameHandRidesInUV1(_ mesh: GLTFDeformedMesh) throws -> Bool {
        let geometry = mesh.geometry
        let uv1 = mesh.lowLevelMesh.descriptor.vertexAttributes.first { $0.semantic == .uv1 }
        guard !geometry.tangents.isEmpty else {
            #expect(uv1 == nil)
            return false
        }
        let attribute = try #require(uv1)
        let bufferIndex = mesh.lowLevelMesh.descriptor.vertexLayouts[attribute.layoutIndex].bufferIndex
        var hands: [SIMD2<Float>] = []
        mesh.lowLevelMesh.withUnsafeBytes(bufferIndex: bufferIndex) { hands = Array($0.bindMemory(to: SIMD2<Float>.self)) }
        for index in 0..<geometry.vertexCount {
            let hand = simd_dot(simd_cross(geometry.normals[index], geometry.tangents[index]), geometry.bitangents[index])
            #expect(hands[index].x == (hand < 0 ? -1 : 1))
        }
        return true
    }

    /// Accessors that break what glTF requires of a primitive, each of which has to fail
    /// the load rather than be drawn from.
    enum MalformedAccessor: CaseIterable {
        /// glTF requires every vertex attribute to match POSITION in length.
        case shortNormal
        /// glTF defines `JOINTS_n` as unsigned integer indices, and converting a signed
        /// one to `UInt32` would trap.
        case signedJoints
        /// glTF defines `inverseBindMatrices` as one matrix per skin joint, and padding a
        /// short one with identities would bind the wrong rest pose.
        case shortInverseBindMatrices
        /// A TRIANGLES primitive holds a multiple of three indices, and trimming the
        /// remainder would draw a triangle list the file does not describe.
        case partialTriangle
        /// glTF stores `WEIGHTS_n` as floats or as normalized integers. An unnormalized
        /// integer accessor holds raw counts, not the 0...1 weights the joint influences
        /// are built from.
        case unnormalizedJointWeights

        /// What the error has to name, where the failure says which accessor it was.
        var messageFragment: String? {
            switch self {
            case .shortNormal, .signedJoints: nil
            case .shortInverseBindMatrices: "inverseBindMatrices"
            case .partialTriangle: "TRIANGLES"
            case .unnormalizedJointWeights: "WEIGHTS_0"
            }
        }

        func rewrite(_ json: inout [String: JSONValue]) throws {
            var accessors = json.objects("accessors")
            let primitive = json.objects("meshes").first?.objects("primitives").first
            let attributes = primitive?.object("attributes")
            switch self {
            case .shortNormal:
                guard let normalIndex = attributes?.int("NORMAL"),
                      accessors.indices.contains(normalIndex),
                      let count = accessors[normalIndex].int("count"), count > 1 else {
                    throw VRMError.dataInconsistent("Missing Seed-san NORMAL accessor")
                }
                accessors[normalIndex]["count"] = .int(count - 1)
            case .signedJoints:
                guard let jointsIndex = attributes?.int("JOINTS_0"),
                      accessors.indices.contains(jointsIndex),
                      // The signed counterpart of the same width, so the component
                      // type is what fails the load.
                      let signed = [5121: 5120, 5123: 5122][accessors[jointsIndex].int("componentType") ?? 0] else {
                    throw VRMError.dataInconsistent("Missing Seed-san JOINTS_0 accessor")
                }
                accessors[jointsIndex]["componentType"] = .int(signed)
            case .shortInverseBindMatrices:
                guard let matricesIndex = json.objects("skins").first?.int("inverseBindMatrices"),
                      accessors.indices.contains(matricesIndex),
                      let count = accessors[matricesIndex].int("count"), count > 1 else {
                    throw VRMError.dataInconsistent("Missing Seed-san inverseBindMatrices accessor")
                }
                accessors[matricesIndex]["count"] = .int(count - 1)
            case .partialTriangle:
                guard let indicesIndex = primitive?.int("indices"),
                      accessors.indices.contains(indicesIndex),
                      let count = accessors[indicesIndex].int("count"), count > 3 else {
                    throw VRMError.dataInconsistent("Missing Seed-san indices accessor")
                }
                accessors[indicesIndex]["count"] = .int(count - 1)
            case .unnormalizedJointWeights:
                guard let weightsIndex = attributes?.int("WEIGHTS_0"),
                      accessors.indices.contains(weightsIndex) else {
                    throw VRMError.dataInconsistent("Missing Seed-san WEIGHTS_0 accessor")
                }
                // Narrower than the float components the fixture ships, so the
                // missing `normalized` flag is what fails the load.
                accessors[weightsIndex]["componentType"] = 5121
                accessors[weightsIndex]["normalized"] = false
            }
            json["accessors"] = .objects(accessors)
        }
    }

    @Test(arguments: MalformedAccessor.allCases)
    func testMalformedAccessorFailsTheLoad(_ accessor: MalformedAccessor) async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "\(accessor)", modify: accessor.rewrite)

        let loader = try VRMEntityLoader(withData: data)
        await #expect {
            try await loader.loadEntity()
        } throws: { error in
            guard let error = error as? VRMError else { return false }
            guard let fragment = accessor.messageFragment else { return true }
            return error.kind == .dataInconsistent && error.message.contains(fragment)
        }
    }

    /// VRM 0.x keeps its normal map in Unity's `_BumpMap`, which the migration
    /// surfaces on the MToon descriptor rather than on the glTF material, so a
    /// primitive without TANGENT still needs a generated basis for it.
    @Test
    func testVRM0BumpMapGeneratesATangentBasisWithoutTANGENT() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let materialIndex = 0
        let data = try TestSupport.modifiedAliciaSolidData(name: "VRM0 _BumpMap without TANGENT") { json in
            guard var extensions = json.object("extensions"),
                  var vrm = extensions.object("VRM") else {
                throw VRMError.dataInconsistent("Missing AliciaSolid material properties")
            }
            var properties = vrm.objects("materialProperties")
            guard properties.indices.contains(materialIndex),
                  var textures = properties[materialIndex].object("textureProperties"),
                  let mainTexture = textures["_MainTex"] else {
                throw VRMError.dataInconsistent("Missing AliciaSolid material properties")
            }
            var meshes = json.objects("meshes")
            // The fixture ships unlit materials with a TANGENT accessor, which
            // is the opposite of what this exercises.
            properties[materialIndex]["shader"] = "VRM/MToon"
            textures["_BumpMap"] = mainTexture
            properties[materialIndex]["textureProperties"] = .object(textures)
            vrm["materialProperties"] = .objects(properties)
            extensions["VRM"] = .object(vrm)
            json["extensions"] = .object(extensions)

            for meshIndex in meshes.indices {
                var primitives = meshes[meshIndex].objects("primitives")
                guard !primitives.isEmpty else { continue }
                for primitiveIndex in primitives.indices {
                    guard primitives[primitiveIndex].int("material") == materialIndex,
                          var attributes = primitives[primitiveIndex].object("attributes") else { continue }
                    attributes.removeValue(forKey: "TANGENT")
                    primitives[primitiveIndex]["attributes"] = .object(attributes)
                }
                meshes[meshIndex]["primitives"] = .objects(primitives)
            }
            json["meshes"] = .objects(meshes)
        }

        let loader = try VRMEntityLoader(withData: data, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        var checkedParts = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let slots = modelEntity.components[GLTFMaterialSlotsComponent.self]?.materialIndices,
                  let geometry = modelEntity.gltfMeshGeometry else { continue }
            for (slot, slotGeometry) in geometry.slots.enumerated()
            where slot < slots.count && slots[slot] == materialIndex {
                #expect(geometry.tangents.count == geometry.positions.count)
                #expect(geometry.bitangents.count == geometry.tangents.count)
                #expect(geometry.tangents[slotGeometry.vertexRange].contains { simd_length_squared($0) > 0.5 })
                checkedParts += 1
            }
        }
        #expect(checkedParts > 0)
    }
}
#endif
