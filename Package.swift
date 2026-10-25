// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VRMKit",
    platforms: [.iOS(.v15), .macOS(.v12), .watchOS(.v8), .visionOS(.v2)],
    products: [
        .library(name: "VRMKit", targets: ["VRMKit"]),
        // The asset, the instance and its frame outputs, for an app drawing a model with its own renderer.
        .library(name: "VRMKitRuntime", targets: ["VRMKitRuntime"]),
        .library(name: "VRMRealityKit", targets: ["VRMRealityKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/tattn/swift-simd-compat", from: "0.1.0")
    ],
    targets: [
        // VRMKit and VRMKitRuntime also build where Apple's `simd` is unavailable (e.g. Android),
        // so they import `SIMDCompat`, which is `simd` itself on Apple platforms.
        .target(
            name: "VRMKit",
            dependencies: [.product(name: "SIMDCompat", package: "swift-simd-compat")],
            exclude: ["Extensions/MoreCodable/LICENSE"],
            // Warnings go to logcat on Android, where there is no OSLog.
            linkerSettings: [.linkedLibrary("log", .when(platforms: [.android]))]
        ),
        .target(
            name: "VRMKitRuntime",
            dependencies: ["VRMKit", .product(name: "SIMDCompat", package: "swift-simd-compat")]
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
            dependencies: ["VRMKit", .product(name: "SIMDCompat", package: "swift-simd-compat")],
            path: "Tests/VRMTestSupport",
            resources: [
                .copy("../Assets/GLTF"),
                .copy("../Assets/VRM"),
                .copy("../Assets/VRMA")
            ]
        ),

        .testTarget(
            name: "VRMKitTests",
            dependencies: ["VRMKit", "VRMTestSupport", .product(name: "SIMDCompat", package: "swift-simd-compat")]
        ),
        .testTarget(
            name: "VRMKitRuntimeTests",
            dependencies: ["VRMKit", "VRMKitRuntime", "VRMTestSupport", .product(name: "SIMDCompat", package: "swift-simd-compat")]
        ),
        .testTarget(
            name: "VRMRealityKitTests",
            dependencies: ["VRMRealityKit", "VRMTestSupport"]
        ),
        // Opt-in measurements (`VRMKIT_BENCH=1`), kept out of the regular test target.
        .testTarget(
            name: "VRMRealityKitBenchmarks",
            dependencies: ["VRMRealityKit", "VRMTestSupport"]
        ),
    ]
)
