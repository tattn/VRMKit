#ifndef MTOON_REALITYKIT_H
#define MTOON_REALITYKIT_H

#include <RealityKit/RealityKit.h>

#include "MToonCore.h"
#include "MToonLayout.h"
#include "MToonSampling.h"

using namespace metal;

// The RealityKit adapter for the MToon specification math in MToonCore.h: how the
// material MToonShader binds (the layout in MToonLayout.h, the sampling in
// MToonSampling.h, and custom.value) reaches a RealityKit surface shader, and the
// helpers the entry points in MToon.metal are built from.
// Functions named realityKitApproximate* are approximations imposed by
// RealityKit's CustomMaterial constraints, not MToon semantics.
//
// A replacement entry point (MToonShaderFunctions) includes this header. Its
// functions are inline, so several source files of one library can include it.

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
    // RealityKit makes the tangent frame right-handed, turning the tangent over where the mesh's
    // frame is left-handed (mirrored UVs). The loader passes that hand in uv1.x to turn it back,
    // as glTF's tangent w does; a mesh without tangents reaches no further than the check above.
    float3 tangent = normalize(rawTangent) * (params.geometry().uv1().x < 0.0 ? -1.0 : 1.0);
    float3 bitangent = normalize(rawBitangent);
    return normalize(tangent * float(tangentNormal.x)
                   + bitangent * float(tangentNormal.y)
                   + geometryNormal * float(tangentNormal.z));
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

// How far the outline shell is pushed away from the camera (meters). Where the shell
// meets its body, as at the tips of double-sided hair, the body has to show; at equal
// depth the order RealityKit draws the two in would decide instead, and that order
// changes as entities are hidden and shown again.
constant float realityKitOutlineDepthPush = 0.0005;

// The world-space direction from the camera through the vertex. Moving a vertex
// along it changes only its depth, not where it lands on screen.
inline float3 realityKitAwayFromCamera(realitykit::geometry_parameters params)
{
    float4x4 modelToView = params.uniforms().model_to_view();
    float4 viewPosition = modelToView * float4(params.geometry().model_position(), 1.0);
    float4x4 worldToView = modelToView * params.uniforms().world_to_model();
    float3x3 viewRotation = float3x3(worldToView[0].xyz, worldToView[1].xyz, worldToView[2].xyz);
    return normalize(transpose(viewRotation) * viewPosition.xyz);
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
// bounding box, in the mesh's own space. Staying inside it stops a wide outline,
// above all a screen-coordinate one far from the camera, from being culled along
// with the box it has left. 0 means no budget was written.
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
