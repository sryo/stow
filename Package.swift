// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Stow",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        // Shared library for cross-platform code
        .library(name: "StowShared", targets: ["StowShared"]),
        // Core library for macOS (includes StowShared)
        .library(name: "StowCore", targets: ["StowCore"]),
        // Executable for development/testing
        .executable(name: "Stow", targets: ["StowApp"])
    ],
    targets: [
        // Shared cross-platform library (Foundation-only, no AppKit/UIKit)
        .target(name: "StowShared"),
        // macOS-specific library (AppKit UI + re-exports StowShared)
        .target(
            name: "StowCore",
            dependencies: ["StowShared"]
        ),
        // Minimal executable entry point
        .executableTarget(
            name: "StowApp",
            dependencies: ["StowCore"]
        ),
        .testTarget(
            name: "StowSharedTests",
            dependencies: ["StowShared"]
        ),
        .testTarget(
            name: "StowTests",
            dependencies: ["StowCore"]
        )
    ]
)
