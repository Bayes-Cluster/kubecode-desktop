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
        .library(name: "KubecodeMarkdown", targets: ["KubecodeMarkdown"]),
        .library(name: "KubecodeUI", targets: ["KubecodeUI"]),
        .library(name: "KubecodeMacUI", targets: ["KubecodeMacUI"]),
        .executable(name: "Kubecode", targets: ["KubecodeApp"]),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
        .package(path: "Vendor/STTextView"),
        .package(path: "Vendor/SwiftMath"),
        .package(path: "Vendor/SwiftMarkdown"),
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
            name: "KubecodeMarkdown",
            dependencies: [
                .product(name: "Markdown", package: "SwiftMarkdown"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KubecodeUI",
            dependencies: ["KubecodeKit", "KubecodeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "KubecodeMacUI",
            dependencies: ["KubecodeUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "KubecodeApp",
            dependencies: [
                "KubecodeKit",
                "KubecodeCore",
                "KubecodeMacRuntime",
                "KubecodeMarkdown",
                "KubecodeUI",
                "KubecodeMacUI",
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
            name: "KubecodeMarkdownTests",
            dependencies: ["KubecodeMarkdown"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KubecodeUITests",
            dependencies: ["KubecodeUI", "KubecodeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "KubecodeAppTests",
            dependencies: ["KubecodeApp", "KubecodeUI", "KubecodeMacUI", "KubecodeMacRuntime"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
