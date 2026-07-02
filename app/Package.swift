// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ContextLayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ContextLayer", path: "Sources/ContextLayer")
    ]
)
