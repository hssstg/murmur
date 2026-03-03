// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "murmur",
    platforms: [.macOS(.v13)],
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
        .testTarget(
            name: "MurmurTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurTests"
        ),
    ]
)
