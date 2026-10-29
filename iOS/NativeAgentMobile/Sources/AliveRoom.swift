import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `AliveRoom.swift` | Phone room and chat-driven mood presenting the shared `HazeView` |

// Three radial-gradient layers drift on the render server; state changes ramp tempo and weight.
// Peak overlap stays within 0.44 alpha so room text retains its contrast.

// MARK: - The room

/// The room colour and the haze over it, edge to edge. Put it behind a screen
/// whose own backgrounds are clear.
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

/// Reads the chat's turn state for the room's mood. Every input changes a few
/// times per turn; the representable ignores anything that is not a change.
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
