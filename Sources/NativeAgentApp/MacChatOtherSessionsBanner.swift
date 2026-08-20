import SwiftUI

/// 658.14 — the "work is running somewhere else" banner, and the way to get to
/// it.
///
/// Previously inline in ChatView (PATCH-2026-05-13, parallel-sessions). Two
/// reasons it moved out:
///
/// 1. Behaviour. The old inline version routed only when EXACTLY ONE other
///    session was running ("Return"). At two or more it degraded to a single
///    "Stop Others" button — so the case where you most need to find the work
///    was the one case with no way to reach it, and the only affordance on
///    offer was destructive. Navigation is now available at every count.
/// 2. Mechanics. ChatView's body is at the Swift type-checker's ceiling;
///    adding a Menu inline produced "unable to type-check this expression in
///    reasonable time". Extraction is the standard fix for that class.
/// The affordances the banner offers, decided in pure code so the property
/// that matters — background work is reachable at EVERY running-session count,
/// and stopping is never the only exit — is testable rather than asserted.
enum MacChatOtherSessionsAffordances: Sendable, Equatable {
    case none
    case single(sessionId: String)
    case many(count: Int)

    static func decide(otherRunning: [String]) -> MacChatOtherSessionsAffordances {
        guard let first = otherRunning.first else { return .none }
        return otherRunning.count == 1 ? .single(sessionId: first) : .many(count: otherRunning.count)
    }

    /// True when the user can reach the running work from here.
    var offersNavigation: Bool {
        switch self {
        case .none: return false
        case .single, .many: return true
        }
    }

    /// True when a stop control is shown. Kept independent from
    /// `offersNavigation` so the destructive-only invariant can actually fail
    /// its regression test if either decision drifts.
    var offersStop: Bool {
        switch self {
        case .none: return false
        case .single, .many: return true
        }
    }
}

struct MacChatOtherSessionsBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let otherRunning: [String]
    let routes: ([String]) -> [MacChatRunningSessionRoute]
    let onGoTo: (String) -> Void
    let onStop: (String) -> Void

    private var affordances: MacChatOtherSessionsAffordances {
        .decide(otherRunning: otherRunning)
    }

    var body: some View {
        if affordances.offersNavigation {
            HStack(spacing: NativeAgentSpacing.sm) {
                Label(title, systemImage: "ellipsis.message")
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .single(let onlySid) = affordances {
                    Button("Return", systemImage: "arrow.turn.up.left") {
                        onGoTo(onlySid)
                    }
                    .buttonStyle(.borderless)
                    if affordances.offersStop {
                        Button("Stop", systemImage: "stop.fill") {
                            onStop(onlySid)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                } else {
                    MacChatRunningSessionMenu(
                        routes: routes(otherRunning),
                        onSelect: onGoTo
                    )
                    if affordances.offersStop {
                        Button("Stop Others", systemImage: "stop.fill") {
                            for sid in otherRunning { onStop(sid) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
            .padding(.horizontal)
            .transition(
                reduceMotion
                    ? .identity
                    : .opacity.combined(with: .move(edge: .bottom))
            )
        }
    }

    private var title: String {
        otherRunning.count == 1
            ? "Chat running in another session"
            : "\(otherRunning.count) other sessions running"
    }
}
