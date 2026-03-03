// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "murmur",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/App",
            resources: [.process("Resources")]
        ),
        .target(
            name: "MurmurCore",
            path: "Sources/MurmurCore"
        ),
        .executableTarget(
            name: "MurmurTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurTests"
        ),
    ]
)
