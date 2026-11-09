import Foundation
import SwiftUI
import NativeAgentShared

// Blueprint: | `MessageBubbleActions.swift` | Bubble hover controls, canonical message JSON sheet and advanced text editor |

struct BubbleHoverBar: View {
    var message: TranscriptMessageReference
    var canRetry: Bool
    var onCopy: () -> Void
    var onRegenerate: () -> Void
    var isReading: Bool
    var onReadAloud: () -> Void
    var onStopReading: () -> Void

    private var isAssistant: Bool { message.role == "assistant" }

    var body: some View {
        HStack(spacing: NativeAgentSpacing.xs) {
            BubbleAction(icon: "doc.on.doc", help: "Copy text", action: onCopy)

            if isAssistant && canRetry {
                BubbleAction(icon: "arrow.clockwise", help: "Regenerate", action: onRegenerate)
            }

            if isAssistant {
                if isReading {
                    BubbleAction(icon: "speaker.slash", help: "Stop reading", action: onStopReading)
                } else {
                    BubbleAction(icon: "speaker.wave.2", help: "Read aloud", action: onReadAloud)
                }
            }
        }
        .padding(.horizontal, NativeAgentSpacing.sm)
        .padding(.vertical, 4)
        .houseSurface(in: RoundedRectangle(cornerRadius: NativeAgentRadius.control))
    }
}

private struct BubbleAction: View {
    var icon: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Canonical message detail is prepared by the body and drawn from its document slot.
struct MessageJSONSheet: View {
    let message: TranscriptMessageReference
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        PageSheetHost(title: "Message data", onDone: { dismiss() }) {
            FaceDocumentReader(identity: [message.session, message.id], presentation: { _ in
                try await appModel.documentPresentation(.message(session: message.session, message: message.id))
            }).padding(16)
        }
    }
}

struct AdvancedTextEditor: View {
    var title: String
    @Binding var text: String
    var minHeight: CGFloat = 82
    var isReadOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .disabled(isReadOnly)
                .frame(minHeight: minHeight, maxHeight: minHeight + 44)
                .scrollContentBackground(.hidden)
                .padding(6)
        }
    }
}
