// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "VRMKit",
    platforms: [.iOS(.v15), .watchOS(.v8)],
    products: [
        .library(name: "VRMKit", targets: ["VRMKit"]),
        .library(name: "VRMSceneKit", targets: ["VRMSceneKit"])
    ],
    targets: [
        .target(name: "VRMKit"),
        .target(
            name: "VRMSceneKit",
            dependencies: ["VRMKit"]
        ),

        .testTarget(
            name: "VRMKitTests",
            dependencies: ["VRMKit"],
            resources: [.copy("Assets/AliciaSolid.vrm"), .copy("Assets/Seed-san.vrm")]
        ),
        .testTarget(
            name: "VRMSceneKitTests",
            dependencies: ["VRMSceneKit"],
            resources: [.copy("Assets/AliciaSolid.vrm"), .copy("Assets/Seed-san.vrm")]
        ),
    ]
)
