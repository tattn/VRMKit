# glTF Sample Assets (test fixtures)

Test fixtures for the generic glTF rendering path, taken from
[KhronosGroup/glTF-Sample-Assets](https://github.com/KhronosGroup/glTF-Sample-Assets)
(`Models/<name>/`).

**Every model here is licensed CC0-1.0**, so the fixtures carry no attribution
obligation. Models under CC-BY-4.0 were deliberately excluded to keep this
repository free of attribution requirements; cover their features with
hand-written fixtures instead (sparse accessors are covered that way in
`GLTFEntityLoaderTests.testSparseAccessorSubstitutesPositions`). Each model keeps
its upstream `LICENSE.md`; note that those metadocumentation files are
themselves CC-BY-4.0, as stated inside them.

| Model | Variant | What it covers |
|---|---|---|
| Triangle | glTF | Minimal indexed geometry, external `.bin` |
| TriangleWithoutIndices | glTF | Non-indexed geometry (`primitive.indices` absent) |
| SimpleMeshes | glTF | Two nodes sharing one mesh |
| SimpleTexture | glTF | External PNG image + sampler |
| SimpleSkin | glTF-Embedded | Skin, joints, inverse bind matrices, data URI buffer |
| SimpleMorph | glTF-Embedded | Morph targets with `mesh.weights` |
| Cameras | glTF-Embedded | Perspective and orthographic cameras |
| AnimatedTriangle | glTF-Embedded | Animation channels (rotation, LINEAR) |
| BoxVertexColors | glTF-Binary | `COLOR_0` vertex colors, GLB container |
| AnimatedMorphCube | glTF-Binary | Morph target animation (`weights` path) |
| InterpolationTest | glTF-Binary | LINEAR / STEP / CUBICSPLINE samplers |
| TextureTransformTest | glTF | `KHR_texture_transform` |

The animation models drive `GLTFAnimationPlaybackTests`: `InterpolationTest`
alone covers all three glTF interpolations across nine animations.

To refresh, re-download the same paths from the upstream `main` branch.
