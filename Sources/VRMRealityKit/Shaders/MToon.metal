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

constant float mtoonParameterTextureWidth = 11.0;

half4 mtoonParameter(realitykit::texture::textures textures, float row)
{
    return textures.custom().sample(mtoonParameterSampler,
                                    float2((row + 0.5) / mtoonParameterTextureWidth, 0.5));
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

float mtoonShadeValue(float lambert, float shift, float toony, float giEqualization)
{
    float clampedToony = clamp(toony, 0.001, 0.999);
    float shade = smoothstep(shift, shift + max(0.001, 1.0 - clampedToony), lambert);
    return mix(shade, 1.0, clamp(1.0 - giEqualization, 0.0, 1.0));
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

    half4 baseSample = textures.base_color().sample(mtoonBaseSampler, uv);
    half4 shadeSample = textures.roughness().sample(mtoonShadeSampler, uv);

    float shift = float(shadeParams.x);
    if (featureFlags.z > 0.5h) {
        half shadingShift = textures.specular().sample(mtoonShadingShiftSampler, uv).r;
        shift += (float(shadingShift) * 2.0 - 1.0) * float(uvAnimation.w);
    }

    float3 normal = mtoonShadingNormal(params, uv, extraFlags);
    float3 lightDirection = mtoonLightDirection(params.uniforms().custom_parameter());
    float lambert = dot(normal, lightDirection) * 0.5 + 0.5;
    float shade = mtoonShadeValue(lambert,
                                  clamp(shift, -1.0, 1.0),
                                  float(shadeParams.y),
                                  float(shadeParams.z));

    half3 base = baseSample.rgb * baseColorFactor.rgb;
    half3 shaded = shadeSample.rgb * shadeColorFactor.rgb;
    half3 color = mix(shaded, base, half(shade));

    float rimBase = 1.0 - abs(dot(normal, normalize(params.geometry().view_direction())));
    float rim = pow(clamp(rimBase + float(rimParams.y), 0.0, 1.0),
                    max(float(rimParams.x), 0.001));
    half3 rimTexture = featureFlags.y > 0.5h
        ? textures.emissive_color().sample(mtoonRimSampler, uv).rgb
        : half3(1.0h);
    half3 rimColor = rimColorFactor.rgb * rimTexture * half(rim) * half(rimParams.z);

    half3 matcapColor = half3(0.0h);
    if (featureFlags.x > 0.5h) {
        float2 matcapUV = mtoonMatcapUV(normal, params.uniforms().model_to_view());
        matcapColor = textures.metallic().sample(mtoonMatcapSampler, matcapUV).rgb * matcapFactor.rgb;
    }

    half opacity = baseSample.a * baseColorFactor.a;
    float opacityThreshold = material.opacity_threshold();
    if (opacityThreshold > 0.0 && float(opacity) < opacityThreshold) {
        discard_fragment();
    }

    half3 finalColor = color + rimColor + matcapColor;
    surface.set_base_color(half3(0.0h));
    surface.set_emissive_color(finalColor);
    surface.set_opacity(opacity);
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
    half opacity = outlineColor.a;
    float opacityThreshold = material.opacity_threshold();
    if (opacityThreshold > 0.0 && float(opacity) < opacityThreshold) {
        discard_fragment();
    }
    surface.set_base_color(half3(0.0h));
    surface.set_emissive_color(outlineColor.rgb);
    surface.set_opacity(opacity);
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
    if (outlineParams.y > 1.5h) {
        float4 viewPosition = params.uniforms().model_to_view() * float4(params.geometry().model_position(), 1.0);
        width *= max(0.001, -viewPosition.z) * 0.002;
    }
    params.geometry().set_model_position_offset(normalize(params.geometry().normal()) * width);
}
