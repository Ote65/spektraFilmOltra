// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SpektraSkin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpektraFilm", targets: ["SpektraSkin"])
    ],
    targets: [
        .executableTarget(
            name: "SpektraSkin",
            path: "Sources/SpektraSkin",
            resources: [.process("Resources")]
        )
    ]
)
