import XCTest
@testable import AICallAssistant

@MainActor
final class CoreAudioSourceDiscoveryServiceTests: XCTestCase {
    func testDiscoveryIncludesSystemAudioAndKeepsDefaultMicrophoneFirst() async throws {
        let microphone = AudioSourceOption(
            id: "microphone:default",
            title: "MacBook Microphone",
            kind: .microphone(uniqueID: "default")
        )
        let service = CoreAudioSourceDiscoveryService(
            processLoader: {
                [
                    CoreAudioProcessDescriptor(
                        processID: 42,
                        bundleIdentifier: "com.example.meeting",
                        title: "Meeting",
                        isProducingOutput: true
                    )
                ]
            },
            microphoneLoader: { [microphone] },
            ownProcessID: 7,
            ownBundleIdentifier: "com.example.callya"
        )

        let catalog = try await service.discoverSources()

        XCTAssertEqual(catalog.incoming.first, .systemAudio)
        XCTAssertEqual(catalog.incoming.map(\.title), ["Весь системный звук", "Meeting"])
        XCTAssertEqual(catalog.microphones, [microphone])
    }

    func testBuilderGroupsHelpersByBundleAndPrefersProcessProducingOutput() {
        let options = CoreAudioProcessSourceBuilder.options(
            from: [
                CoreAudioProcessDescriptor(
                    processID: 40,
                    bundleIdentifier: "com.example.browser",
                    title: "Browser Helper",
                    isProducingOutput: false
                ),
                CoreAudioProcessDescriptor(
                    processID: 41,
                    bundleIdentifier: "COM.EXAMPLE.BROWSER",
                    title: "Browser",
                    isProducingOutput: true
                )
            ],
            excludingProcessID: 7,
            excludingBundleIdentifier: "com.example.callya"
        )

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].id, "application:com.example.browser")
        XCTAssertEqual(options[0].title, "Browser")
        XCTAssertEqual(
            options[0].kind,
            .application(bundleIdentifier: "COM.EXAMPLE.BROWSER", processID: 41)
        )
    }

    func testBuilderExcludesOwnPIDAndBundleAndSortsTitles() {
        let options = CoreAudioProcessSourceBuilder.options(
            from: [
                descriptor(pid: 7, bundle: "com.example.other", title: "Own PID"),
                descriptor(pid: 9, bundle: "com.example.callya", title: "Own Helper"),
                descriptor(pid: 10, bundle: "com.example.zoom", title: "Zoom"),
                descriptor(pid: 11, bundle: "com.example.around", title: "Around")
            ],
            excludingProcessID: 7,
            excludingBundleIdentifier: "COM.EXAMPLE.CALLYA"
        )

        XCTAssertEqual(options.map(\.title), ["Around", "Zoom"])
    }

    func testBuilderFallsBackToTitleWhenBundleIdentifierIsMissing() {
        let options = CoreAudioProcessSourceBuilder.options(
            from: [
                descriptor(pid: 20, bundle: "", title: "Audio Utility"),
                descriptor(pid: 21, bundle: "", title: "audio utility")
            ],
            excludingProcessID: 7,
            excludingBundleIdentifier: nil
        )

        XCTAssertEqual(options.count, 1)
        guard case let .application(bundleIdentifier, processID) = options[0].kind else {
            return XCTFail("Expected an application source")
        }
        XCTAssertEqual(bundleIdentifier, "")
        XCTAssertEqual(processID, 20)
    }

    private func descriptor(
        pid: Int32,
        bundle: String,
        title: String
    ) -> CoreAudioProcessDescriptor {
        CoreAudioProcessDescriptor(
            processID: pid,
            bundleIdentifier: bundle,
            title: title,
            isProducingOutput: false
        )
    }
}
