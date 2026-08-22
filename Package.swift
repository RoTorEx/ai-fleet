// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ai-fleet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ai-fleet",
            targets: ["AIFleet"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AIFleet",
            path: "Sources/AIFleet",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AIFleetTests",
            dependencies: ["AIFleet"],
            path: "Tests/AIFleetTests"
        )
    ]
)
