// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "rePossess",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .library(name: "RePossessFormat", targets: ["RePossessFormat"])
    ],
    targets: [
        .target(
            name: "RePossessFormat",
            exclude: ["RMScene/LICENSE-rmscene"]
        ),
        .testTarget(name: "RePossessFormatTests", dependencies: ["RePossessFormat"], exclude: ["Fixtures"]),
    ]
)
