import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit
// Blueprint: | `PhoneTalkWidget.swift` | Active talk Lock Screen and Dynamic Island: elapsed time, real mute state and app-executed mute/end controls |

struct PhoneTalkWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhoneTalkAttributes.self) { context in
            HStack(spacing: 12) {
                Button(intent: PhoneTalkResumeIntent()) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.agentName).font(.headline)
                        Text(context.isStale ? "Open NativeAgent to check talk" : context.state.status).font(.caption).lineLimit(2)
                        if !context.isStale { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
                    }
                }.buttonStyle(.plain)
                Spacer()
                talkButtons(context)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.agentName).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale { Text(context.attributes.startedAt, style: .timer).monospacedDigit() }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.isStale ? "Open NativeAgent to check talk" : context.state.status).font(.caption).lineLimit(2)
                        Spacer()
                        talkButtons(context)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "phone.fill")
            } compactTrailing: {
                if context.isStale { Image(systemName: "questionmark") }
                else { Text(context.attributes.startedAt, style: .timer).monospacedDigit().frame(width: 48) }
            } minimal: {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "phone.fill")
            }
        }
    }

    private func talkButtons(_ context: ActivityViewContext<PhoneTalkAttributes>) -> some View {
        HStack(spacing: 12) {
            Button(intent: PhoneTalkMuteIntent(callID: context.attributes.callID)) {
                Image(systemName: context.state.muted ? "mic.slash.fill" : "mic.fill").frame(width: 44, height: 44)
            }.accessibilityLabel(context.state.muted ? "Unmute" : "Mute")
            Button(intent: PhoneTalkEndIntent(callID: context.attributes.callID)) {
                Image(systemName: "phone.down.fill").frame(width: 44, height: 44).foregroundStyle(.red)
            }.accessibilityLabel("End talk")
        }
    }
}
