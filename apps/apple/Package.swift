// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KubecodeApple",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KubecodeKit", targets: ["KubecodeKit"]),
        .library(name: "KubecodeCore", targets: ["KubecodeCore"]),
        .library(name: "KubecodeMacRuntime", targets: ["KubecodeMacRuntime"]),
        .library(name: "KubecodeUI", targets: ["KubecodeUI"]),
        .executable(name: "Kubecode", targets: ["KubecodeApp"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(path: "Vendor/STTextView"),
        .package(path: "Vendor/SwiftMath"),
    ],
    targets: [
        .target(
            name: "KubecodeKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KubecodeCore",
            dependencies: ["KubecodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KubecodeMacRuntime",
            dependencies: ["KubecodeKit", "KubecodeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KubecodeUI",
            dependencies: ["KubecodeKit", "KubecodeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "KubecodeApp",
            dependencies: [
                "KubecodeKit",
                "KubecodeCore",
                "KubecodeMacRuntime",
                "KubecodeUI",
                "SwiftTerm",
                "SwiftMath",
                .product(name: "STTextView", package: "STTextView"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KubecodeKitTests",
            dependencies: ["KubecodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KubecodeCoreTests",
            dependencies: ["KubecodeCore", "KubecodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KubecodeMacRuntimeTests",
            dependencies: ["KubecodeMacRuntime", "KubecodeCore", "KubecodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KubecodeUITests",
            dependencies: ["KubecodeUI", "KubecodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KubecodeAppTests",
            dependencies: ["KubecodeApp", "KubecodeUI", "KubecodeMacRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
