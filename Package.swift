// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "VRMKit",
    platforms: [.iOS(.v14)],
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
            exclude: ["Info.plist"],
            resources: [.copy("Assets/AliciaSolid.vrm")]
        ),
        .testTarget(
            name: "VRMSceneKitTests",
            dependencies: ["VRMSceneKit"],
            exclude: ["Info.plist"],
            resources: [.copy("Assets/AliciaSolid.vrm")]
        ),
    ]
)
