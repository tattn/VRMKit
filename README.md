<h1 align="center">VRMKit</h1>

<h5 align="center">VRM loader and VRM renderer</h5>

<div align="center">
  <a href="https://github.com/tattn/VRMKit/actions/workflows/ci.yml">
    <img src="https://github.com/tattn/VRMKit/actions/workflows/ci.yml/badge.svg" />
  </a>
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green.svg?style=flat-square" alt="license:MIT" />
  </a>
</div>

<br />

https://github.com/user-attachments/assets/5bf25ec5-29e7-4e74-a270-0012aac7a56a

For "VRM", please refer to [vrm.dev](https://vrm.dev/en/).

# Features

- [x] Load VRM file
- [x] Render VRM models on RealityKit (experimental)
- [x] Face morphing (blend shape)
- [x] Bone animation (skin / joint)
- [x] Physics (spring bone)
- [x] Look at (eye bone / expression)
- [x] MToon rendering and custom material shaders
- [x] Render plain glTF / GLB with animations
- [x] VRM animation (.vrma) retargeting
- [x] Edit and save glTF / VRM as GLB

# Requirements

- Swift 6.0+
- VRMKit: iOS 15.0+ / macOS 12.0+ / visionOS 2.0+ / watchOS 8.0+
- VRMRealityKit: iOS 18.0+ / macOS 15.0+ / visionOS 2.0+

# Installation

## Swift Package Manager

```swift
.package(url: "https://github.com/tattn/VRMKit.git", from: "0.11.0")
```

For SceneKit rendering, use [0.10.0](https://github.com/tattn/VRMKit/releases/tag/0.10.0).

# Usage

## Load VRM

```swift
import VRMKit

let vrm = try VRM(named: "model.vrm")
// let vrm = try VRM(withURL: URL(fileURLWithPath: "/path/to/model.vrm"))
// let vrm = try VRM(data: data)

// VRM meta data
vrm.name
try vrm.thumbnail
vrm.document.gltf.nodes[0].name

// bones are named as VRM 1.0 names them, whichever version the model is
vrm.nodeIndex(of: .leftThumbMetacarpal)

// the rest of the metadata is version specific
switch vrm {
case .v0(let vrm0): vrm0.meta.author
case .v1(let vrm1): vrm1.meta.authors
}
```

## Render VRM

```swift
import RealityKit
import SwiftUI
import VRMRealityKit

struct ContentView: View {
    var body: some View {
        RealityView { content in
            guard let model = try? await VRMEntityLoader(named: "model.vrm").loadEntity() else { return }
            content.add(model)
        }
    }
}
```

`loadEntity()` returns a `VRMEntity`, which drives expressions, humanoid bones, spring bones and animation.

Skinning, constraints and spring bones update every frame automatically; set `isAutomaticUpdateEnabled = false` and call `update(deltaTime:)` to drive the timing yourself. The spring bones step at a fixed rate, so the swing is the same at every display refresh rate.

```swift
model.springBoneConfiguration.externalForce = SIMD3<Float>(1, 0, 0) // wind
model.resetSpringBones() // after teleporting the model
```

## Expressions / blend shapes

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_joy.png" width="100px" alt="joy" /><img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_angry.png" width="100px" alt="angry" /><img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_><.png" width="100px" alt="><" />

```swift
model.setExpression(value: 1.0, for: .preset(.happy))
model.setExpressions([.preset(.blink): 1.0, .custom("><"): 0.5])

for expression in model.availableExpressions {
    print(expression.key, expression.name) // preset(.happy) Joy
}
```

VRM 0.x and 1.0 share this API. A 0.x model's blend shape groups load as the expressions they stand for, so `joy` is set as `.happy`; `ExpressionPreset.vrm0PresetName` spells it back the 0.x way. `setExpressions` applies several weights at once, which suits per-frame face tracking.

## Look at

```swift
model.lookAtTarget = .position(SIMD3<Float>(0, 1.4, 1)) // a point in world space
model.lookAtTarget = .angles(yaw: 15, pitch: -5)        // degrees from the head's forward
model.lookAtTarget = nil                                // back to rest
```

The eyes stay on the target as either it or the model moves. VRM 0.x and 1.0 share this API, and the model itself states whether the gaze turns its eye bones or weighs its look expressions.

## Bone animation

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_humanoid.png" width="200px" alt="Humanoid" />

```swift
let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
model.humanoid.node(for: .neck)?.transform.rotation *= neckRotation
model.invalidateSkinPose()
```

`invalidateSkinPose()` tells the runtime that a bone moved. Animation, constraints and spring bones do this themselves.

## VRM animation (.vrma)

A `.vrma` file retargets onto any loaded model, VRM 1.0 and 0.x alike: humanoid bone rotations, the hips motion scaled to the model's size, expression tracks, and the gaze, which lands on `lookAtTarget`. An optional bone the model lacks, such as `upperChest`, hands its rotation to the bones that stand in for it.

```swift
let animation = try VRMAnimation(named: "walk.vrma")
let controller = try model.playAnimation(animation, loops: true)
controller.speed = 2        // a negative speed plays backwards
controller.isPaused = true  // holds the pose
controller.seek(to: 0.5)
controller.stop()
```

## MToon rendering

<details>
<summary>Details</summary>

MToon materials render by default on iOS and macOS. visionOS falls back to Unlit / PBR materials, because RealityKit's `CustomMaterial` is unavailable there.

```swift
model.setMToonLightDirection(SIMD3<Float>(0, 0, -1))
model.setMToonLightColor(SIMD3<Float>(1, 1, 1))
model.setMToonAmbientColor(SIMD3<Float>(0.1, 0.1, 0.1))
```

Both loaders take a material shader chain. Each shader is asked in order, and materials no shader claims render through the built-in Unlit / PBR path.

```swift
// The default chain is [MToonShader()]: MToon with authored outlines.
let noOutlines = try VRMEntityLoader(named: "model.vrm", shaders: [MToonShader(outlinePass: .never)])
let noMToon = try VRMEntityLoader(named: "model.vrm", shaders: [])

// Toon-shade a plain glTF, or a VRM whose materials are not MToon.
// Pass .convertAll(MToonConversionStyle(...)) to tune the conversion.
let converted = try GLTFEntityLoader(withURL: url, shaders: [MToonShader(source: .convertAll)])

// Your own shader joins the same chain.
final class MyShader: GLTFMaterialShader {
    func makeMaterial(for context: GLTFMaterialShaderContext) throws -> GLTFShadedMaterial? {
        // Return nil to pass the material on to the next shader / built-in path,
        // or start from try context.standardMaterial() to adjust the standard result.
        var material = UnlitMaterial()
        if let texture = context.material.pbrMetallicRoughness?.baseColorTexture {
            material.color = .init(texture: try context.materialTexture(withTextureIndex: texture.index))
        }
        return GLTFShadedMaterial(material: material)
    }
}

let custom = try VRMEntityLoader(withData: data, shaders: [MyShader(), MToonShader()])
```

`GLTFShadedMaterial` also carries extra render passes, MToon's outline being one, and a `makeAnimatableState` closure that lets VRM expressions animate a custom material. A shader's own runtime controls live on that state type, edited with `updateMaterialStates(_:)`.

```swift
entity.updateMaterialStates(GlowState.self) { state in
    guard state.glow != 1 else { return false } // unchanged: nothing is pushed
    state.glow = 1
    return true
}
```

MToon can also be drawn by Metal functions of your own, built against `Sources/VRMRealityKit/Shaders/MToonRealityKit.h` from the revision you depend on. Each MToon material carries a few user rows for the values they add.

```swift
let library = try device.makeDefaultLibrary(bundle: .main)
let shader = MToonShader(functions: MToonShaderFunctions(surface: .init(named: "myToonSurface", in: library)))

// Read in the shader as mtoonUserParameter(textures, 0).
entity.updateMaterialStates(MToonAnimatableMaterialState.self) { $0.setUserParameter(glow, at: 0) }
```

A blended material also carries a `renderQueue`, the Unity-scale draw order that VRM 0.x's `renderQueue` and MToon's `renderQueueOffsetNumber` express, and `context.renderQueue(alphaMode:transparentWithZWrite:offset:)` derives it. Within one mesh, blended materials at different queues draw in queue order rather than by distance.

A pass can be built hidden and shown later with `setPassEnabled`, for the whole model or for the materials under a node. `resetPassEnabled` puts back what the shader built.

```swift
let selection = entity.materialIndices(under: selectedNode)
entity.setPassEnabled(true, named: "highlight", forMaterials: selection)
entity.resetPassEnabled(named: "highlight", forMaterials: selection)
```

A pass whose geometry modifier moves vertices outside the mesh's bounds sets `applyBoundsBudget` to receive the room the loader widened the culling bounds by.

</details>

## Render glTF / GLB

<details>
<summary>Details</summary>

VRMRealityKit also renders plain glTF assets: `.glb` and JSON `.gltf`, external resources and data URIs included.

```swift
let entity: GLTFEntity = try await GLTFEntityLoader(withURL: url).loadEntity()

entity.animations  // [GLTFAnimation]: index, name, duration
let controller = try entity.playAnimation(at: 0, loops: true)  // same controller as above
```

`loadEntity()` renders the asset's default scene and throws when the glTF names none; pick one with `loadEntity(withSceneIndex:)`.

A `clone(recursive:)` copy shares the loaded meshes and materials but not the animation bindings, so load the scene again for a second animatable instance. `cloneWithOwnMaterialParameters()` instead gives the copy meshes and material parameters of its own, frozen in the original's current pose, so it can be lit or recolored by itself.

`setMaterialColor(_:for:ofMaterial:)` recolors one material at runtime, the way a VRM expression's material color bind does, so a plain glTF can take a color the user picks:

```swift
if let glow = entity.gltf.materials.firstIndex(where: { $0.name == "Glow" }) {
    entity.setMaterialColor(SIMD4<Float>(1, 0.2, 0.6, 1), for: .emissionColor, ofMaterial: glow)
}
```

Skinning and morphing run in a compute kernel, and only when a pose or weight changed. The rest-pose vertex data behind a model entity is readable through `gltfMeshGeometry`.

<details>
<summary>Renderer limitations</summary>

RealityKit meshes and materials cannot express every part of glTF and MToon. Each case below logs a warning once per affected material.

- Only triangle primitives are drawn; `POINTS` and `LINES` primitives are skipped.
- `COLOR_0` vertex colors are ignored: the mesh buffers this renderer builds carry no vertex-color channel.
- One UV set and one `KHR_texture_transform` per material: the first UV-accessed texture decides both. A glTF load requiring more is rejected rather than drawn wrong; a VRM load renders the approximation.
- Tangents for a primitive without `TANGENT` are averaged from its UV gradients, not generated with MikkTSpace, so a normal map baked against MikkTSpace can differ along UV seams.
- Blend shapes morph `POSITION` only; a target's `NORMAL` / `TANGENT` deltas are not read.
- Skinning reads `JOINTS_0` / `WEIGHTS_0` only, so a vertex is driven by at most four joints.
- MToon's outline is clamped to a culling margin of the mesh's radius, so an outline asking for more caps out there.
- MToon's outline takes its lit color from the runtime light color, not from the surface's fully evaluated shading, which RealityKit does not expose to a `CustomMaterial`.
- RealityKit sees only the rest-pose bounds of skinned and morphed meshes, so on iOS 27 and later they opt out of its occlusion culling.

</details>

</details>

## Edit and save glTF / VRM

<details>
<summary>Details</summary>

`GLTFEditableDocument` edits an asset's glTF JSON and writes it back out as a GLB. Fields VRMKit does not model are carried over untouched, and nothing already in the document changes index. It is a value, so a copy taken before an edit is the document as it was. A VRM edit is refused on a document that does not say it is VRM 1.0 or VRM 0.x outright.

```swift
let vrm = try VRM(data: data)
var document = try GLTFEditableDocument(data: data)
if let hand = vrm.nodeIndex(of: .leftHand) {
    let item = try GLTFDocument(withURL: itemURL)
    try document.append(item, under: GLTFNodeIndex(hand), name: "item", materials: .mtoon)
}
try document.serialize().write(to: outputURL)
```

Indices are typed: `GLTFNodeIndex`, `GLTFMeshIndex`, `GLTFMaterialIndex` and `GLTFSceneIndex` keep one kind of index from reaching an edit that wants another.

`append` copies a whole source document to the end of the arrays it belongs in and embeds its external resources into the GLB buffer. The source's default scene decides which of the copied nodes are drawn, or the one `append(_:sceneAt:under:)` names. A source it cannot rebase, such as one declaring an unknown extension or a VRM 0.x model, is refused rather than written out broken.

`materials: .mtoon` writes the copied materials as MToon. A material that already carries MToon is kept as it is, and one that carries none converts through the same `MToonConversionStyle` as `MToonShader(source: .convertAll)`. `convertMaterialsToMToon(at:style:)` does the same to materials already in the document.

`addNode`, `setName` and `setTransform` edit the node graph by appending, never by renumbering, so the VRM extensions keep pointing at what they used to. `detachNode` cuts a subtree's links to its parent and scenes, and `moveNode(at:to:)` hangs it under another node instead, or under the default scene's roots when given none.

`prune()` drops what a detached subtree left behind and remaps the remaining indices. A node something still references keeps its transform but loses what it drew, so a humanoid bone or a spring joint stays where it was. It returns the BIN bytes it reclaimed and where every entry it kept ended up:

```swift
let node = try document.addNode(name: "item")
let result = try document.prune()
let stillThere = result.newIndex(of: node)   // nil for a node the prune dropped
```

`setVRMThumbnail`, `setVRMName` and `setVRMAuthors` rewrite the model's own metadata in whichever form the document keeps, leaving every other field alone, and refuse what that version would not validate: VRM 1.0 asks for a square thumbnail, a name and at least one author. The license fields are the distributor's to set, so they are not writable.

`addVRM1SpringBone` and `addVRM0SpringBone` give merged content its motion. A `VRM1Spring` lists the joints a spring runs down, each below the one before it and each with its own parameters, while a `VRM0SpringBoneGroup` names the nodes a swing starts at and swings everything below them. A spring is checked against what `VRMC_springBone` says one is. Colliders are not authored here.

A merged animation needs no writing: `append` rebases the source's animations, and `VRMEntity` plays them through the same `animations` and `playAnimation(at:)` any glTF scene has.

A `.vrma` is written the same way: `addRestSkeleton(of:)` copies a model's humanoid as the clip's skeleton, `addAnimation(name:tracks:)` adds keyframes, and `setVRMAnimationHumanoid` and `setVRMAnimationExpressions` declare them as `VRMC_vrm_animation`.

```swift
var document = GLTFEditableDocument()
let skeleton = try document.addRestSkeleton(of: vrm)
try document.setVRMAnimationHumanoid(skeleton.bones)
try document.addAnimation(name: "wave", tracks: [
    GLTFAnimationTrack(node: skeleton.bones[.rightUpperArm]!, times: [0, 1], values: .rotation([rest, raised])),
])
let vrma = try document.serialize()
```

`GLTFEditableDocument()` starts an empty document and `addMesh` fills it from vertex data, so a plate, a prop or a test fixture can be built without laying out accessors, buffer views and the GLB container by hand. A mesh given no normals is flat shaded.

```swift
var document = GLTFEditableDocument()
let plate = GLTFTriangleMesh(positions: positions,
                             textureCoordinates: uvs,
                             indices: [0, 1, 2, 0, 2, 3],
                             material: GLTFSimpleMaterial(
                                 baseColorImage: pngData,
                                 baseColorSampler: GLTFTextureSampler(wrapS: .CLAMP_TO_EDGE,
                                                                      wrapT: .CLAMP_TO_EDGE),
                                 isUnlit: true))
try document.addMesh(plate, name: "signboard")
try document.serialize().write(to: outputURL)
```

The scope is one indexed triangle mesh and one material: positions, optional normals and texture coordinates, a base color factor and a PNG or JPEG image with its wrap and filter modes, unlit, alpha mode and double-sidedness. `addMesh` returns the node it added and takes the same `materials: .mtoon` as `append`.

</details>

# Contributing

Pull requests are welcome. Please read [CONTRIBUTING.md](./CONTRIBUTING.md) first: open an issue to discuss anything larger than a bug fix, and keep each pull request to a single purpose.

# Support this project

Donations help me keep working on this project.

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://paypal.me/tattn/)

# License

VRMKit is released under the MIT license. See LICENSE for details.

# Author

Tatsuya Tanaka

<a href="https://x.com/tattn_dev" target="_blank"><img alt="Twitter" src="https://img.shields.io/twitter/follow/tattn_dev.svg?style=social&label=Follow"></a>
<a href="https://github.com/tattn" target="_blank"><img alt="GitHub" src="https://img.shields.io/github/followers/tattn.svg?style=social"></a>
