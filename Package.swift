// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "gesture-lab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "gesture-lab",
            path: "Sources/gesture-lab"
        )
    ]
)
