#include "MToonRealityKit.h"

template <bool Cutout>
inline void mtoonSurfaceImpl(realitykit::surface_parameters params)
{
    auto textures = params.textures();
    auto surface = params.surface();
    auto material = params.material_constants();

    half4 baseColorFactor = mtoonParameter(textures, mtoonRowBaseColor);
    half4 shadeColorFactor = mtoonParameter(textures, mtoonRowShadeColor);
    half4 rimColorFactor = mtoonParameter(textures, mtoonRowRimColor);
    half4 matcapFactor = mtoonParameter(textures, mtoonRowMatcapColor);
    half4 shadeParams = mtoonParameter(textures, mtoonRowShadeParams);
    half4 rimParams = mtoonParameter(textures, mtoonRowRimParams);
    half4 uvAnimation = mtoonParameter(textures, mtoonRowUvAnimation);
    half4 featureFlags = mtoonParameter(textures, mtoonRowFeatureFlags);
    half4 extraFlags = mtoonParameter(textures, mtoonRowExtraFlags);
    half4 emissiveFactor = mtoonParameter(textures, mtoonRowEmissiveFactor);
    half4 lightColorParameter = mtoonParameter(textures, mtoonRowLightColor);
    half4 giColorParameter = mtoonParameter(textures, mtoonRowAmbientColor);
    half4 uvTransform = mtoonParameter(textures, mtoonRowUvTransform);
    half4 uvTransformRotation = mtoonParameter(textures, mtoonRowUvTransformRotation);
    half4 normalParameters = mtoonParameter(textures, mtoonRowNormalParameters);
    half4 baseSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotBase);
    half4 shadeSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotShade);
    half4 shadingShiftSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotShadingShift);
    half4 normalSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotNormal);
    half4 matcapSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotMatcap);
    half4 emissiveSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotEmissive);
    half4 rimSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotRim);

    half4 uvAnimationMaskSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotUvAnimationMask);
    // UV animation time comes from RealityKit's per-frame uniforms; no CPU-side
    // material update is required to advance the animation.
    float2 uv = mtoonAnimatedUV(textures,
                                params.uniforms().time(),
                                mtoonTextureUV(params.geometry().uv0()),
                                uvAnimation,
                                featureFlags,
                                uvAnimationMaskSampler,
                                uvTransform,
                                uvTransformRotation);
    uv = mtoonTransformedUV(uv, uvTransform, uvTransformRotation);

    half4 baseSample = mtoonSample(textures.base_color(), uv, baseSampler);
    half4 shadeSample = extraFlags.y > 0.5h
        ? mtoonSample(textures.roughness(), uv, shadeSampler)
        : half4(1.0h);

    float shift = float(shadeParams.x);
    if (featureFlags.z > 0.5h) {
        half shadingShift = mtoonSample(textures.ambient_occlusion(), uv, shadingShiftSampler).r;
        shift += float(shadingShift) * float(uvAnimation.w);
    }

    float3 normal = mtoonShadingNormal(params, uv, extraFlags, normalParameters.x, normalSampler);
    float3 lightDirection = mtoonLightDirection(textures);
    float shadingToony = clamp(float(shadeParams.y), 0.0, 1.0);
    float shading = mtoonShading(normal, lightDirection, shift, shadingToony);

    float3 litColor = float3(baseSample.rgb * baseColorFactor.rgb);
    float3 shadeColor = float3(shadeSample.rgb * shadeColorFactor.rgb);
    float3 lightColor = float3(lightColorParameter.rgb);
    // MToon equalizes GI between the raw normal-direction sample and a
    // direction-independent one. GLTFEntity exposes a single uniform ambient
    // color, so both samples are that color and the equalization is the identity.
    float3 giColor = float3(giColorParameter.rgb);

    float3 direct = mtoonDirectLighting(litColor, shadeColor, shading, lightColor);
    float3 indirect = mtoonIndirectLighting(litColor, giColor);
    float3 color = direct + indirect;

    // Most MToon materials have no matcap and a black parametric rim color, which
    // makes the whole rim term zero, so skip it.
    if (featureFlags.x > 0.5h || any(rimColorFactor.rgb > 0.0h)) {
        float3 rim = float3(0.0);
        // `normal` and view_direction() are both world-space, which is what
        // lets the matcap, the parametric rim and the shading term share one
        // normal without any change of basis.
        float3 viewDirection = normalize(params.geometry().view_direction());
        if (featureFlags.x > 0.5h) {
            float2 matcapUV = mtoonTextureUV(mtoonMatcapUV(normal, viewDirection));
            rim += float3(mtoonSample(textures.metallic(), matcapUV, matcapSampler).rgb * matcapFactor.rgb);
        }

        if (any(rimColorFactor.rgb > 0.0h)) {
            float parametricRim = mtoonParametricRim(normal, viewDirection, float(rimParams.x), float(rimParams.y));
            rim += parametricRim * float3(rimColorFactor.rgb);
        }

        if (featureFlags.y > 0.5h) {
            rim *= float3(mtoonSample(textures.specular(), uv, rimSampler).rgb);
        }
        rim *= mtoonRimLighting(lightColor, giColor, float(rimParams.z));
        color += rim;
    }

    float3 emissiveTexture = extraFlags.z > 0.5h
        ? float3(mtoonSample(textures.emissive_color(), uv, emissiveSampler).rgb)
        : float3(1.0);
    color += float3(emissiveFactor.rgb) * emissiveTexture;

    float opacity = mtoonOpacity<Cutout>(material.opacity_threshold(), baseSample, baseColorFactor, extraFlags, shadeParams);

    surface.set_base_color(half3(0.0h));
    surface.set_emissive_color(half3(mtoonOutputColor(params.uniforms().custom_parameter(), color)));
    surface.set_opacity(half(opacity));
    surface.set_roughness(1.0h);
    surface.set_metallic(0.0h);
}

