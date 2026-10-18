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
        // CryptoKit's API everywhere (it is CryptoKit itself on Apple platforms); SHA-256 for sign-in.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        // Pure logic, no dependencies.
        .target(name: "TaskCore"),
        // SQLite persistence for TaskCore's models.
        .target(name: "TaskStore", dependencies: [
            "TaskCore",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "TaskCoreTests", dependencies: ["TaskCore"]),
        .testTarget(name: "TaskStoreTests", dependencies: ["TaskStore"]),
    ]
)
