// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JiraSprint",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "JiraSprint",
            path: "Sources/JiraSprint"
        ),
    ]
)
