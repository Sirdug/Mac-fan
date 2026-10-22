// swift-tools-version: 6.0

import PackageDescription

// Swift 5 language mode: the SMC/IOKit layer and daemon use patterns
// (C structs, NSLock, signal handlers) that fight Swift 6 strict concurrency.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "MacFan",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "MacFanCore",
            path: "Sources/MacFanCore",
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "macfan",
            dependencies: ["MacFanCore"],
            path: "Sources/macfan",
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "MacFanApp",
            dependencies: ["MacFanCore"],
            path: "Sources/MacFanApp",
            swiftSettings: swift5
        ),
        .testTarget(
            name: "MacFanTests",
            dependencies: ["MacFanCore"],
            path: "Tests/MacFanTests",
            swiftSettings: swift5
        ),
    ]
)
