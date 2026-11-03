import SwiftUI
import EngineRuntime

// Blueprint: | `ChatStreamingTail.swift` | `StreamingTailBubble` and observer: mounted leaves retain their stable box for row-local live text updates without republishing the whole transcript |

/// Only the streaming tail observes live chunks; the transcript owner retains row structure.
struct StreamingTailBubble: View {
    @Environment(AppModel.self) private var appModel
    var message: ChatMessage
    var isLastAssistant: Bool
    /// Keeping the last reply on this view preserves its settle state; only a live row reads the box.
    var isLive = true

    var body: some View {
        StreamingTailContent(message: message, isLastAssistant: isLastAssistant,
            box: isLive ? appModel.engine.transcripts.streamingTailBox(forMessage: message.id) : nil)
    }
}

/// Retaining the box in the mounted view also tells its cache that it is held.
private struct StreamingTailContent: View {
    var message: ChatMessage
    var isLastAssistant: Bool
    let box: ChatStreamingTailBox?

    var body: some View {
        var live = message
        if let content = box?.content {
            live.content = content
        }
        return MessageBubble(message: live, isLastAssistant: isLastAssistant)
            .equatable()
    }
}

/// The leaf's publication keeps the reply above the composer without per-chunk parent renders.
struct ChatStreamingTailObserver: View {
    @Environment(AppModel.self) private var appModel
    var messageID: String?
    var enabled: Bool
    var onChanged: () -> Void

    var body: some View {
        if enabled {
            StreamingTailObservation(box: appModel.engine.transcripts.streamingTailBox(forMessage: messageID ?? ""),
                onChanged: onChanged)
        }
    }
}

private struct StreamingTailObservation: View {
    let box: ChatStreamingTailBox
    var onChanged: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: box.content) { _, _ in onChanged() }
    }
}

extension View {
    /// Owns the live-tail dependency without adding a generic layer to a
    /// viewport body that is already at the type-checker's limit.
    func followsStreamingTail(
        messageID: String?, enabled: Bool = true, onChanged: @escaping () -> Void
    ) -> some View {
        background(ChatStreamingTailObserver(messageID: messageID, enabled: enabled, onChanged: onChanged))
    }
}
