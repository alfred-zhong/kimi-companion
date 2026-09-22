// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "kimi-companion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "kimi-companion", targets: ["kimi-companion"])
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "kimi-companion",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            path: "Sources/kimi-companion"
        ),

    ]
)
