// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TrackpadKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrackpadKit", targets: ["TrackpadKit"])
    ],
    targets: [
        .target(name: "TrackpadKit"),
        .executableTarget(
            name: "gesture-lab",
            dependencies: ["TrackpadKit"]
        ),
        .testTarget(
            name: "TrackpadKitTests",
            dependencies: ["TrackpadKit"]
        )
    ]
)
