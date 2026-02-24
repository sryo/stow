// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Stow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Library for bundler to use
        .library(name: "StowCore", targets: ["StowCore"]),
        // Executable for development/testing
        .executable(name: "Stow", targets: ["StowApp"])
    ],
    targets: [
        // Core library with all app logic
        .target(name: "StowCore"),
        // Minimal executable entry point
        .executableTarget(
            name: "StowApp",
            dependencies: ["StowCore"]
        ),
        .testTarget(
            name: "StowTests",
            dependencies: ["StowCore"]
        )
    ]
)
