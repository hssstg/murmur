// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "murmur",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "LocalPackages/SherpaOnnx"),
    ],
    targets: [
        .executableTarget(
            name: "murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/App",
            resources: [.process("Resources")]
        ),
        .target(
            name: "MurmurCore",
            dependencies: [
                .product(name: "CSherpaOnnx", package: "SherpaOnnx"),
            ],
            path: "Sources/MurmurCore"
        ),
        .executableTarget(
            name: "MurmurTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurTests"
        ),
        .executableTarget(
            name: "BenchmarkASR",
            dependencies: [
                "MurmurCore",
                .product(name: "CSherpaOnnx", package: "SherpaOnnx"),
            ],
            path: "Sources/BenchmarkASR"
        ),
    ]
)
