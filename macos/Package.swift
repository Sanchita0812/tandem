// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TandemMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "TandemMac",
            targets: ["TandemMac"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TandemMac",
            dependencies: [],
            path: "Sources/TandemMac"
        )
    ]
)
