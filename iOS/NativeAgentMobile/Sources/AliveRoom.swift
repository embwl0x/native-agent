import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `AliveRoom.swift` | Phone room and chat-driven mood presenting the shared `HazeView` |

// Cap peak haze overlap at 0.44 alpha to preserve room text contrast.

// MARK: - The room

/// Screen backgrounds must remain clear so the edge-to-edge room shows through.
struct AliveRoom: View {
    var mood: HazeMood = .idle
    @AppStorage(HazeColor.key) private var colorRaw = HazeColor.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            AlivePalette.room
            if !reduceTransparency {
                HazeBackdrop(color: HazeColor(stored: colorRaw), mood: mood,
                             dark: colorScheme == .dark, still: reduceMotion)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Only changed turn inputs reach the representable, avoiding redundant room updates.
struct AliveChatRoom: View {
    var store: ChatStore

    var body: some View {
        AliveRoom(mood: mood)
    }

    private var mood: HazeMood {
        guard store.isLoading else { return .idle }
        guard let last = store.messages.last, last.role == .assistant, last.isStreaming, !last.text.isEmpty
        else { return .busy }
        return .replying
    }
}

struct HazeBackdrop: UIViewRepresentable {
    var color: HazeColor
    var mood: HazeMood
    var dark: Bool
    var still: Bool

    func makeUIView(context: Context) -> HazeView { HazeView() }

    func updateUIView(_ view: HazeView, context: Context) {
        view.apply(color: color, mood: mood, dark: dark, still: still)
    }

    static func dismantleUIView(_ view: HazeView, coordinator: ()) { view.teardown() }
}