template <bool Cutout>
inline void mtoonOutlineSurfaceImpl(realitykit::surface_parameters params)
{
    auto textures = params.textures();
    auto surface = params.surface();
    auto material = params.material_constants();
    half4 outlineColor = mtoonParameter(textures, mtoonRowOutlineColor);
    half4 shadeParams = mtoonParameter(textures, mtoonRowShadeParams);
    half4 outlineParams = mtoonParameter(textures, mtoonRowOutlineParams);
    half4 uvAnimation = mtoonParameter(textures, mtoonRowUvAnimation);
    half4 featureFlags = mtoonParameter(textures, mtoonRowFeatureFlags);
    half4 extraFlags = mtoonParameter(textures, mtoonRowExtraFlags);
    half4 lightColorParameter = mtoonParameter(textures, mtoonRowLightColor);
    half4 uvTransform = mtoonParameter(textures, mtoonRowUvTransform);
    half4 uvTransformRotation = mtoonParameter(textures, mtoonRowUvTransformRotation);
    half4 baseSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotBase);
    half4 uvAnimationMaskSampler = mtoonSamplerParameter(textures, mtoonSamplerSlotUvAnimationMask);

    // Opaque outlines have opacity 1 regardless of the base texture, so the UV
    // chain and the base-color sample only run for MASK / BLEND materials.
    float opacity = 1.0;
    if (extraFlags.w > 0.5h) {
        float2 uv = mtoonAnimatedUV(textures,
                                    params.uniforms().time(),
                                    mtoonTextureUV(params.geometry().uv0()),
                                    uvAnimation,
                                    featureFlags,
                                    uvAnimationMaskSampler,
                                    uvTransform,
                                    uvTransformRotation);
        uv = mtoonTransformedUV(uv, uvTransform, uvTransformRotation);
        half4 baseSample = mtoonSample(textures.base_color(), uv, baseSampler);
        half4 baseColorFactor = mtoonParameter(textures, mtoonRowBaseColor);
        opacity = mtoonOpacity<Cutout>(material.opacity_threshold(), baseSample, baseColorFactor, extraFlags, shadeParams);
    }
    float3 outlineLit = realityKitApproximateOutlineLighting(float3(lightColorParameter.rgb), float(outlineParams.z));
    float3 finalColor = float3(outlineColor.rgb) * outlineLit;

    surface.set_base_color(half3(0.0h));
    surface.set_emissive_color(half3(mtoonOutputColor(params.uniforms().custom_parameter(), finalColor)));
    surface.set_opacity(half(opacity));
    surface.set_roughness(1.0h);
    surface.set_metallic(0.0h);
}

