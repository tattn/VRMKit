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
        .target(name: "VRMKit"),
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
            dependencies: ["VRMKit", "VRMKitRuntime"]
        ),

        .testTarget(
            name: "VRMKitTests",
            dependencies: ["VRMKit"],
            resources: [.copy("Assets/AliciaSolid.vrm"), .copy("Assets/Seed-san.vrm")]
        ),
        .testTarget(
            name: "VRMSceneKitTests",
            dependencies: ["VRMSceneKit"],
            resources: [.copy("../VRMKitTests/Assets/AliciaSolid.vrm"), .copy("../VRMKitTests/Assets/Seed-san.vrm")]
        ),
    ]
)
