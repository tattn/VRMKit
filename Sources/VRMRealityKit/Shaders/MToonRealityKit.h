#ifndef MTOON_REALITYKIT_H
#define MTOON_REALITYKIT_H

#include <RealityKit/RealityKit.h>

#include "MToonCore.h"

using namespace metal;

// The RealityKit adapter for the MToon specification math in MToonCore.h: the
// material layout MToonShader binds (texture slots, parameter rows and
// custom.value) and the helpers the entry points in MToon.metal are built from.
// Functions named realityKitApproximate* are approximations imposed by
// RealityKit's CustomMaterial constraints, not MToon semantics.
//
// A replacement entry point (MToonShaderFunctions) includes this header. Its
// functions are inline, so several source files of one library can include it.

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

// Parameter rows, mirroring MToonParameterRow on the Swift side.
constant float mtoonRowBaseColor = 0.0;
constant float mtoonRowShadeColor = 1.0;
constant float mtoonRowRimColor = 2.0;
constant float mtoonRowMatcapColor = 3.0;
constant float mtoonRowOutlineColor = 4.0;
constant float mtoonRowShadeParams = 5.0;
constant float mtoonRowRimParams = 6.0;
constant float mtoonRowOutlineParams = 7.0;
constant float mtoonRowUvAnimation = 8.0;
constant float mtoonRowFeatureFlags = 9.0;
constant float mtoonRowExtraFlags = 10.0;
constant float mtoonRowEmissiveFactor = 11.0;
constant float mtoonRowLightColor = 12.0;
constant float mtoonRowAmbientColor = 13.0;
constant float mtoonRowUvTransform = 14.0;
constant float mtoonRowUvTransformRotation = 15.0;
constant float mtoonRowNormalParameters = 16.0;
constant float mtoonRowLightDirection = 17.0;
constant float mtoonSamplerParameterStart = 18.0;
// The rows left to the app (MToonAnimatableMaterialState.setUserParameter).
constant float mtoonUserParameterStart = 27.0;

// Sampler parameter slots, mirroring MToonTextureSlot on the Swift side.
constant float mtoonSamplerSlotBase = 0.0;
constant float mtoonSamplerSlotShade = 1.0;
constant float mtoonSamplerSlotShadingShift = 2.0;
constant float mtoonSamplerSlotNormal = 3.0;
constant float mtoonSamplerSlotMatcap = 4.0;
constant float mtoonSamplerSlotEmissive = 5.0;
constant float mtoonSamplerSlotRim = 6.0;
constant float mtoonSamplerSlotOutlineWidth = 7.0;
constant float mtoonSamplerSlotUvAnimationMask = 8.0;

// The parameter texture is one row of texels, as wide as the app's user rows make
// it, so a row is fetched by index rather than sampled at a fixed width. A fetch
// needs no derivatives, which leaves the compiler free to sink these reads into
// the branches that actually consume them.
inline half4 mtoonParameter(realitykit::texture::textures textures, float row)
{
    return textures.custom().read(uint2(uint(row), 0));
}

inline half4 mtoonSamplerParameter(realitykit::texture::textures textures, float slot)
{
    return mtoonParameter(textures, mtoonSamplerParameterStart + slot);
}

inline half4 mtoonUserParameter(realitykit::texture::textures textures, float index)
{
    return mtoonParameter(textures, mtoonUserParameterStart + index);
}

// The LOD a sample resolves to, clamped to the texture's mip range like
// calculate_clamped_lod. It needs the screen-space derivatives only a fragment
// function has, so specializing -- rather than branching -- keeps the derivative
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

// RealityKit tone maps every CustomMaterial draw; this inverts it.
constant float mtoonRealityKitInverseToneMap[65] = {
    0.0000, 0.0040, 0.0075, 0.0106, 0.0135, 0.0169, 0.0209, 0.0251,
    0.0298, 0.0344, 0.0395, 0.0451, 0.0512, 0.0574, 0.0641, 0.0714,
    0.0791, 0.0873, 0.0958, 0.1047, 0.1142, 0.1247, 0.1365, 0.1488,
    0.1615, 0.1747, 0.1885, 0.2025, 0.2170, 0.2324, 0.2499, 0.2682,
    0.2872, 0.3068, 0.3272, 0.3482, 0.3699, 0.3924, 0.4158, 0.4400,
    0.4661, 0.4939, 0.5225, 0.5523, 0.5805, 0.6128, 0.6528, 0.6925,
    0.7323, 0.7721, 0.8151, 0.8649, 0.9147, 0.9694, 1.0304, 1.0875,
    1.1516, 1.2234, 1.3086, 1.3939, 1.4796, 1.5861, 1.7011, 1.8490,
    2.0000
};

