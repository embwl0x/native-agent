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
/// structural snapshot (`chatMessagesStructureVersion`); the tail row's bubble
/// takes the box for its own message id and observes THAT, so a token changes
/// one leaf's layout instead of the whole tree.
@MainActor
@Observable
final class ChatStreamingTailBox {
    /// nil means "no live value" — the row renders the content it was handed,
    /// which is what every settled row does and what this row does again once
    /// the turn's final write has gone through the structural seam.
    var content: String?
}

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

    var body: some View {
        let box = appModel.streamingTailBox(forMessage: message.id)
        var live = message
        if let content = box.content { live.content = content }
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
            let box = appModel.streamingTailBox(forMessage: messageID ?? "")
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

/// The streaming reply's raw text, one `Text` per paragraph.
///
/// User, 2026-09-23: one `Text` holding the whole growing reply was re-typeset
/// from its first word on every published chunk (~1 ms at the start of a
/// 1,500-word reply, ~70 ms at the end), so a long reply pinned the main
/// thread at 14 chunks a second and starved its own stream. Split at blank
/// lines, finished paragraphs are unchanged `Text`s that keep their cached
/// layout and only the last one re-lays out (~2 ms at the end).
///
/// Same pixels: the dropped `\n` of each `\n\n` becomes the stack's gap, which
/// is the environment's own line spacing, so the break is the one the single
/// `Text` drew. The settled reply does not come through here.
struct StreamingParagraphText: View {
    let text: String
    @Environment(\.lineSpacing) private var lineSpacing

    var body: some View {
        let paragraphs = Self.paragraphs(text)
        VStack(alignment: .leading, spacing: lineSpacing) {
            // Positional ids: paragraphs only append while a reply streams,
            // so a finished one keeps its id and its layout.
            ForEach(paragraphs.indices, id: \.self) { index in
                Text(paragraphs[index])
            }
        }
    }

    /// Splits at each `\n\n`, dropping its first `\n`; the second stays as the
    /// next paragraph's leading empty line.
    static func paragraphs(_ text: String) -> [Substring] {
        var out: [Substring] = []
        var start = text.startIndex
        var from = text.startIndex
        while let range = text[from...].range(of: "\n\n") {
            if range.lowerBound > start {
                out.append(text[start..<range.lowerBound])
                start = text.index(after: range.lowerBound)
            }
            from = range.upperBound
        }
        out.append(text[start...])
        return out
    }
}
