// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "SwiftIRC",
    products: [
        .library(name: "SwiftIRC", targets: ["SwiftIRC"])
    ],
    targets: [
        .target(name: "SwiftIRC"),
        .testTarget(name: "SwiftIRCTests", dependencies: ["SwiftIRC"])
    ]
)
