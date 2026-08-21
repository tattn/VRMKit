#ifndef MTOON_CORE_H
#define MTOON_CORE_H

// Pure VRMC_materials_mtoon 1.0 math. This header must stay free of
// RealityKit types so that the MToon specification layer can be read and
// verified independently of RealityKit-specific approximations, which live
// in MToon.metal as realityKitApproximate* functions.

#include <metal_stdlib>

constant float mtoonEpsilon = 0.00001;

inline float mtoonLinearstep(float minValue, float maxValue, float value)
{
    return metal::saturate((value - minValue) / metal::max(maxValue - minValue, mtoonEpsilon));
}

// https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_materials_mtoon-1.0#shading-shift
inline float mtoonShading(float3 normal, float3 lightDirection, float shadingShift, float shadingToony)
{
    return mtoonLinearstep(-1.0 + shadingToony,
                           1.0 - shadingToony,
                           metal::dot(normal, lightDirection) + shadingShift);
}

// Direct lighting: base and shade colors are mixed by the shading value and
// modulated by the light color.
inline float3 mtoonDirectLighting(float3 litColor, float3 shadeColor, float shading, float3 lightColor)
{
    return metal::mix(shadeColor, litColor, shading) * lightColor;
}

// Global illumination: the lit color is modulated by the (equalized) GI color.
inline float3 mtoonIndirectLighting(float3 litColor, float3 giColor)
{
    return litColor * giColor;
}

// Matcap UV, in the specification's UV convention (v pointing up).
//
// The basis is built from the view direction rather than from a view matrix, so
// `normal` and `viewDirection` only have to agree with each other. Both are
// world-space here, the same space the rim and shading terms use.
// https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_materials_mtoon-1.0#matcap
inline metal::float2 mtoonMatcapUV(float3 normal, float3 viewDirection)
{
    float3 worldViewX = float3(viewDirection.z, 0.0, -viewDirection.x);
    const float horizontalLength = metal::length(worldViewX);
    if (horizontalLength < mtoonEpsilon) {
        // Looking straight along world up or down leaves no horizontal axis to
        // build the basis from; the matcap centre is the stable choice.
        return metal::float2(0.5, 0.5);
    }
    worldViewX /= horizontalLength;
    const float3 worldViewY = metal::cross(viewDirection, worldViewX);
    return metal::float2(metal::dot(worldViewX, normal),
                         metal::dot(worldViewY, normal)) * 0.495 + 0.5;
}

// Parametric rim term before the rim-multiply texture and lighting mix.
inline float mtoonParametricRim(float3 normal, float3 viewDirection, float rimFresnelPower, float rimLift)
{
    const float rimBase = metal::saturate(1.0 - metal::dot(normal, viewDirection) + rimLift);
    return metal::pow(rimBase, metal::max(rimFresnelPower, mtoonEpsilon));
}

#endif
