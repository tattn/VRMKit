#ifndef MTOON_LAYOUT_H
#define MTOON_LAYOUT_H

#include <metal_stdlib>

// The material layout MToonShader binds, free of RealityKit: where each value sits in the
// parameter rows, which sampler row each texture slot reads, and what the rows say about
// the alpha. A function drawing an MToon material outside RealityKit reads the same rows.

// The layout revision, MToonShader.parameterLayoutVersion on the Swift side. It moves with any row.
constant int mtoonParameterLayoutVersion = 1;

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

// Only the cutout entry points discard. A function that may discard keeps the GPU
// from rejecting hidden fragments before shading them, which costs about a quarter
// of the frame on Apple GPUs for every opaque material drawn with it.
template <bool Cutout>
inline float mtoonAlpha(float alphaMode, float baseAlpha, float cutoff)
{
    if (alphaMode > 1.5) {
        return baseAlpha;
    }
    if (Cutout && alphaMode > 0.5 && baseAlpha < cutoff) {
        metal::discard_fragment();
    }
    return 1.0;
}

// Shared by the material's and the outline's surface entry points.
template <bool Cutout>
inline float mtoonOpacity(float opacityThreshold,
                   half4 baseSample,
                   half4 baseColorFactor,
                   half4 extraFlags,
                   half4 shadeParams)
{
    const float cutoff = opacityThreshold > 0.0 ? opacityThreshold : float(shadeParams.w);
    return mtoonAlpha<Cutout>(float(extraFlags.w), float(baseSample.a * baseColorFactor.a), cutoff);
}

#endif
