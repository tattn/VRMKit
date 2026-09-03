#if canImport(RealityKit)
import Foundation
import Metal
import RealityKit
import Testing
import VRMKit
@testable import VRMRealityKit

/// Splits what a loaded VRM costs into the parts worth reducing: entity count, skin
/// pose writes, the per-frame update, GPU memory, and the first frame after a load.
/// Not part of a normal test run: set `VRMKIT_BENCH=1` to run it.
///
///     VRMKIT_BENCH=1 swift test -c release --filter RealityKitCostBenchmark
///
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

    // MARK: - The first frame after a load

    /// What the first frames of a freshly loaded model cost against the steady state.
    ///
    /// The MToon `.metallib` is compiled ahead of time, but RealityKit builds the render
    /// pipeline state for each material permutation the first time something draws with
    /// it, which an app that swaps avatars pays as a hitch.
    @Test
    func measureFirstFrameAfterLoad() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())

        // Warms what every load shares, so the measured load pays only its own pipelines.
        let warm = try await VRMEntityLoader(vrm: try VRM(data: TestSupport.seedSanData)).loadEntity()
        _ = try OffscreenRenderer.render(warm, size: 64)

        let entity = try await VRMEntityLoader(vrm: try VRM(data: TestSupport.seedSanData)).loadEntity()
        entity.isAutomaticUpdateEnabled = false

        var cameraComponent = PerspectiveCameraComponent(near: 0.01, far: 100, fieldOfViewInDegrees: 30)
        cameraComponent.fieldOfViewOrientation = .vertical
        let camera = Entity()
        camera.components.set(cameraComponent)
        camera.position = SIMD3<Float>(0, 0.9, 2.4)
        let renderer = try RealityRenderer()
        renderer.entities.append(entity)
        renderer.entities.append(camera)
        renderer.activeCamera = camera

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: 1920,
                                                                  height: 1080,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: target))

        // Pipeline state depends on the pixel format and vertex layout, not on how many
        // pixels are drawn, so a tiny target should compile the same pipelines.
        var prewarm: Double?
        if ProcessInfo.processInfo.environment["VRMKIT_BENCH_PREWARM"] == "1" {
            let small = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                 width: 8, height: 8,
                                                                 mipmapped: false)
            small.usage = [.renderTarget, .shaderRead, .shaderWrite]
            small.storageMode = .private
            let smallTarget = try #require(device.makeTexture(descriptor: small))
            let smallOutput = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: smallTarget))
            let start = CFAbsoluteTimeGetCurrent()
            try renderer.updateAndRender(deltaTime: 0, cameraOutput: smallOutput)
            prewarm = (CFAbsoluteTimeGetCurrent() - start) * 1000
        }

        var timings: [Double] = []
        for _ in 0..<8 {
            let start = CFAbsoluteTimeGetCurrent()
            try renderer.updateAndRender(deltaTime: 1.0 / 60.0, cameraOutput: output)
            timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        withExtendedLifetime(warm) {}
        if let prewarm {
            print(String(format: "BENCH prewarm 8x8: %.2f ms", prewarm))
        }
        print("BENCH first frames: "
              + timings.map { String(format: "%.2f", $0) }.joined(separator: ", ") + " ms")
    }

    // MARK: - What a loaded model holds on the GPU

    /// The GPU memory one model costs, split by what the load can be asked to leave out.
    @Test
    func measureLoadedModelGPUMemory() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())

        func load(shaders: [any GLTFMaterialShader], limit: Int?) async throws -> VRMEntity {
            let entity = try await VRMEntityLoader(vrm: try VRM(data: TestSupport.seedSanData),
                                                   shaders: shaders,
                                                   maxTextureDimension: limit).loadEntity()
            // Meshes and textures reach the GPU when something draws them, not when they
            // are built, so the model has to be rendered once before it is measured.
            _ = try OffscreenRenderer.render(entity, size: 64)
            return entity
        }

        // Kept alive so each reading is what that load added rather than what it added
        // minus what the one before it released. The first also pays the one-time costs.
        let document = try VRM(data: TestSupport.seedSanData).document
        let sizes = document.gltf.images.indices.compactMap { index -> String? in
            guard let image = try? document.image(at: index) else { return nil }
            return "\(image.width)x\(image.height)"
        }
        print("BENCH gpu authored images: \(sizes.joined(separator: ", "))")

        var held: [VRMEntity] = []
        held.append(try await load(shaders: GLTFEntityLoader.defaultShaders, limit: nil))

        for (label, shaders, limit) in [
            ("outlines", GLTFEntityLoader.defaultShaders, nil),
            ("no outlines", [MToonShader(outlinePass: .never)] as [any GLTFMaterialShader], nil),
            ("2048 textures", GLTFEntityLoader.defaultShaders, 2048),
            ("1024 textures", GLTFEntityLoader.defaultShaders, 1024),
        ] {
            let before = device.currentAllocatedSize
            held.append(try await load(shaders: shaders, limit: limit))
            let megabytes = Double(device.currentAllocatedSize - before) / 1024 / 1024
            print(String(format: "BENCH gpu %-14@ %6.1f MB", label as NSString, megabytes))
        }
        withExtendedLifetime(held) {}
    }

    // MARK: - The per-frame update a tracked model pays

    /// What ``VRMEntity/update(deltaTime:)`` costs a model a face tracker drives.
    ///
    /// The cases differ only in what the app tells the model, which is what decides how
    /// much of the skin re-solves: nothing invalidated (`idle`), the whole skin
    /// invalidated with nothing moved (`held coarse`) or with one bone moved
    /// (`head coarse`), and the same bone invalidated through
    /// ``GLTFEntity/invalidateSkinPose(for:)`` (`head narrow`).
    @Test
    func benchmarkTrackedUpdate() async throws {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }

        /// Springs settled, so the cases differ in what the app asks for rather than in
        /// how much of the initial swing is left over.
        func loadSettled() async throws -> VRMEntity {
            let entity = try await VRMEntityLoader(withData: TestSupport.seedSanData).loadEntity()
            entity.isAutomaticUpdateEnabled = false
            for _ in 0..<600 { entity.update(deltaTime: 1.0 / 60.0) }
            return entity
        }

        /// A head that keeps moving, as a tracker delivering a new sample every frame poses it.
        func headDriver(_ entity: VRMEntity) throws -> (Entity, () -> simd_quatf) {
            let head = try #require(entity.humanoid.node(for: .head))
            let rest = head.transform.rotation
            var tick: Float = 0
            return (head, {
                tick += 0.01
                return rest * simd_quatf(angle: sin(tick) * 0.05, axis: SIMD3<Float>(1, 0, 0))
            })
        }

        let idle = try await loadSettled()
        report("idle", microsecondsPerUpdate {
            idle.update(deltaTime: 1.0 / 60.0)
        })

        // The springs step at a fixed 60 Hz, so a renderer drawing slower runs several
        // steps per update, where anything read per step rather than per update is paid
        // again. 1/30 s is two steps.
        let idle30 = try await loadSettled()
        report("idle 30fps", microsecondsPerUpdate {
            idle30.update(deltaTime: 1.0 / 30.0)
        })

        let held = try await loadSettled()
        report("held coarse", microsecondsPerUpdate {
            held.invalidateSkinPose()
            held.update(deltaTime: 1.0 / 60.0)
        })

        let coarse = try await loadSettled()
        let (coarseHead, coarseRotation) = try headDriver(coarse)
        report("head coarse", microsecondsPerUpdate {
            coarseHead.transform.rotation = coarseRotation()
            coarse.invalidateSkinPose()
            coarse.update(deltaTime: 1.0 / 60.0)
        })

        let narrow = try await loadSettled()
        let (narrowHead, narrowRotation) = try headDriver(narrow)
        report("head narrow", microsecondsPerUpdate {
            narrowHead.transform.rotation = narrowRotation()
            narrow.invalidateSkinPose(for: CollectionOfOne(narrowHead))
            narrow.update(deltaTime: 1.0 / 60.0)
        })

        // What an app running IK pays: every humanoid bone written every frame, differing
        // only in whether it can say which bones it wrote.
        func boneDriver(_ entity: VRMEntity) -> ([Entity], () -> simd_quatf) {
            let bones = HumanoidBone.allCases.compactMap { entity.humanoid.node(for: $0) }
            var tick: Float = 0
            return (bones, {
                tick += 0.01
                return simd_quatf(angle: sin(tick) * 0.05, axis: SIMD3<Float>(1, 0, 0))
            })
        }

        let bodyCoarse = try await loadSettled()
        let (coarseBones, coarseBoneRotation) = boneDriver(bodyCoarse)
        report("body coarse", microsecondsPerUpdate {
            let rotation = coarseBoneRotation()
            for bone in coarseBones { bone.transform.rotation = rotation }
            bodyCoarse.invalidateSkinPose()
            bodyCoarse.update(deltaTime: 1.0 / 60.0)
        })

        let bodyNarrow = try await loadSettled()
        let (narrowBones, narrowBoneRotation) = boneDriver(bodyNarrow)
        print("BENCH   (humanoid bones driven: \(narrowBones.count))")
        report("body narrow", microsecondsPerUpdate {
            let rotation = narrowBoneRotation()
            for bone in narrowBones { bone.transform.rotation = rotation }
            bodyNarrow.invalidateSkinPose(for: narrowBones)
            bodyNarrow.update(deltaTime: 1.0 / 60.0)
        })

        // `Entity.transform` is a computed property over `TransformComponent`, so
        // assigning members one at a time is a get-modify-set, and a world-transform
        // invalidation of the subtree, per member.
        let resting = try await loadSettled()
        let restBones = HumanoidBone.allCases.compactMap { resting.humanoid.node(for: $0) }
        let restPoses = restBones.map(\.transform)
        report("rest 2 writes", microsecondsPerUpdate {
            for (bone, rest) in zip(restBones, restPoses) {
                bone.transform.rotation = rest.rotation
                bone.transform.translation = rest.translation
            }
        })
        report("rest 1 write", microsecondsPerUpdate {
            for (bone, rest) in zip(restBones, restPoses) {
                var transform = bone.transform
                transform.rotation = rest.rotation
                transform.translation = rest.translation
                bone.transform = transform
            }
        })
        report("rest skip unchanged", microsecondsPerUpdate {
            for (bone, rest) in zip(restBones, restPoses) {
                var transform = bone.transform
                guard transform.rotation.vector != rest.rotation.vector
                    || transform.translation != rest.translation else { continue }
                transform.rotation = rest.rotation
                transform.translation = rest.translation
                bone.transform = transform
            }
        })

        // Every skeleton is drawn by a model entity and its outline twin, each carrying
        // its own `SkeletalPosesComponent`: what the second write per skeleton costs.
        let bare = try await VRMEntityLoader(withData: TestSupport.seedSanData,
                                             shaders: [MToonShader(outlinePass: .never)]).loadEntity()
        bare.isAutomaticUpdateEnabled = false
        for _ in 0..<600 { bare.update(deltaTime: 1.0 / 60.0) }
        print("BENCH   (skin bindings: \(coarse.skinBindings.count) with outlines,"
              + " \(bare.skinBindings.count) without)")
        let (bareHead, bareRotation) = try headDriver(bare)
        report("head no outline", microsecondsPerUpdate {
            bareHead.transform.rotation = bareRotation()
            bare.invalidateSkinPose()
            bare.update(deltaTime: 1.0 / 60.0)
        })
    }

    private func report(_ label: String, _ microseconds: Double) {
        print(String(format: "BENCH update %-12@ %7.1f µs/frame", label as NSString, microseconds))
    }

    /// Times the per-frame update on its own. A render behind it costs more than the
    /// update and varies by more than the differences measured here.
    private func microsecondsPerUpdate(frames requested: Int = 4000, _ body: () -> Void) -> Double {
        let frames = ProcessInfo.processInfo.environment["VRMKIT_BENCH_FRAMES"].flatMap(Int.init) ?? requested
        for _ in 0..<(frames / 4) { body() }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<frames { body() }
        return (CFAbsoluteTimeGetCurrent() - start) * 1_000_000 / Double(frames)
    }
}
#endif
