<h1 align="center">VRMKit</h1>

<h5 align="center">VRM loader and VRM renderer</h5>

<div align="center">
  <a href="https://app.bitrise.io/app/efaa4b22f111455d">
    <img src="https://github.com/tattn/VRMKit/actions/workflows/ci.yml/badge.svg" />
  </a>
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-green.svg?style=flat-square" alt="license:MIT" />
  </a>
</div>

<br />

https://github.com/user-attachments/assets/5bf25ec5-29e7-4e74-a270-0012aac7a56a

For "VRM", please refer to [this page](https://dwango.github.io/en/vrm/).

## Features

- [x] Load VRM file
- [x] Render VRM models on RealityKit (experimental)
- [x] Face morphing (blend shape)
- [x] Bone animation (skin / joint)
- [x] Physics (spring bone)
- [x] MToon rendering and custom material shaders
- [x] Render plain glTF / GLB with animations
- [x] VRM animation (.vrma) retargeting
- [x] Edit and save glTF / VRM as GLB

# Requirements

- Swift 6.0+
- iOS 15.0+ / macOS 12.0+ / visionOS 2.0+ / watchOS 8.0+ (experimental)
- VRMRealityKit: iOS 18.0+ / macOS 15.0+ / visionOS 2.0+

# Installation

## Swift Package Manager

You can install this package with Swift Package Manager.

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
            guard let entity = try? VRMEntityLoader(named: "model.vrm").loadEntity() else { return }
            content.add(entity)
        }
    }
}
```

`VRMEntity` is an `Entity`, so it drops into any RealityKit scene, `ARView` included. Once it is in a scene, skinning, constraints and spring bones update every frame automatically; set `isAutomaticUpdateEnabled = false` and call `update(deltaTime:)` to drive the timing yourself.

> VRMSceneKit, the SceneKit renderer, is deprecated. Use VRMRealityKit instead.

## Expressions / blend shapes

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_joy.png" width="100px" alt="joy" /><img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_angry.png" width="100px" alt="angry" /><img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_><.png" width="100px" alt="><" />

```swift
vrmEntity.setExpression(value: 1.0, for: .preset(.happy))
vrmEntity.setExpression(value: 1.0, for: .custom("><"))
```

VRM 0.x and 1.0 are driven through the same API. A 0.x model's blend shape groups load as the expressions they stand for, so `joy` is set as `.happy`.

## Bone animation

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_humanoid.png" width="200px" alt="Humanoid" />

```swift
let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
vrmEntity.humanoid.node(for: .neck)?.transform.rotation *= neckRotation
vrmEntity.invalidateSkinPose()
```

`invalidateSkinPose()` tells the runtime that a bone moved. Animation, constraints and spring bones do this themselves.

## VRM animation (.vrma)

A `.vrma` file retargets onto any loaded model, VRM 1.0 and 0.x alike. Humanoid bone rotations, the hips motion scaled to the model's size, and expression tracks all play. An optional bone the model lacks, such as `upperChest`, hands its rotation to the bones that stand in for it.

```swift
let animation = try VRMAnimation(named: "walk.vrma")
let controller = try vrmEntity.playAnimation(animation, loops: true)
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
vrmEntity.setMToonLightDirection(SIMD3<Float>(0, 0, -1))
vrmEntity.setMToonLightColor(SIMD3<Float>(1, 1, 1))
vrmEntity.setMToonAmbientColor(SIMD3<Float>(0.1, 0.1, 0.1))
```

Both loaders take a material shader chain: each shader is asked in order, and materials no shader claims render through the built-in Unlit / PBR path.

```swift
// The default chain is [MToonShader()]: MToon with authored outlines. Use
// .always for a hidden outline pass on every MToon material, so any of them
// can be outlined at runtime.
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

`GLTFShadedMaterial` also carries extra render passes, MToon's outline being one, and a `makeAnimatableState` closure that lets VRM expressions animate a custom material. The `GLTFMaterialShader` documentation comments cover both, along with what a shader may assume about the mesh it draws.

A pass can be built hidden and shown later with `entity.setPassEnabled(_:named:)`, which is how MToon outlines double as a selection highlight. An override outranks the authored values, and releasing it puts them back.

```swift
entity.setMToonOutlineOverride(
    MToonOutlineOverride(color: SIMD3<Float>(0, 0.5, 1),
                         width: 0.004,          // a fraction of the screen height
                         mode: .screenCoordinates)
)
entity.setMToonOutlineOverride(nil) // back to the authored outlines
```

The override also takes a material set, so part of a model can be outlined on its own. `materialIndices(under:)` answers with the materials under a node; the unit is the glTF material, so one shared beyond the subtree is outlined everywhere it draws.

```swift
let selection = entity.materialIndices(under: selectedNode)
entity.setMToonOutlineOverride(highlight, forMaterials: selection)
entity.setMToonOutlineOverride(nil, forMaterials: selection) // release just those
```

</details>

## Render glTF / GLB

<details>
<summary>Details</summary>

VRMRealityKit also renders plain glTF assets: `.glb` and JSON `.gltf`, external resources and data URIs included.

```swift
let entity: GLTFEntity = try GLTFEntityLoader(withURL: url).loadEntity()

entity.animations  // [GLTFAnimation]: index, name, duration
let controller = try entity.playAnimation(at: 0, loops: true)  // same controller as above
```

