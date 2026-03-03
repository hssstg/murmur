// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "murmur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/App"
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
