#if canImport(RealityKit)
/// The compute kernel that skins and morphs a mesh into its `LowLevelMesh` vertex buffer.
///
/// Compiled at runtime rather than shipped in the MToon metallibs: it is plain Metal
/// with no RealityKit shader dependency, so it compiles on every platform the package
/// renders on, visionOS included, and stays one source with the Swift side that lays
/// out its buffers (``GLTFDeformationContext``).
enum GLTFDeformationKernel {
    static let functionName = "gltfDeformVertices"

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Matches GLTFDeformedVertex and GLTFDeformationUniforms in Swift.
    struct DeformedVertex {
        packed_float3 position;
        packed_float3 normal;
        packed_float3 tangent;
        packed_float3 bitangent;
    };

    struct Uniforms {
        uint vertexCount;
        uint activeTargetCount;
        uint hasNormals;
        uint hasTangents;
        uint isSkinned;
        uint outputCount;
    };

    kernel void gltfDeformVertices(device const DeformedVertex *rest [[buffer(0)]],
                                   device const uint4 *joints [[buffer(1)]],
                                   device const float4 *jointWeights [[buffer(2)]],
                                   device const float4x4 *jointMatrices [[buffer(3)]],
                                   device const packed_float3 *morphDeltas [[buffer(4)]],
                                   device const float *morphWeights [[buffer(5)]],
                                   device const uint *activeTargets [[buffer(6)]],
                                   constant Uniforms &uniforms [[buffer(7)]],
                                   device DeformedVertex *out0 [[buffer(8)]],
                                   device DeformedVertex *out1 [[buffer(9)]],
                                   device DeformedVertex *out2 [[buffer(10)]],
                                   device DeformedVertex *out3 [[buffer(11)]],
                                   device DeformedVertex *out4 [[buffer(12)]],
                                   device DeformedVertex *out5 [[buffer(13)]],
                                   device DeformedVertex *out6 [[buffer(14)]],
                                   device DeformedVertex *out7 [[buffer(15)]],
                                   uint id [[thread_position_in_grid]])
    {
        if (id >= uniforms.vertexCount) return;
        DeformedVertex base = rest[id];
        float3 position = float3(base.position);
        // Only the targets with a weight are summed: a face carries dozens and an
        // expression moves a few.
        for (uint i = 0; i < uniforms.activeTargetCount; i++) {
            uint target = activeTargets[i];
            position += morphWeights[target] * float3(morphDeltas[target * uniforms.vertexCount + id]);
        }
        float3 normal = uniforms.hasNormals ? float3(base.normal) : float3(0.0);
        float3 tangent = uniforms.hasTangents ? float3(base.tangent) : float3(0.0);
        float3 bitangent = uniforms.hasTangents ? float3(base.bitangent) : float3(0.0);

        if (uniforms.isSkinned) {
            uint4 joint = joints[id];
            float4 weight = jointWeights[id];
            // A vertex no joint drives stays where it was authored.
            if (weight.x + weight.y + weight.z + weight.w > 0.0) {
                float4x4 skin = jointMatrices[joint.x] * weight.x
                              + jointMatrices[joint.y] * weight.y
                              + jointMatrices[joint.z] * weight.z
                              + jointMatrices[joint.w] * weight.w;
                position = (skin * float4(position, 1.0)).xyz;
                float3x3 rotation = float3x3(skin[0].xyz, skin[1].xyz, skin[2].xyz);
                normal = normalize(rotation * normal);
                tangent = normalize(rotation * tangent);
                bitangent = normalize(rotation * bitangent);
            }
        }

        // `vertex` is a Metal keyword.
        DeformedVertex deformed;
        deformed.position = position;
        deformed.normal = normal;
        deformed.tangent = tangent;
        deformed.bitangent = bitangent;
        // Every entity drawing the mesh has a vertex buffer of its own. Writing each of them
        // here costs the GPU less than copying the first into the rest, which reads it back.
        device DeformedVertex *outputs[] = { out0, out1, out2, out3, out4, out5, out6, out7 };
        for (uint i = 0; i < uniforms.outputCount; i++) {
            outputs[i][id] = deformed;
        }
    }
    """
}
#endif
