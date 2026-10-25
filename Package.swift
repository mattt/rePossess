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
        .testTarget(name: "RePossessFormatTests", dependencies: ["RePossessFormat"], exclude: ["Fixtures"]),
        .testTarget(name: "RePossessCloudTests", dependencies: ["RePossessCloud"]),
        .testTarget(name: "RePossessUSBTests", dependencies: ["RePossessUSB"]),
        .testTarget(
            name: "RePossessLibraryTests",
            dependencies: ["RePossessLibrary", "RePossessFormat", "RePossessCloud", "RePossessUSB"]
        ),
    ]
)
