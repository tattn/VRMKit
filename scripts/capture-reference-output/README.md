# Capture conformance reference output

This procedure records observable VRM and VRMA behavior from UniVRM and three-vrm without copying
engine-specific code into VRMKit. Captured files must validate against
`Tests/Assets/ReferenceOutputs/schema.json`.

## Reference revisions

Use the following revisions unless a comparison run explicitly records newer ones:

| Source | URL | Revision | Release |
| --- | --- | --- | --- |
| UniVRM | [github.com/vrm-c/univrm](https://github.com/vrm-c/univrm) | `928b30e96439c1c11a49b172efb72eb96d2cad8b` | `v0.131.2` |
| three-vrm | [github.com/pixiv/three-vrm](https://github.com/pixiv/three-vrm) | `1b4fc0cc7ef39a49d62bb7a66dcfeca8f65316f7` | `v3.5.5` |

## Capture contract

1. Select one fixture and record its repository-relative path and SHA-256 digest.
2. Load the fixture with the selected reference implementation at the pinned revision.
3. Sample the same times and inputs for normalized bones, expressions, look-at, constraints, spring
   positions, and VRMA playback.
4. Export one JSON document with `source`, `fixture`, `coordinateSystem`, `tolerances`, and `samples`
   fields required by the schema.
5. Record any coordinate conversion in `coordinateSystem.notes`; do not silently transform values.
6. Store the result under `Tests/Assets/ReferenceOutputs/univrm/` or
   `Tests/Assets/ReferenceOutputs/three-vrm/`.
7. Validate the JSON with a standards-compliant JSON Schema validator before comparing it with Swift
   output.

## Comparison rules

- Pin the exact source commit and release in every output; never compare moving branches implicitly.
- Compare translations and spring positions in meters, rotations as normalized quaternions or
  documented Euler angles, and scalar weights with the tolerances recorded in the output.
- Convert coordinate systems once at the boundary and document the conversion.
- Do not use pixel identity as a conformance criterion. Record rendering comparisons separately from
  normalized runtime samples.

The repository currently contains the schema and fixture inventory, but no captured external outputs.
A differential result must not be marked complete until both the source output and the corresponding
VRMKit output are checked in and reviewed.