inline float realityKitInverseToneMapChannel(float target)
{
    const float encoded = target <= 0.0031308f
        ? target * 12.92f
        : 1.055f * metal::pow(target, 1.0f / 2.4f) - 0.055f;
    const float scaled = saturate(encoded) * 64.0f;
    const int index = min(int(scaled), 63);
    return mix(mtoonRealityKitInverseToneMap[index],
               mtoonRealityKitInverseToneMap[index + 1],
               scaled - float(index));
}

inline float3 realityKitInverseToneMap(float3 color)
{
    return float3(realityKitInverseToneMapChannel(color.x),
                  realityKitInverseToneMapChannel(color.y),
                  realityKitInverseToneMapChannel(color.z));
}

// The inversion assumes the render pass tone maps. A renderer that has turned
// tone mapping off (RealityRenderer.cameraSettings.isToneMappingEnabled) says
// so through custom_parameter().x == 0 and gets the color as is; the table is
// calibrated for one tone curve and does not hold on every platform.
inline float3 mtoonOutputColor(float4 customParameter, float3 color)
{
    return customParameter.x > 0.5f ? realityKitInverseToneMap(color) : color;
}

// RealityKit does not expose the fully evaluated lit term to the outline
// pass; use the runtime light color as the lit approximation.
inline float3 realityKitApproximateOutlineLighting(float3 lightColor, float outlineLightingMix)
{
    return mix(float3(1.0), lightColor, saturate(outlineLightingMix));
}

// Converts RealityKit's mesh UV (v pointing up, as GLTFEntityLoader writes it)
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

inline float3 mtoonLightDirection(realitykit::texture::textures textures)
{
    // GLTFEntity always writes a normalized direction, so this only guards against
    // an unwritten row; renormalizing would cost every fragment.
    float3 direction = float3(mtoonParameter(textures, mtoonRowLightDirection).xyz);
    if (all(direction == 0.0)) {
        return float3(0.0, 0.0, 1.0);
    }
    return direction;
}

inline float3 mtoonShadingNormal(realitykit::surface_parameters params,
                           float2 uv,
                           half4 extraFlags,
                           half normalScale,
                           half4 normalSampler)
{
    float3 geometryNormal = normalize(params.geometry().normal());
    if (extraFlags.x < 0.5h) {
        return geometryNormal;
    }
    half3 tangentNormal = realitykit::unpack_normal(mtoonSample(params.textures().normal(), uv, normalSampler).rgb,
                                                    normalScale);
    float3 rawTangent = params.geometry().tangent();
    float3 rawBitangent = params.geometry().bitangent();
    if (dot(rawTangent, rawTangent) < 0.000001 || dot(rawBitangent, rawBitangent) < 0.000001) {
        return geometryNormal;
    }
    float3 tangent = normalize(rawTangent);
    float3 bitangent = normalize(rawBitangent);
    return normalize(tangent * float(tangentNormal.x)
                   + bitangent * float(tangentNormal.y)
                   + geometryNormal * float(tangentNormal.z));
}

inline float mtoonAlpha(float alphaMode, float baseAlpha, float cutoff)
{
    if (alphaMode < 0.5) {
        return 1.0;
    }
    if (alphaMode < 1.5) {
        if (baseAlpha < cutoff) {
            discard_fragment();
        }
        return 1.0;
    }
    return baseAlpha;
}

// Both surface entry points resolve opacity and write their result the same way.
inline float mtoonOpacity(float opacityThreshold,
                   half4 baseSample,
                   half4 baseColorFactor,
                   half4 extraFlags,
                   half4 shadeParams)
{
    const float cutoff = opacityThreshold > 0.0 ? opacityThreshold : float(shadeParams.w);
    return mtoonAlpha(float(extraFlags.w), float(baseSample.a * baseColorFactor.a), cutoff);
}

template <bool ImplicitLOD>
inline float2 mtoonAnimatedUVImpl(realitykit::texture::textures textures,
                           float time,
                           float2 uv,
                           half4 uvAnimation,
                           half4 featureFlags,
                           half4 uvAnimationMaskSampler,
                           half4 uvTransform,
                           half4 uvTransformRotation)
{
    // Most materials animate nothing, so skip the mask sample and the rotation.
    if (all(uvAnimation.xyz == 0.0h)) {
        return uv;
    }

    // `uv` is already in glTF UV space, so the mask only needs the transform.
    float mask = 1.0;
    if (featureFlags.w > 0.5h) {
        float2 maskUV = mtoonTransformedUV(uv, uvTransform, uvTransformRotation);
        mask = float(mtoonWrappedSample<ImplicitLOD>(textures.ambient_occlusion(), maskUV, uvAnimationMaskSampler).b);
    }

    // Scrolling without rotation is the common case, so the rotation is its own
    // branch rather than a sin/cos of a zero angle.
    float2 animated = uv;
    if (uvAnimation.z != 0.0h) {
        float angle = float(uvAnimation.z) * time * mask;
        float2 center = float2(0.5, 0.5);
        float2 centered = uv - center;
        float s = sin(angle);
        float c = cos(angle);
        animated = float2(centered.x * c - centered.y * s,
                          centered.x * s + centered.y * c) + center;
    }
    return animated + float2(float(uvAnimation.x), float(uvAnimation.y)) * time * mask;
}