// The entry points MToonShader draws with unless MToonShaderFunctions replaces them.
// MASK materials draw with the cutout ones.

[[visible]]
void mtoonSurface(realitykit::surface_parameters params)
{
    mtoonSurfaceImpl<false>(params);
}

[[visible]]
void mtoonCutoutSurface(realitykit::surface_parameters params)
{
    mtoonSurfaceImpl<true>(params);
}

[[visible]]
void mtoonOutlineSurface(realitykit::surface_parameters params)
{
    mtoonOutlineSurfaceImpl<false>(params);
}

[[visible]]
void mtoonCutoutOutlineSurface(realitykit::surface_parameters params)
{
    mtoonOutlineSurfaceImpl<true>(params);
}

[[visible]]
void mtoonOutlineGeometry(realitykit::geometry_parameters params)
{
    half4 outlineParams = mtoonParameter(params.textures(), mtoonRowOutlineParams);
    // outlineWidthMode "none" draws no outline whatever width the material
    // carries, so a pass built for it stays empty even when shown.
    if (outlineParams.y < 0.5h) {
        return;
    }

    // Without an outlineWidthMultiplyTexture the mask is a 1x1 white fallback,
    // so skip the UV work and the fetch entirely.
    float widthMask = 1.0;
    if (outlineParams.w > 0.5h) {
        half4 uvTransform = mtoonParameter(params.textures(), mtoonRowUvTransform);
        half4 uvTransformRotation = mtoonParameter(params.textures(), mtoonRowUvTransformRotation);
        half4 uvAnimation = mtoonParameter(params.textures(), mtoonRowUvAnimation);
        half4 featureFlags = mtoonParameter(params.textures(), mtoonRowFeatureFlags);
        half4 uvAnimationMaskSampler = mtoonSamplerParameter(params.textures(), mtoonSamplerSlotUvAnimationMask);
        // Computed locally for the width mask only: mtoonOutlineSurface applies
        // the UV animation and transform itself, so writing the transformed UV
        // back to uv0 would apply it twice.
        float2 widthUV = mtoonVertexAnimatedUV(params.textures(),
                                               params.uniforms().time(),
                                               mtoonTextureUV(params.geometry().uv0()),
                                               uvAnimation,
                                               featureFlags,
                                               uvAnimationMaskSampler,
                                               uvTransform,
                                               uvTransformRotation);
        widthUV = mtoonTransformedUV(widthUV, uvTransform, uvTransformRotation);

        half4 outlineWidthSampler = mtoonSamplerParameter(params.textures(), mtoonSamplerSlotOutlineWidth);
        widthMask = float(mtoonVertexSample(params.textures().ambient_occlusion(), widthUV, outlineWidthSampler).g);
    }
    float width = max(0.0, float(outlineParams.x)) * widthMask;
    // Offset in world space either way: MToon's widths are meters or a fraction
    // of the screen, and a model-space offset would also scale both by the entity's
    // scale, which may be non-uniform.
    float3 worldNormal = params.uniforms().normal_to_world() * normalize(params.geometry().normal());
    float worldNormalLength = length(worldNormal);
    if (worldNormalLength < mtoonEpsilon) {
        return;
    }
    float3 worldDirection = worldNormal / worldNormalLength;
    if (outlineParams.y > 1.5h) {
        width = realityKitApproximateScreenOutlineWidth(params, width, worldDirection);
    }
    params.geometry().set_world_position_offset(worldDirection * mtoonBudgetedOutlineWidth(params, width, worldDirection));
}
