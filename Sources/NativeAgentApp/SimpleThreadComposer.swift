import AppKit
import SwiftUI
import Foundation
import NativeAgentShared
import EngineRuntime
import SwarmRuns
import Agents
import ChatSessionWork
import AgentWorkspace
import NativeAgentCore
import PersistenceCore
import StandingBots
import ProviderRouting
import AppToolRuntime
// Blueprint: | `SimpleThreadComposer.swift` | SimpleComposer binds drafts to their thread and clears only accepted sends, retaining alternate routes and accessibility |

/// The thread composer shares chat glass and spacing; Return sends and only acceptance clears.
struct SimpleComposer: View {
    /// The thread the draft belongs to across presentations.
    let thread: String
    let placeholder: String
    /// Who a send goes straight to. Shown the whole time, because the
    /// placeholder that named them is gone at the first keystroke.
    var recipient: String?
    var note: String?
    /// A second way to send the draft, beside the arrow: a title and its send.
    var alternate: (title: String, send: (String) async -> Bool)?
    let send: (String) async -> Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @Environment(AppModel.self) private var appModel
    private var draftSubject: String { "simple-thread/\(thread)" }
    private var text: Binding<String> { appModel.editBinding(draftSubject, seed: "") }
    @State private var sending = false

    private var trimmed: String { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sendable: Bool { !sending && !trimmed.isEmpty }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NativeAgentShellLayout.composerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let recipient {
                    Text("To: \(recipient)")
                        .font(ShellType.captionMedium)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(NativeAgentShell.softFill, in: Capsule())
                        .fixedSize()
                }
                TextField(placeholder, text: text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(ShellType.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { submit() }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(note ?? "")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { shape.strokeBorder(NativeAgentShell.hairline, lineWidth: 1) }
            }
            HazeBottomGlow(cornerRadius: NativeAgentShellLayout.composerRadius)
        }
        .glassEffect(reduceTransparency ? .identity : HouseGlass.plate, in: shape)
        .overlay {
            if focused, !reduceTransparency {
                shape.fill(Color.primary.opacity(0.04)).allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : NativeAgentMotion.quick, value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
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
        Task { @MainActor in
            defer { sending = false }
            guard await deliver(message) else { return }
            appModel.acceptEditDraft(origin, submitted: draft, saved: "")
        }
    }
}
