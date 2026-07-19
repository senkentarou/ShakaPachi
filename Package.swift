// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CmdTab",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CmdTab",
            path: "Sources/CmdTab"
        ),
        .testTarget(
            name: "CmdTabTests",
            dependencies: ["CmdTab"],
            path: "Tests/CmdTabTests"
        )
    ]
)
