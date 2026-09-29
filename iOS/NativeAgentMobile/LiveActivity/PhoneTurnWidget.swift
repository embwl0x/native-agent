import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PhoneTurnWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneTurnAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "sparkle")
                VStack(alignment: .leading) {
                    Text(context.attributes.agentName).font(.headline)
                    Text(context.isStale ? "Waiting for an update from the Mac" : context.state.status)
                        .font(.subheadline)
                }
                Spacer()
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.attributes.agentName).font(.headline) }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Waiting for the Mac" : context.state.status)
                }
            } compactLeading: {
                Image(systemName: "sparkle")
            } compactTrailing: {
                Image(systemName: context.isStale ? "clock" : "ellipsis")
            } minimal: {
                Image(systemName: "sparkle")
            }
        }
    }
}
