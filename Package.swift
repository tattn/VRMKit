// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VRMKit",
    platforms: [.iOS(.v15), .macOS(.v12), .watchOS(.v8), .visionOS(.v2)],
    products: [
        .library(name: "VRMKit", targets: ["VRMKit"]),
        .library(name: "VRMSceneKit", targets: ["VRMSceneKit"]),
        .library(name: "VRMRealityKit", targets: ["VRMRealityKit"])
    ],
    targets: [
        .target(
            name: "VRMKit",
            exclude: ["Extensions/MoreCodable/LICENSE"]
        ),
        .target(
            name: "VRMKitRuntime",
            dependencies: ["VRMKit"]
        ),
        .target(
            name: "VRMSceneKit",
            dependencies: ["VRMKit", "VRMKitRuntime"]
        ),
        .target(
            name: "VRMRealityKit",
            dependencies: ["VRMKit", "VRMKitRuntime"],
            // Shaders/MToon.metal is compiled offline into the per-platform
            // metallibs under Resources by scripts/build-mtoon-metallibs.sh.
            exclude: ["Shaders"],
            resources: [.process("Resources")]
        ),

        // Test-only helpers shared by the test targets.
        .target(
            name: "VRMTestSupport",
            dependencies: ["VRMKit"],
            path: "Tests/VRMTestSupport",
            resources: [
                .copy("../Assets/GLTF"),
                .copy("../Assets/VRM"),
                .copy("../Assets/VRMA")
            ]
        ),

        .testTarget(
            name: "VRMKitTests",
            dependencies: ["VRMKit", "VRMTestSupport"]
        ),
        .testTarget(
            name: "VRMKitRuntimeTests",
            dependencies: ["VRMKit", "VRMKitRuntime"]
        ),
        .testTarget(
            name: "VRMSceneKitTests",
            dependencies: ["VRMSceneKit", "VRMTestSupport"]
        ),
        .testTarget(
            name: "VRMRealityKitTests",
            dependencies: ["VRMRealityKit", "VRMTestSupport"]
        ),
    ]
)
