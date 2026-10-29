// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reclaim",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ReclaimCore", targets: ["ReclaimCore"]),
        .executable(name: "reclaim", targets: ["reclaim"]),
        .executable(name: "ReclaimApp", targets: ["ReclaimApp"]),
    ],
    targets: [
        .target(name: "ReclaimCore"),
        .executableTarget(name: "reclaim", dependencies: ["ReclaimCore"]),
        .executableTarget(name: "ReclaimApp", dependencies: ["ReclaimCore"]),
        .testTarget(name: "ReclaimCoreTests", dependencies: ["ReclaimCore"]),
        .testTarget(name: "ReclaimAppTests", dependencies: ["ReclaimApp", "ReclaimCore"]),
    ]
)
