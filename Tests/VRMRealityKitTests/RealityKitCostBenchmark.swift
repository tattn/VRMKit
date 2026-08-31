#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import Testing
import VRMKit
@testable import VRMRealityKit

/// Splits the CPU a loaded VRM costs per frame into the parts worth reducing.
/// Not part of a normal test run: set `VRMKIT_BENCH=1` to run it.
///
///     VRMKIT_BENCH=1 swift test -c release --filter RealityKitCostBenchmark
///
/// Three things are measured:
///
/// - **Entity count on its own**, by adding empty entities to the scene.
/// - **Writing `SkeletalPosesComponent`**, by varying how many skeletons are written.
/// - **Holding the joints as an entity hierarchy.** A skin pose lives entirely in
///   `SkeletalPosesComponent`, against a skeleton `MeshResource` defines; the joint
///   entities are the loader's own bookkeeping. When no `ModelEntity` hangs off a
///   joint, detaching the whole joint hierarchy after solving a pose still draws the
///   same picture — which is where a backend holding poses in arrays would end up,
///   so the two measured side by side give that design's ceiling before writing it.
/// Run this suite on its own, as the command above does: anything running beside a
/// timed loop shows up in its numbers, and suites run in parallel with each other.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VRMKIT_BENCH"] == "1"), .serialized)
@MainActor
struct RealityKitCostBenchmark {
    private func allEntities(_ root: Entity) -> [Entity] {
        [root] + root.children.flatMap { allEntities($0) }
    }

    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func jointIDs(of entity: GLTFEntity) -> Set<Entity.ID> {
        var ids: Set<Entity.ID> = []
        for binding in entity.skinBindings {
            for joint in binding.jointEntities { ids.insert(joint.id) }
        }
        return ids
    }

