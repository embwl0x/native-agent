import AppKit
import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `SimpleThreadComposer.swift` | Thread-bound drafts clear only on acceptance; shared send and accessibility |

/// Clear the draft only after acceptance so failed sends preserve the user's words.
struct SimpleComposer: View {
    /// Bind drafts to thread identity so changing presentation cannot send to the wrong recipient.
    let thread: String
    let placeholder: String
    /// Keep the recipient visible because a placeholder disappears at the first keystroke.
    var recipient: String?
    var note: String?
    var alternate: (title: String, send: (String) async -> Bool)?
    let send: (String) async -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var appModel
    private var draftSubject: String { "simple-thread/\(thread)" }
    private var text: Binding<String> { appModel.editBinding(draftSubject, seed: "") }
    @State private var sending = false
    @State private var request: Task<Void, Never>?

    private var trimmed: String { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sendable: Bool { !sending && !trimmed.isEmpty }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let recipient { ComposerRecipientChip(name: recipient) }
                TextField(recipient == nil ? placeholder : "Message…", text: text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ShellType.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { submit() }
                    .accessibilityLabel(placeholder)
            }
            HStack(alignment: .center, spacing: 10) {
                Text(note ?? "")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if sending {
                    Button("Cancel waiting") { request?.cancel() }.buttonStyle(.plain)
                }
                if let alternate {
                    Button(alternate.title) { submit(alternate.send) }
                        .buttonStyle(.plain)
                        .font(ShellType.captionMedium)
                        .foregroundStyle(sendable ? NativeAgentShell.secondary : NativeAgentShell.tertiary)
                        .disabled(!sendable)
                }
                Button(action: { submit() }) {
                    Image(systemName: "arrow.right")
                        .font(ShellType.body)
                        .frame(width: 36, height: 36)
                        .background(
                            sendable ? Color.primary.opacity(0.12) : NativeAgentShell.quietFill,
                            in: Circle()
                        )
                        .foregroundStyle(sendable ? NativeAgentShell.text : NativeAgentShell.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!sendable)
                .help("Send")
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focused = true }
            HazeBottomGlow(cornerRadius: NativeAgentShellLayout.composerRadius)
        }
        .houseSurface(in: shape, opaqueFill: Color(nsColor: .controlBackgroundColor))
        .overlay {
            shape
                .strokeBorder(NativeAgentShell.text, lineWidth: focused ? 2 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : NativeAgentMotion.quick, value: focused)
        .simpleRoomColumn(gutter: 0)
        .padding(.bottom, 24)
    }

    private func submit(_ route: ((String) async -> Bool)? = nil) {
        guard sendable else { return }
        let draft = text.wrappedValue
        let origin = draftSubject
        let message = trimmed
        let deliver = route ?? send
        sending = true
        request = Task { @MainActor in
            defer { sending = false; request = nil }
            guard await deliver(message) else { return }
            appModel.acceptEditDraft(origin, submitted: draft, saved: "")
        }
    }
}
