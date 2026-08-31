import AppKit
import SwiftUI

@main
struct AICallAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: OpenAISettingsStore
    @StateObject private var model: AppModel

    init() {
        let settings = OpenAISettingsStore()
        _ = try? settings.importAPIKeyFromEnvironmentIfRequested()
        _settings = StateObject(wrappedValue: settings)
#if DEBUG
        let isUISnapshot = CommandLine.arguments.contains("--ui-snapshot")
        _model = StateObject(
            wrappedValue: AppModel(
                openAISettings: settings,
                loadsPersistedStateInBackground: !isUISnapshot,
                contexts: isUISnapshot ? [] : nil,
                recordings: isUISnapshot ? [] : nil
            )
        )
#else
        _model = StateObject(
            wrappedValue: AppModel(
                openAISettings: settings,
                loadsPersistedStateInBackground: true
            )
        )
#endif
    }

    var body: some Scene {
        WindowGroup("Callya") {
            AppShellView(model: model)
        }
        // The hub supplies a quiet unified title strip while macOS keeps the
        // native traffic lights and window behavior.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 800)
        .windowResizability(.contentSize)

        Settings {
            AppSettingsView(store: settings, presentation: .settingsWindow)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let captureProtection = WindowCaptureProtectionController()
    private var isPreparingTermination = false

    func applicationWillFinishLaunching(_ notification: Notification) {
#if DEBUG
        // UI snapshots need a real rendered window. Production builds never
        // compile this escape hatch; debug builds require an explicit launch
        // argument so ordinary local runs remain capture-protected as well.
        guard !CommandLine.arguments.contains("--ui-snapshot") else { return }
#endif
        captureProtection.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureProtection.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = ApplicationTerminationCoordinator.shared
        guard coordinator.needsDeferredTermination else { return .terminateNow }
        guard !isPreparingTermination else { return .terminateLater }

        isPreparingTermination = true
        Task { @MainActor [weak self] in
            let shouldTerminate = await coordinator.prepareForTermination()
            self?.isPreparingTermination = false
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}