    /// Takes the joint hierarchy out of the scene graph once its pose is solved.
    /// `skinBindings` keeps referencing the joints, so nothing is released.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func detachJointHierarchy(from entity: VRMEntity) -> Int {
        let joints = jointIDs(of: entity)
        let roots = allEntities(entity).filter { joints.contains($0.id) && !joints.contains($0.parent?.id ?? .init()) }
        let detached = roots.reduce(0) { $0 + allEntities($1).count }
        for root in roots { root.removeFromParent() }
        return detached
    }

    // MARK: - Timing

    /// Times the per-frame pose update plus `updateAndRender` up to the point it
    /// returns, which is the CPU spent encoding the frame. The GPU is left to run
    /// behind, and only kept from queueing up more than a few frames.
    @available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
    private func millisecondsPerFrame(rendering entity: Entity,
                                      frames: Int,
                                      warmup: Int,
                                      perFrame: () -> Void) throws -> Double {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var cameraComponent = PerspectiveCameraComponent(near: 0.01, far: 100, fieldOfViewInDegrees: 30)
        cameraComponent.fieldOfViewOrientation = .vertical
        let camera = Entity()
        camera.components.set(cameraComponent)
        camera.position = SIMD3<Float>(0, 0.9, 2.4)

        let renderer = try RealityRenderer()
        renderer.entities.append(entity)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.cameraSettings.antialiasing = .none

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: 1920,
                                                                  height: 1080,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))
        let drawn = try #require(device.makeSharedEvent())

        var submitted: UInt64 = 0
        var elapsed: Double = 0
        for index in 0..<(warmup + frames) {
            // Waiting for the GPU to catch up happens outside the timed section.
            while drawn.signaledValue + 3 < submitted {}
            let start = CFAbsoluteTimeGetCurrent()
            perFrame()
            submitted += 1
            try renderer.updateAndRender(deltaTime: 1.0 / 60.0,
                                         cameraOutput: output,
                                         actionsAfterRender: [.signal(drawn, value: submitted)])
            let frameTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if index >= warmup { elapsed += frameTime }
        }
        while drawn.signaledValue < submitted {}
        return elapsed / Double(frames)
    }

    // MARK: - What a model is made of

    @Test
    func inspectSkinBindings() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        for (name, data) in [("seedSan", TestSupport.seedSanData), ("alicia", TestSupport.aliciaSolidData)] {
            let entity = try await VRMEntityLoader(withData: data).loadEntity()
            let all = allEntities(entity)
            let joints = jointIDs(of: entity)
            let models = all.compactMap { $0 as? ModelEntity }
            print("BENCH \(name): \(all.count) entities = \(joints.count) joints"
                  + " + \(models.count) models + \(all.count - joints.count - models.count) other")
            let modelsUnderJoints = models.filter { model in
                sequence(first: model, next: { $0.parent }).dropFirst().contains { joints.contains($0.id) }
            }
            print("BENCH \(name): models parented under a joint: \(modelsUnderJoints.count)")
            for binding in entity.skinBindings {
                let pass = binding.modelEntity.components[GLTFMaterialPassComponent.self]?.name ?? "-"
                print("  skeleton \(binding.skeletonKey) joints \(binding.jointEntities.count)"
                      + " pass \(pass) name \(binding.modelEntity.name)")
            }
        }
    }

    // MARK: - Cost per frame

    @Test
    func benchmarkSeedSan() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }

        func load() async throws -> VRMEntity {
            let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
            entity.isAutomaticUpdateEnabled = false
            entity.update(deltaTime: 0)
            return entity
        }

        // Holding a pose: what the joint entities cost by merely being in the scene.
        let staticAttached = try await load()
        print(String(format: "BENCH static  attached: %.3f ms/frame (entities %d)",
                     try millisecondsPerFrame(rendering: staticAttached, frames: 200, warmup: 60) {},
                     allEntities(staticAttached).count))

        let staticDetached = try await load()
        let removed = detachJointHierarchy(from: staticDetached)
        print(String(format: "BENCH static  detached: %.3f ms/frame (entities %d, removed %d)",
                     try millisecondsPerFrame(rendering: staticDetached, frames: 200, warmup: 60) {},
                     allEntities(staticDetached).count, removed))

        // Detaching is only meaningful if it draws the same picture.
        let imageAttached = try await load()
        let attachedPixels = try OffscreenRenderer.render(imageAttached, size: 96)
        let imageDetached = try await load()
        _ = detachJointHierarchy(from: imageDetached)
        #expect(try OffscreenRenderer.render(imageDetached, size: 96) == attachedPixels)

        // The marginal cost of an entity, measured with entities that do nothing else.
        for extra in [0, 500, 2000] {
            let scaled = try await load()
            for _ in 0..<extra { scaled.addChild(Entity()) }
            print(String(format: "BENCH static  +%4d empty: %.3f ms/frame (entities %d)",
                         extra,
                         try millisecondsPerFrame(rendering: scaled, frames: 200, warmup: 60) {},
                         allEntities(scaled).count))
        }

        // The marginal cost of one `SkeletalPosesComponent` write. The joint hierarchy
        // is gone and the pose is written back unchanged, so nothing but the write is timed.
        for count in [0, 1, 5, 10] {
            let writer = try await load()
            _ = detachJointHierarchy(from: writer)
            let targets: [(ModelEntity, SkeletalPosesComponent)] = writer.skinBindings.prefix(count).compactMap { binding in
                binding.modelEntity.components[SkeletalPosesComponent.self].map { (binding.modelEntity, $0) }
            }
            print(String(format: "BENCH skeleton writes %2d: %.3f ms/frame",
                         targets.count,
                         try millisecondsPerFrame(rendering: writer, frames: 200, warmup: 60) {
                             for (modelEntity, component) in targets {
                                 modelEntity.components.set(component)
                             }
                         }))
        }

        // Driven through the entity hierarchy, as an app posing humanoid bones every
        // frame does: write the bones, then let the model solve constraints, gaze,
        // spring bones and the skin.
        let drivenAttached = try await load()
        let bones = HumanoidBone.allCases.compactMap { drivenAttached.humanoid.node(for: $0) }
        var tick: Float = 0
        print(String(format: "BENCH driven  attached: %.3f ms/frame (bones %d)",
                     try millisecondsPerFrame(rendering: drivenAttached, frames: 200, warmup: 60) {
                         tick += 0.01
                         for bone in bones {
                             bone.transform.rotation = simd_quatf(angle: sin(tick) * 0.05, axis: SIMD3<Float>(1, 0, 0))
                         }
                         drivenAttached.invalidateSkinPose()
                         drivenAttached.update(deltaTime: 1.0 / 60.0)
                     },
                     bones.count))

        // The same motion reaching the skin without a joint hierarchy at all: the
        // ceiling a backend holding poses in arrays could reach.
        let drivenPacked = try await load()
        _ = detachJointHierarchy(from: drivenPacked)
        var poses: [(ModelEntity, SkeletalPosesComponent)] = drivenPacked.skinBindings.compactMap { binding in
            binding.modelEntity.components[SkeletalPosesComponent.self].map { (binding.modelEntity, $0) }
        }
        var packedTick: Float = 0
        print(String(format: "BENCH driven  packed:   %.3f ms/frame (skeletons %d)",
                     try millisecondsPerFrame(rendering: drivenPacked, frames: 200, warmup: 60) {
                         packedTick += 0.01
                         let rotation = simd_quatf(angle: sin(packedTick) * 0.05, axis: SIMD3<Float>(1, 0, 0))
                         for index in poses.indices {
                             var component = poses[index].1
                             if var pose = component.poses.default {
                                 for jointIndex in pose.jointTransforms.indices {
                                     pose.jointTransforms[jointIndex].rotation = rotation
                                 }
                                 component.poses[pose.id] = pose
                                 component.poses.default = pose
                             }
                             poses[index].1 = component
                             poses[index].0.components.set(component)
                         }
                     },
                     poses.count))
    }
}
#endif
