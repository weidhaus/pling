// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlingCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PlingCore", targets: ["PlingCore"]),
        .executable(name: "ntfy-e2e", targets: ["ntfy-e2e"]),
    ],
    targets: [
        .target(name: "PlingCore", resources: [.process("Resources")]),
        .executableTarget(name: "ntfy-e2e", dependencies: ["PlingCore"]),
        .testTarget(name: "PlingCoreTests", dependencies: ["PlingCore"]),
    ]
)
