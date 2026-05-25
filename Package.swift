// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tinyClicker",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "tinyClicker",
            path: "Sources/tinyClicker"
        )
    ]
)
