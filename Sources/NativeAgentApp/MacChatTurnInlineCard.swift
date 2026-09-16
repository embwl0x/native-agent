import SwiftUI
import CoreGraphics

/// The working card, in the inline-card grammar, at the transcript position the
/// interaction belongs to.
///
/// NOT MOUNTED IN THE APP YET. `InlineCardMockups` is its only caller: the
/// transcript still renders the floating working card, and switching that
/// mount is the mechanism's job. This is the drawn proposal for when it does,
/// which is what the mockups are shot from.
///
/// Truth still lives in the lifecycle owner: this is a second pure projection
/// of the same `MacChatTurnCardModel` the floating card already renders, and it
/// decides nothing. Nothing here duplicates lifecycle state, owns a clock, or
/// offers an approval decision.
///
/// What survives from the floating card: Stop, the unknown outcome carrying its
/// own yellow mark (never green, never red), and the live frame thumbnail.
struct MacChatTurnInlineCard: View {
    let model: MacChatTurnCardModel
    /// The live frame, while the agent is driving the Mac. `nil` for every turn
    /// that never touches those verbs.
    var preview: MacChatScreenPreview? = nil
    var onStop: (() -> Void)? = nil

    /// The line under the title. While the agent is driving the Mac the verb's
    /// own words win — the same rule the floating card follows.
    private var reason: String {
        if showsPreviewPane, let caption = preview?.caption, model.approval == nil {
            return caption
        }
        return model.detail ?? ""
    }

    private var showsPreviewPane: Bool {
        !model.isTerminal && preview?.isShowable == true
    }

    private var meta: String {
        MacChatTurnCardFormat.metaLine(
            elapsed: model.elapsed,
            secondsSinceMovement: model.secondsSinceMovement,
            isTerminal: model.isTerminal,
            separator: " · "
        )
    }

    /// A terminal turn that cannot say how it ended keeps the yellow mark. The
    /// three marks are the whole vocabulary: nothing here is ever green for a
    /// stop or red for an unknown.
    private var mark: InlineCardMark {
        switch model.tone {
        case .unresolved, .canceled, .failed, .attention: return .unknown
        case .working: return .done
        }
    }

    var body: some View {
        if model.isTerminal {
            InlineCardReceipt(mark: mark, outcome: model.title,
                              meta: meta.isEmpty ? reason : meta)
                .accessibilityIdentifier("chat.turn.inline-card.settled")
        } else {
            InlineCard(symbol: model.symbolName,
                       symbolTint: NativeAgentShell.needsYou,
                       title: model.title,
                       reason: reason) {
                HStack(spacing: NativeAgentSpacing.sm) {
                    InlineCardBusyLine(text: meta)
                    Spacer(minLength: NativeAgentSpacing.sm)
                    if showsPreviewPane, let preview, let image = preview.image {
                        thumbnail(image)
                            .accessibilityLabel(preview.caption.isEmpty
                                                ? "What the agent is looking at" : preview.caption)
                    }
                    if let onStop {
                        InlineCardSecondaryButton(title: "Stop", enabled: !model.cancellationPending,
                                                  action: onStop)
                            .help(model.cancellationPending ? "Stop already requested" : "Stop this turn")
                    }
                }
            }
            .accessibilityIdentifier("chat.turn.inline-card")
        }
    }

    /// The live computer pane: a picture of the user's own screen, shown back
    /// in the app that took it. It never leaves this process, and the capture
    /// side has already painted out every secure field.
    private func thumbnail(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 2)
            .resizable()
            .aspectRatio(16.0 / 10.0, contentMode: .fill)
            .frame(width: 72, height: 45)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NativeAgentRadius.control, style: .continuous)
                    .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
            )
    }
}
