import SwiftUI
import WidgetKit

@main
struct NativeAgentControls: WidgetBundle {
    var body: some Widget { QuickAskControl() }
}

struct QuickAskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "NativeAgentMobile.QuickAsk") {
            ControlWidgetButton(action: MobileQuickAskIntent()) {
                Label("Quick Ask", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .displayName("Quick Ask")
        .description("Open a message to your agent in NativeAgent.")
    }
}
