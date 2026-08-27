import SwiftUI

struct CompatibleSettingsLink<Label: View>: View {
    private let fallbackAction: () -> Void
    private let label: Label

    init(
        fallbackAction: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.fallbackAction = fallbackAction
        self.label = label()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                label
            }
        } else {
            Button(action: fallbackAction) {
                label
            }
        }
    }
}
