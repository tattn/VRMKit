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

inline float3 mtoonDirectLighting(float3 litColor, float3 shadeColor, float shading, float3 lightColor)
{
    return metal::mix(shadeColor, litColor, shading) * lightColor;
}

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

// A rim light from a direction, not part of the specification. The shape follows
// the backlight of anime-style shaders rather than a Fresnel gradient:
//   - the light is bent away from the viewer (shape.w) so a backlight lines the
//     near edges of the silhouette too, not only the surfaces facing it;
//   - a half-Lambert with a wrap range (shape.z) carries the band around the
//     shadowed side instead of cutting it off at the terminator;
//   - the Fresnel edge times that facing is cut into a band of set width (shape.x)
//     with a soft inner edge (shape.y).
// shape = (width, softness, wrap, viewBend), all in 0...1.
//
// A back face of a double-sided material carries a normal pointing away from the
// viewer, which would read as the sharpest edge there is; it is flipped to face
// the viewer so that only real silhouettes light up.
inline float mtoonRimLightTerm(float3 normal, float3 viewDirection, float3 lightDirection, float4 shape)
{
    if (metal::dot(normal, viewDirection) < 0.0) {
        normal = -normal;
    }
    const float3 bentLight = metal::normalize(lightDirection - viewDirection * shape.w);
    const float halfLambert = metal::dot(normal, bentLight) * 0.5 + 0.5;
    const float facing = metal::saturate((halfLambert + shape.z) / (1.0 + shape.z));
    const float edge = 1.0 - metal::saturate(metal::dot(normal, viewDirection));
    const float band = edge * facing;
    const float border = 1.0 - shape.x;
    return mtoonLinearstep(border - shape.y * 0.5, border + shape.y * 0.5, band);
}

#endif