`loadEntity()` renders the asset's default scene, and throws when the glTF names none; pick one with `loadEntity(withSceneIndex:)`. A `clone(recursive:)` copy shares the loaded meshes and materials but not the animation bindings, so load the scene again for a second animatable instance.

<details>
<summary>Renderer limitations</summary>

RealityKit meshes and materials cannot express every part of glTF and MToon. Each case below logs a warning once per affected material.

- Only triangle primitives are drawn; `POINTS` and `LINES` primitives are skipped.
- `COLOR_0` vertex colors are ignored: the mesh buffers this renderer builds carry no vertex-color channel.
- One UV set and one `KHR_texture_transform` per material: the first UV-accessed texture decides both. A glTF load requiring more is rejected rather than drawn wrong; a VRM load renders the approximation.
- Tangents for a primitive without `TANGENT` are averaged from its UV gradients, not generated with MikkTSpace, so a normal map baked against MikkTSpace can differ along UV seams.
- Blend shapes morph `POSITION` only, since RealityKit blend shapes have no `NORMAL` / `TANGENT` channel.
- Skinning reads `JOINTS_0` / `WEIGHTS_0` only, so a vertex is driven by at most four joints.
- MToon's `renderQueueOffsetNumber` is ignored, because RealityKit has no material-level draw-order hook; `transparentWithZWrite` works through `CustomMaterial.writesDepth`.
- MToon's outline is clamped to a culling margin of the mesh's radius, so an outline asking for more caps out there.
- MToon's outline takes its lit color from the runtime light color, not from the surface's fully evaluated shading, which RealityKit does not expose to a `CustomMaterial`.

</details>

</details>

## Edit and save glTF / VRM

<details>
<summary>Details</summary>

`GLTFEditableDocument` edits an asset's glTF JSON and writes it back out as a GLB. Fields VRMKit does not model, unknown extensions included, are carried over untouched, and nothing already in the document changes index. A document spread over several buffers is merged into the one a GLB holds, which moves byte offsets; one that also declares an extension VRMKit does not know is refused rather than relaid out underneath it.

```swift
let vrm = try VRM(data: data)
let document = try GLTFEditableDocument(data: data)
if let hand = vrm.nodeIndex(of: .leftHand) {
    let item = try GLTFDocument(withURL: itemURL)
    try document.append(item, under: hand, name: "item", materials: .mtoon)
}
try document.serialize().write(to: outputURL)
```

`append` copies the whole source document to the end of the arrays it belongs in, embeds its external resources into the GLB buffer, and keeps a VRM 0.x model's `materialProperties` parallel to its materials. The source's default scene decides which of the copied nodes are drawn, or the one `append(_:sceneAt:under:)` names. Sources it cannot rebase are refused rather than written out broken: one declaring an unknown extension, Draco and meshopt among them, and a VRM 0.x model, whose materials are described outside the materials themselves.

`materials: .mtoon` writes those materials as MToon instead: the `materialProperties` entry of a VRM 0.x model, the `VRMC_materials_mtoon` extension of anything else. A material that already carries MToon keeps what it says, and one that carries none converts through the same `MToonConversionStyle` as `MToonShader(source: .convertAll)`, so an item previewed toon-shaded is saved looking the same. `convertMaterialsToMToon(at:style:)` does it to materials already in the document. VRM 0.x applies one UV transform to all of a material's textures and samples UV set 0 only, so a material asking for a rotation, a second UV set or a transform per texture is refused rather than saved looking different.

`addNode`, `setName` and `setTransform` edit the node graph by appending, never by renumbering, so the extensions that make a document a VRM keep pointing at what they used to. `detachNode` cuts a subtree's links to its parent and scenes and nothing else, and `moveNode(at:to:)` cuts them and hangs the subtree under another node, or under the default scene's roots when given none.

`GLTFEditableDocument()` starts an empty document and `addMesh` fills it from vertex data, so a plate, a prop or a test fixture can be built without laying out accessors, buffer views and the GLB container by hand.

```swift
let document = GLTFEditableDocument()
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

The scope is one indexed triangle mesh and one material: positions, optional normals and texture coordinates, a base color factor and a PNG or JPEG image with its wrap and filter modes, unlit, alpha mode and double-sidedness. Any other image format is refused rather than transcoded. `addMesh` returns the node it added and takes the same `materials: .mtoon` as `append`. A mesh given no normals is flat-shaded, which is what `VRMRealityKit` draws; the deprecated `VRMSceneKit` shades it smooth.

</details>

# ToDo

- [ ] Look-at playback from vrma

# Contributing

Pull requests are welcome. Fork the repository, work on a feature branch, and open a PR :D

## Support this project

Donating to help me continue working on this project.

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://paypal.me/tattn/)

# License

VRMKit is released under the MIT license. See LICENSE for details.

# Author

Tatsuya Tanaka

<a href="https://x.com/tattn_dev" target="_blank"><img alt="Twitter" src="https://img.shields.io/twitter/follow/tattn_dev.svg?style=social&label=Follow"></a>
<a href="https://github.com/tattn" target="_blank"><img alt="GitHub" src="https://img.shields.io/github/followers/tattn.svg?style=social"></a>
