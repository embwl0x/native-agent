import NativeAgentShared
import EngineRuntime
import SwiftUI

// Blueprint: | `MacChatOtherSessionsBanner.swift` | `MacChatOtherSessionsBanner`: navigation and stop controls directly over the other running sessions |

/// Every nonempty list offers navigation to its running work and a stop control.
struct MacChatOtherSessionsBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let otherRunning: [String]
    let routes: ([String]) -> [MacChatRunningSessionRoute]
    let onGoTo: (String) -> Void
    let onStop: (String) -> Void

    var body: some View {
        if let first = otherRunning.first {
            HStack(spacing: NativeAgentSpacing.sm) {
                Label(title, systemImage: "ellipsis.message")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                Spacer()
                if otherRunning.count == 1 {
                    Button("Return", systemImage: "arrow.turn.up.left") {
                        onGoTo(first)
                    }
                    .buttonStyle(.borderless)
                    Button("Stop", systemImage: "stop.fill") {
                        onStop(first)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    MacChatRunningSessionMenu(
                        routes: routes(otherRunning),
                        onSelect: onGoTo
                    )
                    Button("Stop Others", systemImage: "stop.fill") {
                        for sid in otherRunning { onStop(sid) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .transition(
                reduceMotion ? NativeAgentMotion.fade : NativeAgentMotion.reveal(anchor: .bottom)
            )
        }
    }

    private var title: String {
        otherRunning.count == 1
            ? "Chat running in another session"
            : "\(otherRunning.count) other sessions running"
    }
}
