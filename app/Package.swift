// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ContextLayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ContextLayer",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ContextLayer",
            linkerSettings: [
                // Sparkle.framework lives in Contents/Frameworks in the .app;
                // for bare dev binaries it sits next to the executable.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]),
    ]
)
