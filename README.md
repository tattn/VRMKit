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

# Requirements

- Swift 6.0+
- iOS 15.0+
- macOS 12.0+
- visionOS 2.0+
- watchOS 8.0+ (Experimental)

VRMRealityKit requires iOS 18.0+ / macOS 15.0+ / visionOS 2.0+.

# Installation

## Swift Package Manager

You can install this package with Swift Package Manager.

## Carthage & CocoaPods (Deprecated)

If you want to use these package managers, please use https://github.com/tattn/VRMKit/releases/tag/0.4.2

# Usage

## Load VRM

```swift
import VRMKit

let vrm = try VRMLoader().load(named: "model.vrm")
// let vrm = try VRMLoader().load(withUrl: URL(string: "/path/to/model.vrm")!)
// let vrm = try VRMLoader().load(withData: data)

// VRM meta data
vrm.meta.title
vrm.meta.author

// model data
vrm.gltf.jsonData.nodes[0].name
```

## Render VRM

```swift
import RealityKit
import VRMKit
import VRMRealityKit

let loader = try VRMEntityLoader(named: "model.vrm")
let vrmEntity = try loader.loadEntity()

let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
let anchor = AnchorEntity(world: .zero)
anchor.addChild(vrmEntity)
arView.scene.addAnchor(anchor)
```

`VRMEntity` is an `Entity`. Once it is in a scene, skinning, constraints and spring bones are updated every frame automatically.

### Render VRM (SwiftUI)

```swift
import RealityKit
import SwiftUI
import VRMKit
import VRMRealityKit

struct ContentView: View {
    var body: some View {
        RealityView { content in
            guard let loader = try? VRMEntityLoader(named: "model.vrm"),
                  let vrmEntity = try? loader.loadEntity() else { return }
            content.add(vrmEntity)
        }
    }
}
```

<details>
<summary>Render VRM (SceneKit) — Deprecated</summary>

> Note: VRMSceneKit is deprecated. Use VRMRealityKit instead.

```swift
import VRMKit
import VRMSceneKit

@IBOutlet weak var sceneView: SCNView!

let loader = try VRMSceneLoader(named: "model.vrm")
let scene: VRMScene = try loader.loadScene()
let node: VRMNode = scene.vrmNode

sceneView.scene = scene
```

</details>

### Blend shapes / expressions

VRM 0.x uses blend shapes:

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_joy.png" width="100px" alt="joy" />

```swift
vrmEntity.setBlendShape(value: 1.0, for: .preset(.joy))
```

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_angry.png" width="100px" alt="angry" />

```swift
vrmEntity.setBlendShape(value: 1.0, for: .preset(.angry))
```

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_><.png" width="100px" alt="><" />

```swift
vrmEntity.setBlendShape(value: 1.0, for: .custom("><"))
```

VRM 1.0 uses expressions:

```swift
vrmEntity.setExpression(value: 1.0, for: .preset(.happy))
vrmEntity.setExpression(value: 1.0, for: .preset(.aa))
vrmEntity.setExpression(value: 1.0, for: .custom("customExpressionName"))
```

### Bone animation

<img src="https://github.com/tattn/VRMKit/raw/main/.github/alicia_humanoid.png" width="200px" alt="Humanoid" />

```swift
let neckRotation = simd_quatf(angle: 20 * .pi / 180, axis: SIMD3<Float>(0, 0, 1))
vrmEntity.humanoid.node(for: .neck)?.transform.rotation *= neckRotation
```

### Read the thumbnail image

```swift
let loader = VRMLoader()
let vrm = try loader.load(named: "model.vrm")
let image = try loader.loadThumbnail(from: vrm)
```

## MToon rendering

VRMRealityKit renders MToon materials by default on iOS and macOS. visionOS falls back to Unlit / PBR materials because RealityKit's `CustomMaterial` is unavailable there.

```swift
vrmEntity.setMToonLightDirection(SIMD3<Float>(0, 0, -1))
vrmEntity.setMToonLightColor(SIMD3<Float>(1, 1, 1))
vrmEntity.setMToonAmbientColor(SIMD3<Float>(0.1, 0.1, 0.1))
```

<details>
<summary>Loader options and limitations</summary>

```swift
let loader = try VRMEntityLoader(
    named: "model.vrm",
    isMToonEnabled: true,  // false: disable MToon and use the legacy Unlit / PBR conversion
    isOutlineEnabled: true // false: skip MToon outline entities
)
```

Outlines can be skipped while keeping the MToon surface shader. On visionOS both options fall back automatically because the required RealityKit APIs are unavailable.

