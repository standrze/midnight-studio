// swift-tools-version: 6.3

import PackageDescription

// These revisions match the Midnight runtime. The web package deliberately
// does not depend on this native package or any MLX products.
#if os(macOS)
let backendSwiftSettings: [SwiftSetting] = [.define("MLX_METAL_BACKEND")]
#elseif os(Linux)
let backendSwiftSettings: [SwiftSetting] = Context.environment["SPM_CUDA"] == "0"
    ? [.define("MLX_CPU_BACKEND")]
    : [.define("MLX_CUDA_BACKEND")]
#else
let backendSwiftSettings: [SwiftSetting] = [.define("MLX_CPU_BACKEND")]
#endif

#if os(Linux)
let mlxSwiftDependency: Package.Dependency = .package(
    url: "https://github.com/ml-explore/mlx-swift",
    revision: "2d2724006b62855c6c2a71df633baf4ee4ad8a0f"
)
#else
let mlxSwiftDependency: Package.Dependency = .package(
    url: "https://github.com/ml-explore/mlx-swift",
    revision: "72f3c3ad8aeee39bfc94f8fbeb446cac89e3a798"
)
#endif

let package = Package(
    name: "MidnightStudioWorkers",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "midnight-studio-worker", targets: ["StudioWorker"])],
    dependencies: [
        .package(name: "Midnight", path: Context.environment["MIDNIGHT_RUNTIME_PATH"] ?? "../../midnight"),
        mlxSwiftDependency,
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",
                 revision: "14414441fa44f45eee35a61e9fa0bab577cf9734", traits: []),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        .executableTarget(name: "StudioWorker", dependencies: [
            .product(name: "ModelRunnerCore", package: "Midnight"),
            .product(name: "ModelRunnerProtocol", package: "Midnight"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXOptimizers", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ], swiftSettings: backendSwiftSettings),
        .testTarget(name: "StudioWorkerTests", dependencies: [
            "StudioWorker",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
