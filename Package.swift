// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sill",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SillCore", targets: ["SillCore"]),
        .executable(name: "Sill", targets: ["SillApp"]),
        .executable(name: "sillctl", targets: ["sillctl"])
    ],
    targets: [
        .target(name: "SillCore"),
        .executableTarget(name: "SillApp", dependencies: ["SillCore"]),
        .executableTarget(name: "sillctl", dependencies: ["SillCore"]),
        .executableTarget(name: "SillChecks", dependencies: ["SillCore"], path: "Tests/SillCoreTests")
    ]
)
