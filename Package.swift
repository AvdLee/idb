// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FBSimulatorControlSPM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FBSimulatorControl", targets: ["FBSimulatorControl"]),
        .library(name: "FBControlCore", targets: ["FBControlCore"]),
        .library(name: "XCTestBootstrap", targets: ["XCTestBootstrap"])
    ],
    targets: [
        .binaryTarget(name: "FBSimulatorControl", path: "SPM/xcframeworks/FBSimulatorControl.xcframework"),
        .binaryTarget(name: "FBControlCore", path: "SPM/xcframeworks/FBControlCore.xcframework"),
        .binaryTarget(name: "XCTestBootstrap", path: "SPM/xcframeworks/XCTestBootstrap.xcframework")
    ]
)
