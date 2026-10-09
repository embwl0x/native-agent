import SwiftUI

/// The live content of ONE streaming transcript row.
///
/// User, 2026-09-14 ("snappy is a requirement"): a streamed chunk used to
/// publish the whole `[ChatMessage]`, so ChatView, the shell column and the
/// message list all re-rendered fourteen times a second and the transcript —
/// a plain VStack of up to 300 rows — was re-laid-out whole for a token.
/// `/usr/bin/sample` during a 14 chunk/s stream: main thread ~62% busy, 5416
/// of 16532 samples under `NSHostingView.beginTransaction`, 2832 under
/// RootGeometry measurement.
///
/// Structure and live tail are now separately observed. The parent keeps its
/// structural snapshot (`engine.transcripts.structureVersion`); the tail row's bubble
/// takes the box for its own message id and observes THAT, so a token changes
/// one leaf's layout instead of the whole tree.


/// The streaming tail row. The ONLY view that observes a live chunk.
///
/// Everything the list puts around an ordinary row — the scroll target id, the
/// search highlight, the entrance transition, the layout probe — stays on the
/// row in `ChatMessageListView.bubbleRow`, so the transcript still follows the
/// stream and the working card still sits above the composer.
struct StreamingTailBubble: View {
    @Environment(AppModel.self) private var appModel
    var message: ChatMessage
    var isLastAssistant: Bool
    /// Fluid glass A1: the list keeps the last reply on this one view whether
    /// or not it streams, so the bubble keeps its state, and its settle
    /// crossfade, when the turn ends. Only a live row reads the box.
    var isLive = true

    var body: some View {
        var live = message
        if isLive, let content = appModel.engine.transcripts.streamingTailBox(forMessage: message.id).content {
            live.content = content
        }
        return MessageBubble(message: live, isLastAssistant: isLastAssistant)
            .equatable()
    }
}

/// Zero-size owner of the live-tail dependency for the surfaces that used to
/// hang an `onChange(of: chatMessages.last?.content)` off their own body.
///
/// The explicit follow added in 91925c76a has to keep working — the reply must
/// stay above the composer while it streams — so the trigger moved here, to
/// the leaf's publication, rather than being dropped with the parent's
/// per-chunk render.
struct ChatStreamingTailObserver: View {
    @Environment(AppModel.self) private var appModel
    var messageID: String?
    var enabled: Bool
    var onChanged: () -> Void

    var body: some View {
        if enabled {
            let box = appModel.engine.transcripts.streamingTailBox(forMessage: messageID ?? "")
            Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: box.content) { _, _ in onChanged() }
        }
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
