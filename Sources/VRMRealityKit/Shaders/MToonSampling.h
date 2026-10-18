#ifndef MTOON_SAMPLING_H
#define MTOON_SAMPLING_H

#include <metal_stdlib>

using namespace metal;

// How an MToon texture is sampled, free of RealityKit: glTF's wrap and filter modes applied
// to one repeating sampler, and the UV space the samples are taken in.

// Metal allows at most 16 constant samplers per shader entry point, and the
// budget is shared with the shaders RealityKit generates. Exceeding it only
// shows up at runtime, as a pipeline that never builds: with one sampler per
// addressing mode (nine) the depth-only technique of the outline pass, whose
// vertex stage runs the outline geometry modifier, failed to build on iPhone.
// So the shader owns one repeating sampler for every texture, reads the
// parameter rows by index, and applies glTF's wrap modes (mtoonWrappedCoordinate)
// and filter modes (mtoonWrappedSample) to the coordinate and the sample instead.
constexpr sampler mtoonTextureSampler(coord::normalized,
                                      address::repeat,
                                      mag_filter::linear, min_filter::linear, mip_filter::linear);

// The LOD a sample resolves to, clamped to the texture's mip range like
// calculate_clamped_lod. It needs the screen-space derivatives only a fragment
// function has, so specializing rather than branching keeps the derivative
// instructions out of the code the vertex stage links against.
//
// Computed by hand rather than with calculate_clamped_lod, which crashes the
// on-device Metal compiler (iOS 27.0, iPhone 17 Pro) and leaves RealityKit
// drawing its fallback. This is the isotropic LOD the query gives for these
// samplers, which set no anisotropy.
template <bool ImplicitLOD>
struct MToonSampledLOD {
    static float of(texture2d<half> texture, float2 uv);
};

template <>
struct MToonSampledLOD<true> {
    static float of(texture2d<half> texture, float2 uv)
    {
        const float2 size = float2(texture.get_width(), texture.get_height());
        const float2 dx = dfdx(uv * size);
        const float2 dy = dfdy(uv * size);
        const float footprint = max(dot(dx, dx), dot(dy, dy));
        const float lod = 0.5 * log2(max(footprint, 1e-8));
        return clamp(lod, 0.0, float(texture.get_num_mip_levels()) - 1.0);
    }
};

template <>
struct MToonSampledLOD<false> {
    static float of(texture2d<half>, float2)
    {
        return 0.0;
    }
};

// glTF's wrap modes, applied to one coordinate before it reaches the repeating
// sampler. `mode` is MToonShader.wrapMode(_:): 0 = repeat, 1 = clamp to edge,
// 2 = mirrored repeat. `levelSize` is the size of the coarsest mip level the
// sample touches: a clamped coordinate stays inside that level's outer texel
// centres, so the repeating sampler never filters across the seam, which is
// exactly what clamp_to_edge does. A mirrored coordinate is folded into [0, 1]
// first; at its seams the mirrored neighbour is the edge texel itself, so the
// same clamp reproduces mirrored_repeat too.
inline float mtoonWrappedCoordinate(float coordinate, int mode, float levelSize)
{
    if (mode == 0) {
        return coordinate;
    }
    float folded = coordinate;
    if (mode == 2) {
        const float period = coordinate - 2.0 * floor(coordinate * 0.5);
        folded = 1.0 - abs(period - 1.0);
    }
    const float halfTexel = 0.5 / max(levelSize, 1.0);
    return clamp(folded, halfTexel, 1.0 - halfTexel);
}

