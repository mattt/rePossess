// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "rePossess",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "RePossessFormat", targets: ["RePossessFormat"]),
        .library(name: "RePossessCloud", targets: ["RePossessCloud"]),
        .library(name: "RePossessUSB", targets: ["RePossessUSB"]),
        .library(name: "RePossessLibrary", targets: ["RePossessLibrary"]),
        .library(name: "RePossessRender", targets: ["RePossessRender"]),
        .library(name: "RePossessRecognize", targets: ["RePossessRecognize"]),
        .library(name: "RePossessMCP", targets: ["RePossessMCP"]),
        .executable(name: "repossess", targets: ["repossess"]),
        // The menu bar app's executable; `mise run build:app` puts it in rePossess.app with `repossess`.
        .executable(name: "RePossessApp", targets: ["RePossessApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // Handwriting recognition through configurable providers (Mattt, 2026-10-25).
        // Only the MLX trait: the system model and the cloud providers need no trait.
        .package(url: "https://github.com/huggingface/AnyLanguageModel.git", exact: "1.1.0", traits: ["MLX"]),
    ],
    targets: [
        .target(
            name: "RePossessFormat",
            exclude: ["RMScene/LICENSE-rmscene"]
        ),
        .target(name: "RePossessCloud"),
        .target(name: "RePossessUSB"),
        .target(
            name: "RePossessLibrary",
            dependencies: ["RePossessFormat", "RePossessCloud", "RePossessUSB"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "RePossessRender",
            dependencies: ["RePossessFormat"]
        ),
        .target(
            name: "RePossessRecognize",
            dependencies: [
                "RePossessFormat",
                "RePossessCloud",
                "RePossessLibrary",
                "RePossessRender",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
        .target(
            name: "RePossessMCP",
            dependencies: [
                "RePossessFormat",
                "RePossessCloud",
                "RePossessUSB",
                "RePossessLibrary",
                "RePossessRender",
                "RePossessRecognize",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "repossess",
            dependencies: [
                "RePossessFormat",
                "RePossessCloud",
                "RePossessUSB",
                "RePossessLibrary",
                "RePossessRender",
                "RePossessRecognize",
                "RePossessMCP",
            ]
        ),
        .target(
            name: "RePossessAppCore",
            dependencies: [
                "RePossessCloud",
                "RePossessUSB",
                "RePossessLibrary",
                "RePossessRecognize",
                "RePossessMCP",
            ]
        ),
        .executableTarget(name: "RePossessApp", dependencies: ["RePossessAppCore"]),
        .testTarget(name: "RePossessFormatTests", dependencies: ["RePossessFormat"], exclude: ["Fixtures"]),
        .testTarget(name: "RePossessCloudTests", dependencies: ["RePossessCloud"]),
        .testTarget(name: "RePossessUSBTests", dependencies: ["RePossessUSB"]),
        .testTarget(
            name: "RePossessLibraryTests",
            dependencies: ["RePossessLibrary", "RePossessFormat", "RePossessCloud", "RePossessUSB"]
        ),
        .testTarget(name: "RePossessRenderTests", dependencies: ["RePossessRender", "RePossessFormat"]),
        .testTarget(
            name: "RePossessRecognizeTests",
            dependencies: ["RePossessRecognize", "RePossessLibrary", "RePossessFormat", "RePossessRender"]
        ),
        .testTarget(
            name: "RePossessMCPTests",
            dependencies: [
                "RePossessMCP",
                "RePossessLibrary",
                "RePossessFormat",
                "RePossessUSB",
                "RePossessRecognize",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "RePossessAppCoreTests",
            dependencies: [
                "RePossessAppCore",
                "RePossessLibrary",
                "RePossessCloud",
                "RePossessUSB",
                "RePossessRecognize",
                "RePossessMCP",
            ]
        ),
    ]
)
