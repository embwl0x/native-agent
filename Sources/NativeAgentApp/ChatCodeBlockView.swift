import SwiftUI

/// A fenced code block in the transcript: monospaced, newline-preserving,
/// selectable, with the fence's language label and a copy button.
///
/// NO STATE AND NO CLOCK. There is deliberately no "Copied!" confirmation
/// flash — that needs a flag plus a timer to clear it, which is exactly the
/// renderer-local state machine and renderer-local clock this surface is not
/// allowed to grow. The copy is an unconfirmed, idempotent action.
///
/// NO SYNTAX HIGHLIGHTING. The language is shown as a label, not used to
/// tokenize. Highlighting is a per-language tokenizer plus a light/dark theme
/// we would own forever; the label plus copy carries nearly all of the value.
///
/// NO NESTED SCROLL VIEW. Long lines wrap. A horizontal `ScrollView` inside a
/// `LazyVStack` row competes with the transcript's own scroll gesture and
/// costs layout on every row; wrapping keeps text selection contiguous.
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
        .background(
            RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NativeAgentRadius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        )
        .accessibilityElement(children: .contain)
    }
}