// One texture sample with glTF's wrap and filter modes applied. The sampler
// parameter row is (wrapS, wrapT, filterIndex, 0), where filterIndex is
// MToonSamplerFilter.index on the Swift side:
// (magnification * 2 + minification) * 3 + mip, with the texel filters
// 0 = linear, 1 = nearest and the mip filter 0 = none, 1 = nearest, 2 = linear.
template <bool ImplicitLOD>
inline half4 mtoonWrappedSample(texture2d<half> texture, float2 uv, half4 samplerParameters)
{
    const int wrapS = int(float(samplerParameters.x) + 0.5);
    const int wrapT = int(float(samplerParameters.y) + 0.5);
    const int filterIndex = int(float(samplerParameters.z) + 0.5);
    const int mipFilter = filterIndex % 3;
    const bool nearestMinification = (filterIndex / 3) % 2 != 0;
    const bool nearestMagnification = filterIndex / 6 != 0;

    // The LOD comes from the unwrapped coordinate: folding a mirrored coordinate
    // flips its derivatives but not their size, and the sample below takes the
    // level explicitly, so the sampler never sees the wrapped derivatives. The
    // outline geometry modifier has no implicit LOD at all, so it samples level 0.
    const float sampledLod = MToonSampledLOD<ImplicitLOD>::of(texture, uv);
    // glTF's NEAREST and LINEAR minFilters do not mipmap, so they are level 0;
    // the MIPMAP_NEAREST filters take the nearest level; the MIPMAP_LINEAR
    // filters blend the two levels the fractional LOD falls between.
    const float lod = mipFilter == 0 ? 0.0 : (mipFilter == 1 ? round(sampledLod) : sampledLod);
    // Magnification and minification are independent glTF filters; the LOD the
    // sampler resolved is what decides which of the two applies here.
    const bool nearest = sampledLod > 0.0 ? nearestMinification : nearestMagnification;

    // A blended sample touches the level above the fractional LOD as well, and
    // its texels are the larger ones, so its size sets the clamp.
    const uint coarsestLevel = uint(ceil(lod));
    const float2 coarsestSize = float2(texture.get_width(coarsestLevel), texture.get_height(coarsestLevel));
    float2 sampleUV = float2(mtoonWrappedCoordinate(uv.x, wrapS, coarsestSize.x),
                             mtoonWrappedCoordinate(uv.y, wrapT, coarsestSize.y));
    if (nearest) {
        // A linear sampler returns one texel exactly when the coordinate sits at
        // that texel's centre, so NEAREST costs a coordinate snap instead of a
        // sampler of its own. It is approximate only where two levels are blended.
        const float2 levelSize = float2(texture.get_width(uint(lod)), texture.get_height(uint(lod)));
        sampleUV = (floor(sampleUV * levelSize) + 0.5) / levelSize;
    }
    return texture.sample(mtoonTextureSampler, sampleUV, level(lod));
}

// Fragment-stage sampling: the LOD comes from the screen-space derivatives.
inline half4 mtoonSample(texture2d<half> texture, float2 uv, half4 samplerParameters)
{
    return mtoonWrappedSample<true>(texture, uv, samplerParameters);
}

// Vertex-stage sampling for the geometry modifier, which has no derivatives.
inline half4 mtoonVertexSample(texture2d<half> texture, float2 uv, half4 samplerParameters)
{
    return mtoonWrappedSample<false>(texture, uv, samplerParameters);
}

// Converts the mesh UV the loader writes (v pointing up, as RealityKit reads it)
// into the glTF / MToon UV space that KHR_texture_transform, MToon UV animation
// and Metal texture sampling all share (v pointing down).
//
// This runs once, *before* any UV math: MToon's animation and
// KHR_texture_transform are both defined in glTF UV space, so flipping
// afterwards would invert Y offsets and the rotation direction, and shift
// anything with a Y scale.
inline float2 mtoonTextureUV(float2 uv)
{
    return float2(uv.x, 1.0 - uv.y);
}

inline float2 mtoonTransformedUV(float2 uv, half4 uvTransform, half4 uvTransformRotation)
{
    float2 transformed = uv * float2(uvTransform.xy);
    float c = float(uvTransformRotation.x);
    float s = float(uvTransformRotation.y);
    transformed = float2(transformed.x * c - transformed.y * s,
                         transformed.x * s + transformed.y * c);
    return transformed + float2(uvTransform.zw);
}

#endif
