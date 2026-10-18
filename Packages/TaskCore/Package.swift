// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TaskCore", targets: ["TaskCore"]),
    ],
    targets: [
        .target(name: "TaskCore"),
        .testTarget(name: "TaskCoreTests", dependencies: ["TaskCore"]),
    ]
)
