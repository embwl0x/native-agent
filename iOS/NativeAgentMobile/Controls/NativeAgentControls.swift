import SwiftUI
import WidgetKit

@main
struct NativeAgentControls: WidgetBundle {
    var body: some Widget { QuickAskControl() }
}

struct QuickAskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "NativeAgentMobile.QuickAsk") {
            ControlWidgetButton(action: MobileOpenTalkIntent()) {
                Label("Talk", systemImage: "phone.fill")
            }
        }
        .displayName("Talk to Your Agent")
        .description("Start a hands-free conversation with your agent in NativeAgent.")
    }
}