inline float2 mtoonAnimatedUV(realitykit::texture::textures textures,
                       float time,
                       float2 uv,
                       half4 uvAnimation,
                       half4 featureFlags,
                       half4 uvAnimationMaskSampler,
                       half4 uvTransform,
                       half4 uvTransformRotation)
{
    return mtoonAnimatedUVImpl<true>(textures, time, uv, uvAnimation, featureFlags,
                                     uvAnimationMaskSampler, uvTransform, uvTransformRotation);
}

// The geometry modifier's counterpart: same animation, sampled at level 0.
inline float2 mtoonVertexAnimatedUV(realitykit::texture::textures textures,
                             float time,
                             float2 uv,
                             half4 uvAnimation,
                             half4 featureFlags,
                             half4 uvAnimationMaskSampler,
                             half4 uvTransform,
                             half4 uvTransformRotation)
{
    return mtoonAnimatedUVImpl<false>(textures, time, uv, uvAnimation, featureFlags,
                                      uvAnimationMaskSampler, uvTransform, uvTransformRotation);
}

// RealityKit's geometry_parameters exposes projection matrices but no viewport
// size, so a screen-coordinate width is a fraction of the normalized screen
// height rather than a pixel count.
//
// Returns the distance covering that fraction, in view space, which is also the
// world-space distance it is applied as: a camera does not scale.
inline float realityKitApproximateScreenOutlineWidth(realitykit::geometry_parameters params, float width, float3 worldDirection)
{
    float4x4 modelToView = params.uniforms().model_to_view();
    float4x4 viewToProjection = params.uniforms().view_to_projection();
    float4 viewPosition = modelToView * float4(params.geometry().model_position(), 1.0);
    // Measured along the direction the vertex actually moves. A normal put
    // through model_to_view instead would skew under a non-uniform scale.
    float3 viewDirection = normalize((modelToView * (params.uniforms().world_to_model()
                                                     * float4(worldDirection, 0.0))).xyz);
    float4 clipPosition = viewToProjection * viewPosition;
    float4 offsetClipPosition = viewToProjection * (viewPosition + float4(viewDirection, 0.0));
    float clipW = clipPosition.w;
    if (abs(clipW) < mtoonEpsilon) {
        clipW = clipW < 0.0 ? -mtoonEpsilon : mtoonEpsilon;
    }
    float offsetClipW = offsetClipPosition.w;
    if (abs(offsetClipW) < mtoonEpsilon) {
        offsetClipW = offsetClipW < 0.0 ? -mtoonEpsilon : mtoonEpsilon;
    }
    float2 deltaNdc = offsetClipPosition.xy / offsetClipW - clipPosition.xy / clipW;
    // NDC x spans the viewport's width and y its height, so x is converted into
    // y's units: MToon measures the width against the screen height. Both
    // projections carry the aspect ratio as m[1][1] / m[0][0].
    float projectionX = viewToProjection[0][0];
    float projectionY = viewToProjection[1][1];
    if (abs(projectionX) > mtoonEpsilon) {
        deltaNdc.x *= abs(projectionY / projectionX);
    }
    float ndcPerViewUnit = length(deltaNdc);
    if (ndcPerViewUnit < mtoonEpsilon) {
        return 0.0;
    }
    // NDC spans 2 over the screen height, so a width of 1 is the whole height.
    return (width * 2.0) / ndcPerViewUnit;
}

// custom.value.w is the room the loader granted the pass outside the mesh's
// bounding box, in the mesh's own space. Staying inside it is what stops a wide
// outline -- a screen-coordinate one far from the camera above all -- from
// being culled along with the box it has left. 0 means no budget was written.
inline float mtoonBudgetedOutlineWidth(realitykit::geometry_parameters params, float width, float3 worldDirection)
{
    float budget = params.uniforms().custom_parameter().w;
    if (budget <= 0.0) {
        return width;
    }
    // The offset is a world distance and the budget a model-space one, so the
    // direction is measured back in model space to compare the two.
    float modelLength = metal::length((params.uniforms().world_to_model() * float4(worldDirection, 0.0)).xyz);
    if (modelLength < mtoonEpsilon) {
        return width;
    }
    return metal::min(width, budget / modelLength);
}

#endif
