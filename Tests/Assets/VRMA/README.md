# VRM animations (`.vrma` fixtures)

Between them the two files cover the retargeting paths from opposite ends: one
is a minimal file with a single channel per path, the other a real full-body
motion.

## `walk.vrma`

A walk cycle, CC0. It was retargeted to `.vrma` from the CC0
[Josie - Character Model](https://jenjell.itch.io/josie-character-model)
animations with Blender and [Blender-MCP](https://github.com/ahujasid/blender-mcp),
and exported with VRM Add-on for Blender v3.18.0. Public domain, so it needs no
license file and carries no attribution obligation.

The example apps play it, and it is what the tests exercise real-world
retargeting with: 54 humanoid bones mapped, 52 rotation channels plus the hips
translation, no expressions, LINEAR throughout. Its 0.77 s cycle loops, and its
source skeleton rests with the hips 0.908 m up, a different build from either
bundled `.vrm`, which is what makes it a retargeting test rather than a replay.

## `test.vrma`

A test fixture only; the example apps do not bundle it.

The `VRMC_vrm_animation` sample from
[pixiv/three-vrm](https://github.com/pixiv/three-vrm)
(`packages/three-vrm-animation/examples/models/test.vrma`), licensed under the
MIT License. See the bundled [`LICENSE`](LICENSE), which is three-vrm's
repository license and covers this file only.

The 3-second animation covers each retargeting path with one channel. Its
skeleton rests with non-identity local rotations, which is what makes it a
worthwhile complement to the identity-rest `VRMASampleFixture`:

| Time | Channel | Value |
|---|---|---|
| 0.5 s | `rightUpperArm` rotation | 90° around the bone's local +X, which is the model's +Z, so the arm lifts sideways. Back at rest by 1 s |
| 1.5 s | `happy` expression | weight 1, zero elsewhere |
| 2.5 s | look-at rotation | 90° around +Y, a gaze a quarter turn to the model's own left |
