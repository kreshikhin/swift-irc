// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "SwiftIRC",
    products: [
        .library(name: "SwiftIRCCore", targets: ["SwiftIRCCore"]),
        .library(name: "SwiftIRCClient", targets: ["SwiftIRCClient"]),
        .library(name: "SwiftIRCServer", targets: ["SwiftIRCServer"])
    ],
    targets: [
        .target(name: "SwiftIRCCore"),
        .target(name: "SwiftIRCClient", dependencies: ["SwiftIRCCore"]),
        .target(name: "SwiftIRCServer", dependencies: ["SwiftIRCCore"]),
        .testTarget(name: "SwiftIRCCoreTests", dependencies: ["SwiftIRCCore"]),
        .testTarget(
            name: "SwiftIRCClientTests",
            dependencies: ["SwiftIRCClient", "SwiftIRCCore"]
        ),
        .testTarget(
            name: "SwiftIRCServerTests",
            dependencies: ["SwiftIRCServer", "SwiftIRCClient", "SwiftIRCCore"]
        )
    ]
)
