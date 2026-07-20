// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LazyStudio",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "LazyStudio",
            path: "Sources/LazyStudio"
        )
    ]
)
