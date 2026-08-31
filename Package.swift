// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Callya",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "AICallAssistant", targets: ["AICallAssistant"])
    ],
    targets: [
        .target(
            name: "CoreAudioTapCapture",
            path: "Sources/CoreAudioTapCapture",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "AICallAssistant",
            dependencies: ["CoreAudioTapCapture"],
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
