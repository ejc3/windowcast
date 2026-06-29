// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "windowcast",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "windowcast", path: "Sources/windowcast")
    ]
)
