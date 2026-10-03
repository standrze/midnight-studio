// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "midnight-studio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "midnight-studio", targets: ["MidnightInspector"])],
    dependencies: [
        .package(url: "https://github.com/standrze/loom.git", exact: "0.1.1"),
        .package(url: "https://github.com/standrze/weft.git", exact: "0.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "MidnightInspector",
            dependencies: [.product(name: "loom", package: "loom"), .product(name: "weft", package: "weft")]
        ),
        .testTarget(
            name: "MidnightInspectorTests",
            dependencies: ["MidnightInspector", .product(name: "loom", package: "loom")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
