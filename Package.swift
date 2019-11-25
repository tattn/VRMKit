// swift-tools-version:5.1
import PackageDescription

let package = Package(
    name: "VRMKit",
    platforms: [.iOS(.v10)],
    products: [
        .library(name: "VRMKit", targets: ["VRMKit"]),
        .library(name: "VRMSceneKit", targets: ["VRMSceneKit"])
    ],
    targets: [
        .target(
            name: "VRMKit",
            path: "Sources/VRMKit"
        ),
        .target(
            name: "VRMSceneKit",
            dependencies: ["VRMKit"],
            path: "Sources/VRMSceneKit"
        )
    ]
)
