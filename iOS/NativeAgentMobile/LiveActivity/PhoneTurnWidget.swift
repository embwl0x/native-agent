import ActivityKit
import SwiftUI
import WidgetKit
import NativeAgentShared

@main
struct PhoneTurnWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneTurnAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "sparkle")
                VStack(alignment: .leading) {
                    Text(context.attributes.agentName).font(.headline)
                    Text(context.state.title).font(.headline).lineLimit(2)
                    Text(context.isStale ? "Last known: \(context.state.status)" : context.state.status)
                        .font(.subheadline)
                }
                Spacer()
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.state.title).font(.headline).lineLimit(2) }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Last known: \(context.state.status)" : context.state.status)
                }
            } compactLeading: {
                Image(systemName: "sparkle")
            } compactTrailing: {
                Image(systemName: symbol(context.state.state, stale: context.isStale))
            } minimal: {
                Image(systemName: "sparkle")
            }
        }
    }

    private func symbol(_ state: MobileWorkActivity.State, stale: Bool) -> String {
        if stale { return "clock" }
        switch state {
        case .queued, .preparing, .waiting, .retrying: return "clock"
        case .blocked: return "hand.raised"
        case .tool: return "gearshape"
        case .replying: return "text.bubble"
        case .completed: return "checkmark"
        case .failed, .interrupted, .unknown: return "exclamationmark"
        case .stopped: return "stop.fill"
        case .working: return "ellipsis"
        }
    }
}
