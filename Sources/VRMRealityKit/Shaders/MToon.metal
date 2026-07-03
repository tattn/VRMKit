#include <RealityKit/RealityKit.h>

using namespace metal;

constexpr sampler mtoonBaseSampler(coord::normalized,
                                   address::repeat,
                                   filter::linear,
                                   mip_filter::nearest);
constexpr sampler mtoonShadeSampler(coord::normalized,
                                    address::repeat,
                                    filter::linear,
                                    mip_filter::nearest);
constexpr sampler mtoonShadingShiftSampler(coord::normalized,
                                           address::repeat,
                                           filter::linear,
                                           mip_filter::nearest);
constexpr sampler mtoonNormalSampler(coord::normalized,
                                     address::repeat,
                                     filter::linear,
                                     mip_filter::nearest);
constexpr sampler mtoonMatcapSampler(coord::normalized,
                                     address::repeat,
                                     filter::linear,
                                     mip_filter::nearest);
constexpr sampler mtoonEmissiveSampler(coord::normalized,
                                       address::repeat,
                                       filter::linear,
                                       mip_filter::nearest);
constexpr sampler mtoonRimSampler(coord::normalized,
                                  address::repeat,
                                  filter::linear,
                                  mip_filter::nearest);
constexpr sampler mtoonOutlineWidthSampler(coord::normalized,
                                           address::repeat,
                                           filter::linear,
                                           mip_filter::nearest);
constexpr sampler mtoonUvAnimationMaskSampler(coord::normalized,
                                              address::repeat,
                                              filter::linear,
                                              mip_filter::nearest);
constexpr sampler mtoonParameterSampler(coord::normalized,
                                        address::clamp_to_edge,
                                        filter::nearest,
                                        mip_filter::none);

constant float mtoonEpsilon = 0.00001;
constant float mtoonParameterTextureWidth = 14.0;

half4 mtoonParameter(realitykit::texture::textures textures, float row)
{
    return textures.custom().sample(mtoonParameterSampler,
                                    float2((row + 0.5) / mtoonParameterTextureWidth, 0.5));
}

float mtoonLinearstep(float a, float b, float t)
{
    return saturate((t - a) / max(b - a, mtoonEpsilon));
}

float2 mtoonTextureUV(float2 uv)
{
    return float2(uv.x, 1.0 - uv.y);
}

float3 mtoonLightDirection(float4 customValue)
{
    float len = length(customValue.xyz);
    if (len < 0.001) {
        return normalize(float3(0.35, 0.55, 0.75));
    }
    return customValue.xyz / len;
}

float2 mtoonMatcapUV(float3 normal, float4x4 modelToView)
{
    float3 viewNormal = normalize((modelToView * float4(normal, 0.0)).xyz);
    return float2(viewNormal.x * 0.5 + 0.5, 0.5 - viewNormal.y * 0.5);
}

