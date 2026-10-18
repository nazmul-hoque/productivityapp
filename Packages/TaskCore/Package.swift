// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TaskCore", targets: ["TaskCore"]),
        .library(name: "TaskStore", targets: ["TaskStore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Pure logic, no dependencies.
        .target(name: "TaskCore"),
        // SQLite persistence for TaskCore's models.
        .target(name: "TaskStore", dependencies: ["TaskCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "TaskCoreTests", dependencies: ["TaskCore"]),
        .testTarget(name: "TaskStoreTests", dependencies: ["TaskStore"]),
    ]
)
