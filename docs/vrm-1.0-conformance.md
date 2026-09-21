# VRM 1.0 Conformance Matrix

This file is the living evidence table for VRM 1.0 support in the package. Status values are intentionally explicit: `supported`, `partial`, `unsupported`, `not applicable`, or `tbd`.

## Legend

- `supported`: behavior is implemented and backed by an executable test or fixture.
- `partial`: behavior is partly implemented but missing validation, edge cases, or platform coverage.
- `unsupported`: the package intentionally does not claim support.
- `not applicable`: the feature is not relevant for this package or runtime.
- `tbd`: evidence is still pending.

## Feature Matrix

| Feature | Spec section | Current owner | Existing unit / fixture test | UniVRM comparison source | three-vrm comparison source | Status | Known approximation or limitation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| VRM 1.0 spec-version and required extension validation | `VRMC_vrm` root extension | VRMKit | `Tests/VRMKitTests/VRM1Tests.swift` (`testMalformedSpecVersionThrowsInsteadOfCrashing`, `testUnsupportedSpecVersionIsRejected`) | UniVRM rejects unsupported `specVersion` values | N/A | supported | Unsupported versions are rejected before runtime use; no renderer-specific approximation. |
| Core metadata and license fields | VRM 1.0 metadata | VRMKit | `Tests/VRMKitTests/VRM1Tests.swift` (`testMeta`) | UniVRM metadata validation | N/A | supported | The metadata surface is decoded as typed enums/strings and remains stable; license URLs are required. |
| Humanoid required bones | Humanoid definition | VRMKitRuntime | `Tests/VRMKitTests/HumanoidBoneTests.swift` (`testAVRM1RigMissingARequiredBoneIsRejected`) | UniVRM humanoid mapping | N/A | supported | Missing required bones fail fast with a typed error; no implicit recovery is attempted. |
| Humanoid optional bones | Humanoid definition | VRMKitRuntime | `Tests/VRMKitTests/HumanoidBoneTests.swift` (`testAnUnknownBoneNameIsIgnored`) | UniVRM optional-bone handling | N/A | supported | Unknown or extra bone names are ignored; missing optional bones remain non-fatal. |
| First-person mesh annotations | VRM first-person | VRMKit / VRMRealityKit | `Tests/VRMKitTests/VRM1Tests.swift` (`testFirstPerson`) | UniVRM first-person semantics | N/A | supported | Requires renderer integration to use the annotations, but the parser and metadata layer is validated. |
| Expressions: preset and custom | Expression specification | VRMKitRuntime | `Tests/VRMKitRuntimeTests/ExpressionTests.swift`; `Tests/VRMRealityKitTests/VRMExpressionTests.swift` | UniVRM expression binds | three-vrm expression output | supported | Preset mapping, custom names, and runtime accumulation are validated in the package tests. |
| Expression binds: morph, material color, texture transform | Expression binding spec | VRMKit | `Tests/VRMKitTests/VRM1Tests.swift`; `Tests/VRMRealityKitTests/VRMExpressionTests.swift` | UniVRM bind semantics | three-vrm output differential | supported | Material-color and texture-transform binds are tested in the runtime / renderer paths, with intent captured in the fixture metadata. |
| Expression binary and override semantics | Expression override rules | VRMKitRuntime | `Tests/VRMKitRuntimeTests/ExpressionTests.swift`; `Tests/VRMRealityKitTests/VRMExpressionTests.swift` | UniVRM expression override logic | three-vrm override groups | supported | Binary override semantics, suppression, and accumulation are validated with explicit regression tests. |
| Look-at bone and expression modes | Look-at spec | VRMKitRuntime | `Tests/VRMKitRuntimeTests/LookAtRigTests.swift`; `Tests/VRMRealityKitTests/VRMLookAtTests.swift` | UniVRM look-at ranges | three-vrm normalized gaze output | supported | Range maps, orientation conversion, and model-space target handling are validated for both bone and expression-driven gaze. |
| Node constraints: roll, aim, rotation | Node constraint spec | VRMKitRuntime | `Tests/VRMKitRuntimeTests/NodeConstraintOrderTests.swift`; `Tests/VRMKitTests/VRM1Tests.swift` (`testConstraintTwistSampleContainsRollAndAimConstraints`) | UniVRM constraint semantics | three-vrm constraint output | supported | Seed-san covers rotation constraints and ordering; the VRM specification twist sample adds parser evidence for roll and aim constraints. |
| Spring bones: joints, collider groups, center transforms | Spring bone spec | VRMKitRuntime | `Tests/VRMKitRuntimeTests/SpringBoneRigTests.swift`; `Tests/VRMKitRuntimeTests/SpringBoneRuntimeTests.swift` | UniVRM spring assembly | three-vrm spring output | supported | Chain solving, gravity, colliders, reset behavior, and invalid spring definitions are validated by runtime tests. |
| MToon materials and texture transforms | MToon material spec | VRMKit / VRMRealityKit | `Tests/VRMKitTests/GLTFMToonTests.swift`; `Tests/VRMRealityKitTests/MToonRenderingTests.swift` | UniVRM material conversion | three-vrm material conversions | supported | The material conversion and runtime parameter paths are covered by conversion and rendering tests; platform-specific approximations remain explicit. |
| VRMA humanoid retargeting | VRMA humanoid track spec | VRMKitRuntime | `Tests/VRMKitTests/VRMAnimationTests.swift`; `Tests/VRMRealityKitTests/VRMAnimationPlaybackTests.swift` | UniVRM retargeting | three-vrm VRMA output | supported | Hips retargeting, parent transforms, and runtime playback are covered by the existing VRMA tests. |
| VRMA expression and look-at tracks | VRMA expression / look-at spec | VRMKitRuntime | `Tests/VRMKitTests/VRMAnimationTests.swift`; `Tests/VRMRealityKitTests/VRMAnimationPlaybackTests.swift` | UniVRM animation tracks | three-vrm output comparison | supported | Expression ownership and look-at playback are validated in the runtime tests. |
| Runtime loading, cancellation, and resource lifetime | Loader lifecycle | VRMRealityKit / VRMKit | `Tests/VRMRealityKitTests/AsyncLoadingTests.swift`; `Tests/VRMRealityKitTests/GLTFEntityLoaderTests.swift` | UniVRM loader behavior | three-vrm asset lifecycle expectations | supported | Cancellation, reuse, queued load behavior, and malformed primitive failures are all exercised by the loader tests. |
| RealityKit rendering limitations and approximations | RealityKit platform support | VRMRealityKit | `Tests/VRMRealityKitTests/*.swift` | N/A | N/A | tbd | Keep renderer-specific limits explicit and non-claiming. |

