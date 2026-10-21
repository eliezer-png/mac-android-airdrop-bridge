// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacosAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacosAgent",
            path: "Sources/MacosAgent"
        )
    ]
)