RealityKit constrains what the MToon renderer can express. Each case below logs a warning once per affected material.

- `renderQueueOffsetNumber` is parsed but ignored, because RealityKit has no material-level draw-order hook. (`transparentWithZWrite` is supported through `CustomMaterial.writesDepth`, so a blended material can still write depth.)
- Textures requesting a UV set other than `TEXCOORD_0` use `TEXCOORD_0`, because custom meshes expose only that one.
- When UV-accessed texture slots specify different `KHR_texture_transform` values, the transform of the first UV-accessed slot — base color when the material has one — is applied to all of them, because `CustomMaterial` has a single material-level UV transform. Expression texture transform binds still update all UV-accessed textures together as required by VRMC_vrm.

</details>

<details>
<summary>Frame updates</summary>

`VRMUpdateSystem` (a RealityKit `System` registered on load) calls `VRMEntity.update(deltaTime:)` on every render frame. To control the timing yourself, opt out and call it manually:

```swift
vrmEntity.isAutomaticUpdateEnabled = false

// Then, once per frame:
vrmEntity.update(deltaTime: deltaTime)
```

To run your own animation code in a guaranteed order relative to the VRM update (e.g. posing joints that the same frame's skinning should reflect), put it in a custom `System` declared with `SystemDependency.before(VRMUpdateSystem.self)`.

</details>

<details>
<summary>Render glTF / GLB</summary>

VRMRealityKit can also render plain glTF assets (`.glb` and JSON `.gltf`, including external resources and data URIs).

```swift
let entity: GLTFEntity = try GLTFEntityLoader(withURL: url).loadEntity()
content.add(entity)

entity.animations          // [GLTFAnimation] — index, name, duration
let controller = try entity.playAnimation(at: 0, loops: true)
controller.speed = 2       // a negative speed plays backwards
controller.seek(to: 0.5)
controller.stop()
```

`loadEntity()` renders the asset's default scene, and throws when the glTF names none; pick one with `loadEntity(withSceneIndex:)`. A `clone(recursive:)` copy shares the loaded meshes and materials but not the animation bindings, so load the scene again for a second animatable instance.

### RealityKit renderer limitations

The renderer builds RealityKit meshes and materials, so a few parts of glTF have no place to go:

- Only triangle primitives are drawn; `POINTS` and `LINES` primitives are skipped.
- `COLOR_0` vertex colors are ignored: the `MeshResource.Part` buffers this renderer builds carry no vertex-color channel.
- One UV set per material: the first UV-accessed texture decides both the `TEXCOORD_n` set and the single `KHR_texture_transform` every texture of that material is sampled with. An asset that merely lists `KHR_texture_transform` in `extensionsUsed` renders through that approximation and logs it; one that lists it in `extensionsRequired` and gives a material's textures different transforms is rejected instead of drawn wrong.
- Tangents for a primitive without `TANGENT` are averaged from its UV gradients rather than generated with MikkTSpace, which the spec recommends, so a normal map baked against MikkTSpace can differ slightly along UV seams.
- Blend shapes morph `POSITION` only, since RealityKit blend shapes have no `NORMAL` / `TANGENT` channel.
- Skinning reads `JOINTS_0` / `WEIGHTS_0` only, so a vertex is driven by at most four joints; the further sets a glTF may carry (`JOINTS_1` and up) are ignored, which the spec allows and which can change the result of an animation.

</details>

# ToDo

- [x] VRM 1.0 support
  - [x] Decoding VRM 1.0 file
  - [x] Render an avatar by RealityKit (as VRM 0.x)
  - [x] Render an avatar by RealityKit (as VRM 1.x)
- [x] VRM shaders support (MToon, RealityKit)
- [ ] Improve rendering quality
- [ ] Animation support (vrma)
- [ ] VRM editing function
- [x] glTF renderer / animation support (RealityKit)

# Contributing

1. Fork it!
2. Create your feature branch: `git checkout -b my-new-feature`
3. Commit your changes: `git commit -am 'Add some feature'`
4. Push to the branch: `git push origin my-new-feature`
5. Submit a pull request :D

## Support this project

Donating to help me continue working on this project.

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://paypal.me/tattn/)

# License

VRMKit is released under the MIT license. See LICENSE for details.

# Author

Tatsuya Tanaka

<a href="https://twitter.com/tattn_dev" target="_blank"><img alt="Twitter" src="https://img.shields.io/twitter/follow/tattn_dev.svg?style=social&label=Follow"></a>
<a href="https://github.com/tattn" target="_blank"><img alt="GitHub" src="https://img.shields.io/github/followers/tattn.svg?style=social"></a>
