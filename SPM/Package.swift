// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FBSimulatorControlSPM",
    platforms: [.macOS(.v14)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SimulatorControl",
            targets: ["SimulatorControl"]),
//        .library(
//            name: "FBSimulatorControl",
//            targets: ["FBSimulatorControl"]
//        ),
    ],
    targets: [
        .target(name: "SimulatorControl", path: "sources/SimulatorControl"),
        .binaryTarget(name: "FBSimulatorControl", path: "xcframeworks/FBSimulatorControl.xcframework")
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
//        .target(
//            name: "FBSimulatorControlSPM",
//            dependencies: [
//                "FBControlCoreSPM"
//            ],
//            path: "FBSimulatorControl/",
//            exclude: [
//                "FBSimulatorControl-Info.plist"
//            ],
//            publicHeadersPath: ".",
//            cSettings: [
//                .headerSearchPath("../FBSimulatorControl/**"),
//                .headerSearchPath("../FBControlCore"),
//                .headerSearchPath("../PrivateHeaders/CoreSimulator"),
//                .headerSearchPath("../PrivateHeaders/SimulatorApp"),
//            ]
//        ),
//        .target(
//            name: "FBControlCoreSPM",
//            path: "FBControlCore/spm/",
//            publicHeadersPath: ".",
//            cSettings: [
//                .headerSearchPath("."),
//                .headerSearchPath(".."),
//                .headerSearchPath("Headers"),
//                .headerSearchPath("FBControlCore"),
//                .headerSearchPath("FBControlCore/Applications"),
//                .headerSearchPath("FBControlCore/Async"),
//                .headerSearchPath("FBControlCore/Codesigning"),
//                .headerSearchPath("FBControlCore/Commands"),
//                .headerSearchPath("FBControlCore/Configuration"),
//                .headerSearchPath("FBControlCore/Crashes"),
//                .headerSearchPath("FBControlCore/Management"),
//                .headerSearchPath("FBControlCore/Processes"),
//                .headerSearchPath("FBControlCore/Reporting"),
//                .headerSearchPath("FBControlCore/Sockets"),
//                .headerSearchPath("FBControlCore/Tasks"),
//                .headerSearchPath("FBControlCore/Utility"),
//                .headerSearchPath("PrivateHeaders/CoreSimulator"),
//                .headerSearchPath("PrivateHeaders/AXRuntime")
//            ]
//        )
    ]
)
