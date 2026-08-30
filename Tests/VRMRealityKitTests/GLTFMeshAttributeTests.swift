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
    @Test
    func testNormalMappedMeshesCarryACompleteTangentBasis() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        var checkedParts = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let mesh = modelEntity.components[ModelComponent.self]?.mesh else { continue }
            for part in mesh.contents.models.flatMap(\.parts) {
                guard let tangents = part.tangents?.elements, !tangents.isEmpty else { continue }
                // MToon.metal falls back to the geometry normal unless both
                // buffers are present and non-degenerate.
                let bitangents = try #require(part.bitangents?.elements)
                #expect(tangents.count == part.positions.count)
                #expect(bitangents.count == tangents.count)
                #expect(tangents.allSatisfy { simd_length_squared($0) > 0.5 })
                #expect(bitangents.allSatisfy { simd_length_squared($0) > 0.5 })
                checkedParts += 1
            }
        }
        // Seed-san's normal-mapped materials have no glTF TANGENT attribute, so
        // reaching this count also proves the generated basis is used.
        #expect(checkedParts > 0)
    }

    /// MToon samples the normal map in glTF UV space, where v points down, while
    /// the mesh stores UVs with v up, so the generated bitangent has to follow
    /// glTF +v to match what a TANGENT accessor supplies.
    @Test
    func testGeneratedBitangentsFollowTheGLTFUVOrientation() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let loader = try VRMEntityLoader(withData: TestSupport.seedSanData, shaders: TestSupport.noOutlineShaders)
        let vrmEntity = try await loader.loadEntity()

        var checkedTriangles = 0
        var agreeingTriangles = 0
        for modelEntity in TestSupport.modelEntities(in: vrmEntity) {
            guard let mesh = modelEntity.components[ModelComponent.self]?.mesh else { continue }
            for part in mesh.contents.models.flatMap(\.parts) {
                guard let bitangents = part.bitangents?.elements, !bitangents.isEmpty,
                      let texcoords = part.textureCoordinates?.elements,
                      let indices = part.triangleIndices?.elements else { continue }
                let positions = part.positions.elements
                for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
                    let i0 = Int(indices[triangle])
                    let i1 = Int(indices[triangle + 1])
                    let i2 = Int(indices[triangle + 2])
                    let deltaUV1 = texcoords[i1] - texcoords[i0]
                    let deltaUV2 = texcoords[i2] - texcoords[i0]
                    // The stored v runs the other way, so the glTF-space
                    // determinant is the stored one negated.
                    let determinant = deltaUV2.x * deltaUV1.y - deltaUV1.x * deltaUV2.y
                    guard abs(determinant) > 1e-9 else { continue }
                    let edge1 = positions[i1] - positions[i0]
                    let edge2 = positions[i2] - positions[i0]
                    let expected = (edge2 * deltaUV1.x - edge1 * deltaUV2.x) / determinant
                    guard simd_length_squared(expected) > 1e-10 else { continue }
                    checkedTriangles += 1
                    if simd_dot(simd_normalize(expected), bitangents[i0]) > 0 {
                        agreeingTriangles += 1
                    }
                }
            }
        }
        #expect(checkedTriangles > 0)
        // Vertices shared by triangles with opposing UV gradients average out, so
        // a few legitimately disagree; a flipped basis inverts the ratio entirely.
        #expect(Float(agreeingTriangles) > Float(checkedTriangles) * 0.9)
    }

    /// glTF requires every vertex attribute to match POSITION in length, so a
    /// short NORMAL accessor has to fail the load.
    @Test
    func testVertexAttributeShorterThanPositionFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "short NORMAL") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let attributes = primitives.first?.object("attributes"),
                  let normalIndex = attributes.int("NORMAL"),
                  accessors.indices.contains(normalIndex),
                  let count = accessors[normalIndex].int("count"), count > 1 else {
                throw VRMError.dataInconsistent("Missing Seed-san NORMAL accessor")
            }
            accessors[normalIndex]["count"] = .int(count - 1)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect(throws: VRMError.self) {
            try await loader.loadEntity()
        }
    }

    /// glTF defines `JOINTS_n` as unsigned integer indices, and converting a
    /// signed one to `UInt32` would trap, so the load has to fail.
    @Test
    func testSignedJointIndicesFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "signed JOINTS_0") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let attributes = primitives.first?.object("attributes"),
                  let jointsIndex = attributes.int("JOINTS_0"),
                  accessors.indices.contains(jointsIndex),
                  // The signed counterpart of the same width, so the component
                  // type is what fails the load.
                  let signed = [5121: 5120, 5123: 5122][accessors[jointsIndex].int("componentType") ?? 0] else {
                throw VRMError.dataInconsistent("Missing Seed-san JOINTS_0 accessor")
            }
            accessors[jointsIndex]["componentType"] = .int(signed)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect(throws: VRMError.self) {
            try await loader.loadEntity()
        }
    }

    /// glTF defines `inverseBindMatrices` as one matrix per skin joint, and
    /// padding a short one with identities would bind the wrong rest pose.
    @Test
    func testShortInverseBindMatricesFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "short inverseBindMatrices") { json in
            var accessors = json.objects("accessors")
            guard let matricesIndex = json.objects("skins").first?.int("inverseBindMatrices"),
                  accessors.indices.contains(matricesIndex),
                  let count = accessors[matricesIndex].int("count"), count > 1 else {
                throw VRMError.dataInconsistent("Missing Seed-san inverseBindMatrices accessor")
            }
            accessors[matricesIndex]["count"] = .int(count - 1)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect {
            try await loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "inverseBindMatrices")
        }
    }

    /// A TRIANGLES primitive holds a multiple of three indices, and trimming the
    /// remainder would draw a triangle list the file does not describe.
    @Test
    func testTriangleIndexCountThatIsNotAMultipleOfThreeFailsTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "partial triangle") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let indicesIndex = primitives.first?.int("indices"),
                  accessors.indices.contains(indicesIndex),
                  let count = accessors[indicesIndex].int("count"), count > 3 else {
                throw VRMError.dataInconsistent("Missing Seed-san indices accessor")
            }
            accessors[indicesIndex]["count"] = .int(count - 1)
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect {
            try await loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "TRIANGLES")
        }
    }

    /// glTF stores `WEIGHTS_n` as floats or as normalized integers. An
    /// unnormalized integer accessor holds raw counts, not the 0...1 weights the
    /// joint influences are built from.
    @Test
    func testUnnormalizedIntegerJointWeightsFailTheLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let data = try TestSupport.modifiedSeedSanData(name: "unnormalized WEIGHTS_0") { json in
            var accessors = json.objects("accessors")
            let primitives = json.objects("meshes").first?.objects("primitives") ?? []
            guard let attributes = primitives.first?.object("attributes"),
                  let weightsIndex = attributes.int("WEIGHTS_0"),
                  accessors.indices.contains(weightsIndex) else {
                throw VRMError.dataInconsistent("Missing Seed-san WEIGHTS_0 accessor")
            }
            // Narrower than the float components the fixture ships, so the
            // missing `normalized` flag is what fails the load.
            accessors[weightsIndex]["componentType"] = 5121
            accessors[weightsIndex]["normalized"] = false
            json["accessors"] = .objects(accessors)
        }

        let loader = try VRMEntityLoader(withData: data)
        await #expect {
            try await loader.loadEntity()
        } throws: { error in
            isDataInconsistent(error, containing: "WEIGHTS_0")
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
                  let mesh = modelEntity.components[ModelComponent.self]?.mesh else { continue }
            for part in mesh.contents.models.flatMap(\.parts)
            where part.materialIndex < slots.count && slots[part.materialIndex] == materialIndex {
                let tangents = try #require(part.tangents?.elements)
                let bitangents = try #require(part.bitangents?.elements)
                #expect(tangents.count == part.positions.count)
                #expect(bitangents.count == tangents.count)
                #expect(tangents.contains { simd_length_squared($0) > 0.5 })
                checkedParts += 1
            }
        }
        #expect(checkedParts > 0)
    }

    private func isDataInconsistent(_ error: any Error, containing fragment: String) -> Bool {
        guard let error = error as? VRMError, error.kind == .dataInconsistent else { return false }
        return error.message.contains(fragment)
    }
}
#endif
