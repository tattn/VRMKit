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

<div>
<img src="https://github.com/tattn/VRMKit/raw/main/.github/demo.jpg" width="300px" alt="demo" />
<img src="https://github.com/tattn/VRMKit/raw/main/.github/demo2.gif" width="300px" alt="demo" />
</div>

For "VRM", please refer to [this page](https://dwango.github.io/en/vrm/).

## Features

- [x] Load VRM file
- [x] Render VRM models on RealityKit (experimental)
- [x] Face morphing (blend shape)
- [x] Bone animation (skin / joint)
- [x] Physics (spring bone)
- [x] MToon rendering and custom material shaders
- [x] Render plain glTF / GLB with animations

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

let loader = VRMLoader()
let vrm = try loader.load(named: "model.vrm")
// let vrm = try loader.load(withUrl: URL(string: "/path/to/model.vrm")!)
// let vrm = try loader.load(withData: data)

// VRM meta data
vrm.meta.title
vrm.meta.author

// model data
vrm.gltf.jsonData.nodes[0].name

// thumbnail
try loader.loadThumbnail(from: vrm)
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

`VRMEntity` is an `Entity`, so it drops into any RealityKit scene, `ARView` included. Once it is in a scene, skinning, constraints and spring bones update every frame automatically; set `isAutomaticUpdateEnabled = false` and call `update(deltaTime:)` to drive the timing yourself. Animation code that must run in a fixed order relative to that update belongs in a `System` declared with `SystemDependency.before(VRMUpdateSystem.self)`.

> VRMSceneKit, the SceneKit renderer, is deprecated. Use VRMRealityKit instead.

## Expressions / blend shapes

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_joy.png" width="100px" alt="joy" />
<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_angry.png" width="100px" alt="angry" />
<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_><.png" width="100px" alt="><" />

```swift
// VRM 1.0
vrmEntity.setExpression(value: 1.0, for: .preset(.happy))
vrmEntity.setExpression(value: 1.0, for: .custom("customExpressionName"))

// VRM 0.x
vrmEntity.setBlendShape(value: 1.0, for: .preset(.joy))
vrmEntity.setBlendShape(value: 1.0, for: .custom("><"))
```

## Bone animation

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_humanoid.png" width="200px" alt="Humanoid" />

```swift
let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
vrmEntity.humanoid.node(for: .neck)?.transform.rotation *= neckRotation
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

`GLTFShadedMaterial` also carries extra render passes (MToon draws its outline as one) and a `makeAnimatableState` closure that lets VRM expressions animate a custom material. The `GLTFMaterialShader` documentation comments cover both, along with what a shader may assume about the mesh it draws.

A pass can be built hidden and shown later with `entity.setPassEnabled(_:named:)`, which is how MToon outlines double as a selection highlight. The override outranks the authored values — a VRM expression bound to `outlineColor` included — and releasing it puts them back.

```swift
entity.setMToonOutlineOverride(
    MToonOutlineOverride(color: SIMD3<Float>(0, 0.5, 1),
                         width: 0.004,          // a fraction of the screen height
                         mode: .screenCoordinates)
)
entity.setMToonOutlineOverride(nil) // back to the authored outlines
```

The override also takes a material set, so part of a model — a selected node's subtree, say — can be outlined on its own. `materialIndices(under:)` answers with the materials any model entity under a node renders with; the unit is the glTF material, so one shared beyond the subtree is outlined everywhere it draws. Disjoint selections compose, and releasing one leaves the others standing.

```swift
let selection = entity.materialIndices(under: selectedNode)
entity.setMToonOutlineOverride(highlight, forMaterials: selection)
entity.setMToonOutlineOverride(nil, forMaterials: selection) // release just those
```

</details>

## Render glTF / GLB

<details>
<summary>Details</summary>

VRMRealityKit also renders plain glTF assets (`.glb` and JSON `.gltf`, including external resources and data URIs).

```swift
let entity: GLTFEntity = try GLTFEntityLoader(withURL: url).loadEntity()

entity.animations          // [GLTFAnimation]: index, name, duration
let controller = try entity.playAnimation(at: 0, loops: true)
controller.speed = 2       // a negative speed plays backwards
controller.seek(to: 0.5)
controller.stop()
```

`loadEntity()` renders the asset's default scene, and throws when the glTF names none; pick one with `loadEntity(withSceneIndex:)`. A `clone(recursive:)` copy shares the loaded meshes and materials but not the animation bindings, so load the scene again for a second animatable instance.

<details>
<summary>Renderer limitations</summary>

RealityKit meshes and materials cannot express every part of glTF and MToon. Each case below logs a warning once per affected material.

- Only triangle primitives are drawn; `POINTS` and `LINES` primitives are skipped.
- `COLOR_0` vertex colors are ignored: the mesh buffers this renderer builds carry no vertex-color channel.
- One UV set and one `KHR_texture_transform` per material: the first UV-accessed texture decides both for every texture of that material. A glTF load rejects a document that lists `KHR_texture_transform` in `extensionsRequired` and needs more than that, instead of drawing it wrong; a VRM load renders the approximation.
- Tangents for a primitive without `TANGENT` are averaged from its UV gradients rather than generated with MikkTSpace, which the spec recommends, so a normal map baked against MikkTSpace can differ slightly along UV seams.
- Blend shapes morph `POSITION` only, since RealityKit blend shapes have no `NORMAL` / `TANGENT` channel.
- Skinning reads `JOINTS_0` / `WEIGHTS_0` only, so a vertex is driven by at most four joints; the further sets a glTF may carry are ignored.
- MToon's `renderQueueOffsetNumber` is parsed but ignored, because RealityKit has no material-level draw-order hook. (`transparentWithZWrite` is supported through `CustomMaterial.writesDepth`.)
- MToon's outline is drawn past the mesh's bounding box, which RealityKit culls by, so the outline pass is given a culling margin of the mesh's radius and its vertex offset is clamped to that same margin. An outline asking for more — a screen-space width far from the camera, say — caps out there rather than growing further.
- MToon's outline takes its lit color from the runtime light color rather than from the surface's fully evaluated shading, which RealityKit does not expose to a `CustomMaterial`.

</details>

</details>

# ToDo

- [ ] Animation support (vrma)
- [ ] VRM export

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
