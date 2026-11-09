// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RecBar",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "RecBar", targets: ["RecBar"]),
        .library(name: "RecBarCore", targets: ["RecBarCore"])
    ],
    targets: [
        .target(
            name: "RecBarCore",
            path: "Sources/RecBarCore"
        ),
        .executableTarget(
            name: "RecBar",
            dependencies: ["RecBarCore"],
            path: "Sources/RecBar"
        )
    ]
)
