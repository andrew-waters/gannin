// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GanninRemote",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "GanninRemote", targets: ["GanninRemote"]),
    ],
    targets: [
        .target(name: "GanninRemote"),
        .testTarget(name: "GanninRemoteTests", dependencies: ["GanninRemote"]),
    ]
)
