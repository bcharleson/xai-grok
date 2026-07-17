// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrokChat",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Grok",
            targets: ["GrokChat"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "GrokChat",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "GrokChatTests",
            dependencies: ["GrokChat"],
            path: "Tests"
        )
    ]
)

