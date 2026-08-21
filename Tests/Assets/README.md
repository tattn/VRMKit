# Test assets

Fixtures shared by every test target, and by the Example apps.

| Directory | Contents |
|---|---|
| [`GLTF/`](GLTF/README.md) | CC0-1.0 models from KhronosGroup/glTF-Sample-Assets |
| `VRM/` | `.vrm` models for the VRM 0.x / 1.0 loading paths |

`VRMTestSupport` owns this directory as its resources (see `Package.swift`), so
the fixtures are copied into one bundle instead of one per test target. Reach
them through `GLTFSampleAsset` / `VRMSampleAsset`, never through
`Bundle.module` of a test target: the assets are not in those bundles.

When adding a fixture, drop it in the matching directory and add a case to the
corresponding enum in `Tests/VRMTestSupport`.