float3 mtoonShadingNormal(realitykit::surface_parameters params, float2 uv, half4 extraFlags)
{
    float3 geometryNormal = normalize(params.geometry().normal());
    if (extraFlags.x < 0.5h) {
        return geometryNormal;
    }
    half3 tangentNormal = realitykit::unpack_normal(params.textures().normal().sample(mtoonNormalSampler, uv).rgb, 1.0h);
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

float mtoonAlpha(float alphaMode, float baseAlpha, float cutoff)
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

[[visible]]
void mtoonSurface(realitykit::surface_parameters params)
{
    auto textures = params.textures();
    auto surface = params.surface();
    auto material = params.material_constants();
    float2 uv = mtoonTextureUV(params.geometry().uv0());

    half4 baseColorFactor = mtoonParameter(textures, 0.0);
    half4 shadeColorFactor = mtoonParameter(textures, 1.0);
    half4 rimColorFactor = mtoonParameter(textures, 2.0);
    half4 matcapFactor = mtoonParameter(textures, 3.0);
    half4 shadeParams = mtoonParameter(textures, 5.0);
    half4 rimParams = mtoonParameter(textures, 6.0);
    half4 uvAnimation = mtoonParameter(textures, 8.0);
    half4 featureFlags = mtoonParameter(textures, 9.0);
    half4 extraFlags = mtoonParameter(textures, 10.0);
    half4 emissiveFactor = mtoonParameter(textures, 11.0);
    half4 lightColorParameter = mtoonParameter(textures, 12.0);
    half4 giColorParameter = mtoonParameter(textures, 13.0);

    half4 baseSample = textures.base_color().sample(mtoonBaseSampler, uv);
    half4 shadeSample = textures.roughness().sample(mtoonShadeSampler, uv);

    float shift = float(shadeParams.x);
    if (featureFlags.z > 0.5h) {
        half shadingShift = textures.specular().sample(mtoonShadingShiftSampler, uv).r;
        shift += float(shadingShift) * float(uvAnimation.w);
    }

    float3 normal = mtoonShadingNormal(params, uv, extraFlags);
    float3 lightDirection = mtoonLightDirection(params.uniforms().custom_parameter());
    float shadingToony = clamp(float(shadeParams.y), 0.0, 1.0);
    float shading = mtoonLinearstep(-1.0 + shadingToony,
                                    1.0 - shadingToony,
                                    dot(normal, lightDirection) + shift);

    float3 litColor = float3(baseSample.rgb * baseColorFactor.rgb);
    float3 shadeColor = float3(shadeSample.rgb * shadeColorFactor.rgb);
    float3 lightColor = float3(lightColorParameter.rgb);
    float3 giColor = float3(giColorParameter.rgb);
    float giLuma = dot(giColor, float3(0.2126, 0.7152, 0.0722));
    // RealityKit does not expose UniVRM's full GI pipeline; approximate giEqualization by neutralizing ambient hue only.
    giColor = mix(giColor, float3(giLuma), clamp(float(shadeParams.z), 0.0, 1.0));

    float3 direct = mix(shadeColor, litColor, shading) * lightColor;
    float3 indirect = litColor * giColor;
    float3 color = direct + indirect;

    float3 rim = float3(0.0);
    if (featureFlags.x > 0.5h) {
        float2 matcapUV = mtoonMatcapUV(normal, params.uniforms().model_to_view());
        rim += float3(textures.metallic().sample(mtoonMatcapSampler, matcapUV).rgb * matcapFactor.rgb);
    }

    float3 viewDirection = normalize(params.geometry().view_direction());
    float rimBase = saturate(1.0 - dot(normal, viewDirection) + float(rimParams.y));
    float parametricRim = pow(rimBase, max(float(rimParams.x), mtoonEpsilon));
    rim += parametricRim * float3(rimColorFactor.rgb);

    if (featureFlags.y > 0.5h) {
        rim *= float3(textures.clearcoat_roughness().sample(mtoonRimSampler, uv).rgb);
    }
    rim *= mix(float3(1.0), direct + indirect, clamp(float(rimParams.z), 0.0, 1.0));
    color += rim;

    float3 emissiveTexture = extraFlags.z > 0.5h
        ? float3(textures.emissive_color().sample(mtoonEmissiveSampler, uv).rgb)
        : float3(1.0);
    color += float3(emissiveFactor.rgb) * emissiveTexture;

    float baseAlpha = float(baseSample.a * baseColorFactor.a);
    float cutoff = material.opacity_threshold() > 0.0 ? material.opacity_threshold() : float(shadeParams.w);
    float opacity = mtoonAlpha(float(extraFlags.w), baseAlpha, cutoff);

    surface.set_base_color(half3(0.0h));
    surface.set_emissive_color(half3(color));
    surface.set_opacity(half(opacity));
    surface.set_roughness(1.0h);
    surface.set_metallic(0.0h);
}

[[visible]]
void mtoonOutlineSurface(realitykit::surface_parameters params)
{
    auto textures = params.textures();
    auto surface = params.surface();
    auto material = params.material_constants();
    half4 outlineColor = mtoonParameter(textures, 4.0);
    half4 shadeParams = mtoonParameter(textures, 5.0);
    half4 outlineParams = mtoonParameter(textures, 7.0);
    half4 extraFlags = mtoonParameter(textures, 10.0);
    half4 lightColorParameter = mtoonParameter(textures, 12.0);

    float cutoff = material.opacity_threshold() > 0.0 ? material.opacity_threshold() : float(shadeParams.w);
    float opacity = mtoonAlpha(float(extraFlags.w), float(outlineColor.a), cutoff);
    // RealityKit does not expose the fully evaluated lit term here; use runtime light color as the lit approximation.
    float3 outlineLit = mix(float3(1.0), float3(lightColorParameter.rgb), clamp(float(outlineParams.z), 0.0, 1.0));
    float3 finalColor = float3(outlineColor.rgb) * outlineLit;

    surface.set_base_color(half3(0.0h));
    surface.set_emissive_color(half3(finalColor));
    surface.set_opacity(half(opacity));
    surface.set_roughness(1.0h);
    surface.set_metallic(0.0h);
}

float2 mtoonAnimatedUV(realitykit::geometry_parameters params,
                       float2 uv,
                       half4 uvAnimation,
                       half4 featureFlags)
{
    float time = params.uniforms().custom_parameter().w;
    float mask = 1.0;
    if (featureFlags.w > 0.5h) {
        float2 maskUV = mtoonTextureUV(uv);
        mask = float(params.textures().ambient_occlusion().sample(mtoonUvAnimationMaskSampler, maskUV).b);
    }

    float angle = float(uvAnimation.z) * time * mask;
    float2 center = float2(0.5, 0.5);
    float2 centered = uv - center;
    float s = sin(angle);
    float c = cos(angle);
    float2 rotated = float2(centered.x * c - centered.y * s,
                            centered.x * s + centered.y * c) + center;
    return rotated + float2(float(uvAnimation.x), float(uvAnimation.y)) * time * mask;
}

[[visible]]
void mtoonGeometry(realitykit::geometry_parameters params)
{
    float2 uv = params.uniforms().uv0_transform() * params.geometry().uv0()
              + params.uniforms().uv0_offset();
    half4 uvAnimation = mtoonParameter(params.textures(), 8.0);
    half4 featureFlags = mtoonParameter(params.textures(), 9.0);
    params.geometry().set_uv0(mtoonAnimatedUV(params, uv, uvAnimation, featureFlags));
}

float mtoonScreenOutlineWidth(realitykit::geometry_parameters params, float width, float3 modelNormal)
{
    float4x4 modelToView = params.uniforms().model_to_view();
    float4x4 viewToProjection = params.uniforms().view_to_projection();
    float4 viewPosition = modelToView * float4(params.geometry().model_position(), 1.0);
    float3 viewNormal = normalize((modelToView * float4(modelNormal, 0.0)).xyz);
    float4 clipPosition = viewToProjection * viewPosition;
    float4 offsetClipPosition = viewToProjection * (viewPosition + float4(viewNormal, 0.0));
    float clipW = clipPosition.w;
    if (abs(clipW) < mtoonEpsilon) {
        clipW = clipW < 0.0 ? -mtoonEpsilon : mtoonEpsilon;
    }
    float offsetClipW = offsetClipPosition.w;
    if (abs(offsetClipW) < mtoonEpsilon) {
        offsetClipW = offsetClipW < 0.0 ? -mtoonEpsilon : mtoonEpsilon;
    }
    float2 ndc = clipPosition.xy / clipW;
    float2 offsetNdc = offsetClipPosition.xy / offsetClipW;
    float ndcPerModelUnit = length(offsetNdc - ndc);
    if (ndcPerModelUnit < mtoonEpsilon) {
        return 0.0;
    }
    // geometry_parameters has projection matrices but no viewport height, so this treats width as a normalized screen-height fraction.
    return (width * 2.0) / ndcPerModelUnit;
}

[[visible]]
void mtoonOutlineGeometry(realitykit::geometry_parameters params)
{
    float2 uv = params.uniforms().uv0_transform() * params.geometry().uv0()
              + params.uniforms().uv0_offset();
    half4 uvAnimation = mtoonParameter(params.textures(), 8.0);
    half4 featureFlags = mtoonParameter(params.textures(), 9.0);
    uv = mtoonAnimatedUV(params, uv, uvAnimation, featureFlags);
    params.geometry().set_uv0(uv);

    half4 outlineParams = mtoonParameter(params.textures(), 7.0);
    if (outlineParams.w < 0.5h) {
        return;
    }

    float2 widthUV = mtoonTextureUV(uv);
    float widthMask = float(params.textures().clearcoat().sample(mtoonOutlineWidthSampler, widthUV).g);
    float width = max(0.0, float(outlineParams.x)) * widthMask;
    float3 modelNormal = normalize(params.geometry().normal());
    if (outlineParams.y > 1.5h) {
        width = mtoonScreenOutlineWidth(params, width, modelNormal);
    }
    params.geometry().set_model_position_offset(modelNormal * width);
}
