import SwiftUI

@main
struct AICallAssistantApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("AI Call Assistant") {
            AppShellView(model: model)
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            SidebarCommands()
        }
    }
}
