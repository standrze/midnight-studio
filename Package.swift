// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "MidnightStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "midnight-studio", targets: ["MidnightInspector"]),
        .executable(name: "midnight-inspector", targets: ["MidnightInspector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/standrze/loom.git", exact: "0.1.1"),
        .package(url: "https://github.com/standrze/weft.git", exact: "0.1.1"),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.26.0",
            traits: []
        ),
    ],
    targets: [
        .target(
            name: "StudioResources", path: "Sources/MidnightInspector/Resources", sources: ["ResourceBundle.swift"],
            resources: [
                .process("app.js"), .process("controls.css"), .process("controls.html"), .process("controls.js"),
                .process("favicon.svg"), .process("index.html"), .process("midnight-mark.svg"), .process("prepare.css"),
                .process("prepare.html"), .process("prepare.js"), .process("styles.css"),
            ]),
        .executableTarget(
            name: "MidnightInspector",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "loom", package: "loom"),
                .product(name: "weft", package: "weft"),
                "StudioResources",
            ],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MidnightInspectorTests",
            dependencies: [
                "MidnightInspector",
                .product(name: "loom", package: "loom"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
