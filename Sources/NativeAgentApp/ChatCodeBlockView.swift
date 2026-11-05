import NativeAgentShared
import SwiftUI

// Blueprint: | `ChatCodeBlockView.swift` | `ChatCodeBlockView`: selectable fenced code, language label and idempotent copy; no renderer state or clock |

/// Keep copy idempotent and unconfirmed so the renderer needs no state or timer.
/// Show the language without a tokenizer or theme system to keep rendering lightweight.
/// Wrap long lines because nested scroll views compete with transcript gestures and fragment text selection.
struct ChatCodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NativeAgentSpacing.xs) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: NativeAgentSpacing.sm)
                Button {
                    ChatClipboard.copy(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(NativeAgentFont.tag)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy code")
                .accessibilityLabel("Copy code block")
            }
            .padding(.horizontal, NativeAgentSpacing.sm)
            .padding(.vertical, NativeAgentSpacing.xs)

            Divider().opacity(0.4)

            Text(code)
                .font(NativeAgentFont.mono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, NativeAgentSpacing.sm)
                .padding(.vertical, NativeAgentSpacing.sm)
        }
        .houseInset(in: RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
