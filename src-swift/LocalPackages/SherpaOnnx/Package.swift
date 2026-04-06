// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SherpaOnnx",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CSherpaOnnx", targets: ["CSherpaOnnx"]),
    ],
    targets: [
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/sherpa-onnx.xcframework/macos-arm64_x86_64",
                    "-L\(Context.packageDirectory)/libs",
                ]),
                .linkedLibrary("sherpa-onnx"),
                .linkedLibrary("onnxruntime"),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
            ]
        ),
    ]
)
