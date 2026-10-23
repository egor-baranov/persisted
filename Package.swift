// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Persisted",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PersistedCore", targets: ["PersistedCore"]),
        .library(name: "PersistedPlatform", targets: ["PersistedPlatform"]),
        .executable(name: "Persisted", targets: ["Persisted"]),
        .executable(name: "PersistedHarness", targets: ["PersistedHarness"])
    ],
    targets: [
        .target(name: "PersistedCore"),
        .target(name: "PersistedSpacesBridge", linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("ApplicationServices")]),
        .target(name: "PersistedPlatform", dependencies: ["PersistedCore", "PersistedSpacesBridge"]),
        .executableTarget(name: "Persisted", dependencies: ["PersistedCore", "PersistedPlatform"]),
        .executableTarget(name: "PersistedHarness"),
        .testTarget(name: "PersistedCoreTests", dependencies: ["PersistedCore"])
    ]
)
