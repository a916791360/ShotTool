// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShotTool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ShotTool", targets: ["ShotTool"])
    ],
    targets: [
        .executableTarget(
            name: "ShotTool",
            path: "Sources/ShotTool"
        )
    ]
)
