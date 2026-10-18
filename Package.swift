// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacEven",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacEvenCore", targets: ["MacEvenCore"]),
        .executable(name: "MacEven", targets: ["MacEven"]),
        .executable(name: "MacEvenProbe", targets: ["MacEvenProbe"])
    ],
    targets: [
        .target(name: "MacEvenCore", resources: [.process("Resources")], swiftSettings: [.unsafeFlags(["-enable-testing"])], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "MacEven", dependencies: ["MacEvenCore"]),
        .executableTarget(name: "MacEvenProbe", dependencies: ["MacEvenCore"]),
        .executableTarget(name: "MacEvenDuplicateProbe", dependencies: ["MacEvenCore"]),
        .executableTarget(name: "MacEvenMonitorProbe", dependencies: ["MacEvenCore"]),
        .executableTarget(name: "MacEvenMonitorChecks", dependencies: ["MacEvenCore"], path: "Tests/MacEvenMonitorChecks"),
        .executableTarget(name: "MacEvenChecks", dependencies: ["MacEvenCore"], path: "Tests/MacEvenCoreTests")
    ]
)
