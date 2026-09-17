// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenLedger",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenLedgerCore", targets: ["TokenLedgerCore"]),
        .executable(name: "tok", targets: ["tok"]),
        .executable(name: "TokenLedgerApp", targets: ["TokenLedgerApp"]),
    ],
    targets: [
        .target(name: "TokenLedgerCore", path: "Sources/TokenLedgerCore"),
        .target(name: "TokenLedgerUI", dependencies: ["TokenLedgerCore"], path: "Sources/TokenLedgerUI"),
        .target(name: "FSEventsBridge", path: "Sources/FSEventsBridge"),
        .executableTarget(name: "tok", dependencies: ["TokenLedgerCore"], path: "Sources/tok"),
        .executableTarget(name: "TokenLedgerApp", dependencies: ["TokenLedgerCore", "TokenLedgerUI", "FSEventsBridge"], path: "Sources/TokenLedgerApp"),
        .testTarget(name: "TokenLedgerCoreTests", dependencies: ["TokenLedgerCore", "TokenLedgerUI"], path: "Tests/TokenLedgerCoreTests"),
    ]
)
