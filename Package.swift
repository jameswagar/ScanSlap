// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanSlap",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanSlapCore", targets: ["ScanSlapCore"]),
        .executable(name: "ScanSlap", targets: ["ScanSlap"]),
        .executable(name: "ScanSlapCoreSpec", targets: ["ScanSlapCoreSpec"])
    ],
    targets: [
        .target(name: "ScanSlapCore"),
        .executableTarget(name: "ScanSlap", dependencies: ["ScanSlapCore"]),
        .executableTarget(name: "ScanSlapCoreSpec", dependencies: ["ScanSlapCore"])
    ]
)
