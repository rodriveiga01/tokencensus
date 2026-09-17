// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenCensus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenCensusCore", targets: ["TokenCensusCore"]),
        .executable(name: "tok", targets: ["tok"]),
        .executable(name: "TokenCensusApp", targets: ["TokenCensusApp"]),
    ],
    targets: [
        .target(name: "TokenCensusCore", path: "Sources/TokenCensusCore"),
        .target(name: "TokenCensusUI", dependencies: ["TokenCensusCore"], path: "Sources/TokenCensusUI"),
        .target(name: "FSEventsBridge", path: "Sources/FSEventsBridge"),
        .executableTarget(name: "tok", dependencies: ["TokenCensusCore"], path: "Sources/tok"),
        .executableTarget(name: "TokenCensusApp", dependencies: ["TokenCensusCore", "TokenCensusUI", "FSEventsBridge"], path: "Sources/TokenCensusApp"),
        .testTarget(name: "TokenCensusTests", dependencies: ["TokenCensusCore", "TokenCensusUI"], path: "Tests/TokenCensusTests"),
    ]
)