## MToon 1.0 Property Matrix

The MToon row above is supported by the following property-level evidence. `supported` means the
property is decoded, converted into runtime shader parameters, and covered by a focused test;
`approximation` means the value is represented with a documented RealityKit limitation rather than
silently ignored.

| Property family | VRM 1.0 fields | Evidence | Status | Limitation |
| --- | --- | --- | --- | --- |
| Version and fallback | `specVersion`, `KHR_materials_unlit` | `MToonMaterialDescriptorTests.testUnsupportedMToonSpecVersionFallsBackToNonMToon`; `GLTFEntityLoaderTests` required-extension tests | supported | Unsupported MToon versions fall back unless the extension is required. |
| Base and shade | `shadeColorFactor`, `shadeMultiplyTexture`, `shadingShiftFactor`, `shadingShiftTexture`, `shadingToonyFactor` | `MToonMaterialDescriptorTests`; `MToonRenderingTests` parameter and texture tests | supported | Shading is implemented by the bundled RealityKit custom material. |
| GI and matcap | `giEqualizationFactor`, `matcapFactor`, `matcapTexture` | `MToonMaterialDescriptorTests.testVRM1EmissiveFieldsAndMatcapDefaultUseGltfMaterial`; `MToonRenderingTests` parameter tests | supported | Matcap follows the available RealityKit parameter path. |
| Rim | `parametricRimColorFactor`, `rimMultiplyTexture`, `rimLightingMixFactor`, `parametricRimFresnelPowerFactor`, `parametricRimLiftFactor` | `MToonMaterialDescriptorTests`; `MToonRenderingTests` rim/light parameter tests | supported | Runtime light direction/color are explicit controls. |
| Outline | `outlineWidthMode`, `outlineWidthFactor`, `outlineWidthMultiplyTexture`, `outlineColorFactor`, `outlineLightingMixFactor` | `GLTFMToonTests`; `MToonOutlineTests`; `MToonOutlineRenderingTests`; `MToonRenderingTests` | supported | Outline width is clamped to the culling margin; render-queue offsets are not material-level controls in RealityKit. |
| UV animation | `uvAnimationMaskTexture`, `uvAnimationScrollXSpeedFactor`, `uvAnimationScrollYSpeedFactor`, `uvAnimationRotationSpeedFactor` | `MToonMaterialDescriptorTests`; `MToonRenderingTests`; `TextureTransformRenderingTests` | supported | Texture transforms use the renderer's documented first-UV-accessed texture approximation. |
| Transparency and ordering | `transparentWithZWrite`, `renderQueueOffsetNumber` | `MToonRenderingTests`; `RenderQueueTests`; `MToonMaterialDescriptorTests` | approximation | `transparentWithZWrite` maps to depth writes; `renderQueueOffsetNumber` is ignored because RealityKit has no material-level draw-order hook. |
| Color and emission | `emissiveFactor`, base/shade/rim/outline colors, `emissiveTexture` | `MToonMaterialDescriptorTests`; `MToonRenderingTests`; `VRMExpressionTests` material-color binds | supported | Unity sRGB colors are converted to linear values; emission remains linear. |
| Texture metadata | MToon texture `index`, `texCoord`, `KHR_texture_transform`, shading-shift `scale` | `GLTFMToonTests`; `MToonMaterialDescriptorTests`; `TextureTransformRenderingTests` | approximation | RealityKit supports one effective UV transform per material; required unsupported combinations fail or VRM rendering uses the documented approximation. |
| Culling and normal response | glTF `doubleSided`, normal texture scale, normal texture binding | `MToonMaterialDescriptorTests`; `MToonRenderingTests`; `GLTFMeshAttributeTests` | supported | Tangents without authored `TANGENT` use the documented generated approximation. |

## Immediate follow-up

This scaffold is intended to turn into a closed evidence table by the end of Phase 1. Each row should be narrowed to one of the following actions before the row is considered `supported`:

1. A focused regression test or fixture.
2. Recorded comparison output from UniVRM and/or three-vrm.
3. A clear note documenting any deliberate approximation or platform limit.
4. A source owner and review trail for the behavior.

The first work stream should focus on the parser, metadata, and version-validation rows before moving to expression, look-at, and spring-bone parity.
