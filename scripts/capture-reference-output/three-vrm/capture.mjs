// Headless capture of humanoid bones, expressions, look-at, node constraints, and
// spring-bone joint positions from a VRM 1.0 asset via three-vrm, matching the schema at
// Tests/Assets/ReferenceOutputs/schema.json. See ../README.md for the capture contract.
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import * as THREE from 'three';
import { GLTFLoader } from 'three/examples/jsm/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMHumanBoneName, VRMExpressionPresetName } from '@pixiv/three-vrm';

const SOURCE_VERSION = 'v3.5.5';
const SOURCE_COMMIT = '1b4fc0cc7ef39a49d62bb7a66dcfeca8f65316f7';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '../../..');

function toVector3(vector) {
    return { x: vector.x, y: vector.y, z: vector.z };
}

// This capture never renders anything, so material/texture data is dropped before
// parsing rather than polyfilling a headless Image/canvas decoder for it.
function pruneTextureReferences(value) {
    if (Array.isArray(value)) {
        for (const item of value) pruneTextureReferences(item);
        return;
    }
    if (value === null || typeof value !== 'object') return;
    for (const key of Object.keys(value)) {
        const child = value[key];
        if (child !== null && typeof child === 'object' && !Array.isArray(child)
            && typeof child.index === 'number') {
            delete value[key];
        } else {
            pruneTextureReferences(child);
        }
    }
}

function stripTexturesFromGLB(buffer) {
    const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    const jsonChunkLength = view.getUint32(12, true);
    const jsonBytes = buffer.subarray(20, 20 + jsonChunkLength);
    const json = JSON.parse(jsonBytes.toString('utf8'));

    delete json.images;
    delete json.textures;
    delete json.samplers;
    pruneTextureReferences(json.materials);

    let jsonString = JSON.stringify(json);
    while (jsonString.length % 4 !== 0) jsonString += ' ';
    const newJsonBytes = Buffer.from(jsonString, 'utf8');

    const binChunkStart = 12 + 8 + jsonChunkLength;
    const binChunk = binChunkStart < buffer.byteLength ? buffer.subarray(binChunkStart) : Buffer.alloc(0);

    const header = Buffer.alloc(12);
    header.writeUInt32LE(0x46546c67, 0); // 'glTF'
    header.writeUInt32LE(2, 4);
    header.writeUInt32LE(12 + 8 + newJsonBytes.length + binChunk.length, 8);

    const jsonChunkHeader = Buffer.alloc(8);
    jsonChunkHeader.writeUInt32LE(newJsonBytes.length, 0);
    jsonChunkHeader.writeUInt32LE(0x4e4f534a, 4); // 'JSON'

    return Buffer.concat([header, jsonChunkHeader, newJsonBytes, binChunk]);
}

async function loadVrm(fixtureRelativePath) {
    const absolutePath = path.join(repoRoot, fixtureRelativePath);
    const bytes = await readFile(absolutePath);
    const sanitized = stripTexturesFromGLB(bytes);

    const loader = new GLTFLoader();
    loader.register((parser) => new VRMLoaderPlugin(parser));
    const gltf = await loader.parseAsync(
        sanitized.buffer.slice(sanitized.byteOffset, sanitized.byteOffset + sanitized.byteLength), '');
    const vrm = gltf.userData.vrm;
    vrm.scene.updateMatrixWorld(true);

    return { vrm, bytes, absolutePath };
}

function captureBones(vrm) {
    const names = [];
    const positions = [];
    const rotations = [];
    const hips = vrm.humanoid.getRawBoneNode(VRMHumanBoneName.Hips);
    const origin = new THREE.Vector3();
    hips.getWorldPosition(origin);

    for (const boneName of Object.values(VRMHumanBoneName)) {
        const node = vrm.humanoid.getRawBoneNode(boneName);
        if (!node) continue;
        const position = new THREE.Vector3();
        const rotation = new THREE.Quaternion();
        node.getWorldPosition(position);
        node.getWorldQuaternion(rotation);
        names.push(boneName);
        positions.push(toVector3(position));
        rotations.push({ x: rotation.x, y: rotation.y, z: rotation.z, w: rotation.w });
    }

    return { names, types: [], sources: [], scalars: [], positions, rotations };
}

function captureExpressions(vrm) {
    const manager = vrm.expressionManager;
    const names = [];
    const scalars = [];
    if (manager) {
        for (const name of Object.values(VRMExpressionPresetName)) {
            if (!manager.getExpression(name)) continue;
            names.push(name);
            scalars.push(manager.getValue(name) ?? 0);
        }
    }
    return { names, types: [], sources: [], scalars, positions: [], rotations: [] };
}

function captureLookAt(vrm) {
    const lookAt = vrm.lookAt;
    const yaw = lookAt?.yaw ?? 0;
    const pitch = lookAt?.pitch ?? 0;
    return { names: ['yaw', 'pitch'], types: [], sources: [], scalars: [yaw, pitch], positions: [], rotations: [] };
}

function captureConstraints(vrm) {
    const names = [];
    const types = [];
    for (const constraint of vrm.nodeConstraintManager?.constraints ?? []) {
        names.push(constraint.destination?.name ?? '');
        types.push(constraint.constructor.name);
    }
    return { names, types, sources: [], scalars: [], positions: [], rotations: [] };
}

function captureSpringPositions(vrm) {
    const names = [];
    const positions = [];
    for (const joint of vrm.springBoneManager?.joints ?? []) {
        const position = new THREE.Vector3();
        joint.bone.getWorldPosition(position);
        names.push(joint.bone.name);
        positions.push(toVector3(position));
    }
    return { names, types: [], sources: [], scalars: [], positions, rotations: [] };
}

async function main() {
    const fixtureRelativePath = process.argv[2] ?? 'Tests/Assets/VRM/AvatarSample_M.vrm';
    const outputPath = process.argv[3]
        ?? path.join(repoRoot, 'Tests/Assets/ReferenceOutputs/three-vrm/AvatarSample_M.json');

    const { vrm, bytes } = await loadVrm(fixtureRelativePath);
    const sha256 = createHash('sha256').update(bytes).digest('hex');

    const output = {
        schemaVersion: '1',
        source: {
            name: 'three-vrm',
            version: SOURCE_VERSION,
            commit: SOURCE_COMMIT,
            notes: 'Captured headlessly with three.js + @pixiv/three-vrm on Node.js.'
        },
        fixture: { path: fixtureRelativePath, sha256 },
        coordinateSystem: {
            handedness: 'right',
            upAxis: '+Y',
            forwardAxis: '-Z',
            units: 'meters',
            notes: 'three.js world coordinates; rotations are three.js quaternions.'
        },
        tolerances: { translation: 0.002, rotation: 0.001, scalar: 0.001 },
        samples: {
            bones: [{ time: 0, values: captureBones(vrm), notes: '' }],
            expressions: [{ time: 0, values: captureExpressions(vrm), notes: '' }],
            lookAt: [{ time: 0, values: captureLookAt(vrm), notes: '' }],
            constraints: [{ time: 0, values: captureConstraints(vrm), notes: '' }],
            springPositions: [{ time: 0, values: captureSpringPositions(vrm), notes: '' }],
            vrma: [{
                time: 0,
                values: captureBones(vrm),
                notes: 'No three-vrm VRMA controller is attached; this is the current runtime pose.'
            }]
        }
    };

    await writeFile(outputPath, JSON.stringify(output, null, 4));
    console.log(`three-vrm reference output written: ${outputPath}`);
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
