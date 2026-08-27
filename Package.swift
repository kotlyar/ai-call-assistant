// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Callya",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AICallAssistant", targets: ["AICallAssistant"])
    ],
    targets: [
        .executableTarget(
            name: "AICallAssistant",
            path: "Sources/AICallAssistant"
        ),
        .testTarget(
            name: "AICallAssistantTests",
            dependencies: ["AICallAssistant"],
            path: "Tests/AICallAssistantTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
