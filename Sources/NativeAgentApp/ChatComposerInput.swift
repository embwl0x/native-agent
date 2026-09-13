import SwiftUI

/// The composer: the text field, its slash menu, and the control strip around
/// it.
///
/// User, 2026-09-13 (typing lag). This is the only view a keystroke invalidates.
/// It is split out of `ChatView.body` because it is the only place the
/// in-progress text is READ during a body evaluation — `canSend` needs it, the
/// text field is bound to it, and the slash menu watches it. With the draft
/// living in an `@Observable` `ChatComposerDraft` and every read of it confined
/// here, SwiftUI's observation graph stops at this struct: the transcript
/// (`ChatMessageListView` / `MessageBubble`) and the conversation list
/// (`ChatShellConversationRow`) are siblings whose inputs did not change, so
/// their bodies are not re-run and `ChatMessage.==` is not called.
///
/// Everything else — slash menu, voice draft, Stop/Steer, drag-drop, Tab focus
/// — is the same code, moved, with the focus state still owned by `ChatView`
/// (passed as a `@FocusState` binding) so `focusComposer` and the keyboard
/// reach of the receipts rail keep working.
struct ChatComposerInput: View {
    let draft: ChatComposerDraft
    let classicShell: Bool
    let placeholder: String
    let voiceInput: VoiceInputController
    let capabilitiesStore: CapabilitiesStore
    /// The conversation dictation started in, and the one on screen. Speech may
    /// only write into the composer it started in (2026-09-06).
    let voiceSessionId: String
    let activeSessionId: String
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let hasPendingAttachments: Bool
    let isRunning: Bool
    let hasQueuedTurns: Bool
    let isQueuePaused: Bool
    let isCapturing: Bool
    @FocusState.Binding var inputFocused: Bool
    let onToggleVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let onSlashCommand: (String) -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let onToast: (String) -> Void
    let composeVoiceDraft: (String) -> String

    // The slash menu is composer-local state; nothing outside this view reads
    // it, so it no longer invalidates the chat.
    @State private var showSlashMenu = false
    @State private var slashFilter = ""

    private var canSend: Bool {
        !isCapturing
            && (ChatTranscriptPresentation.hasVisibleText(draft.text) || hasPendingAttachments)
    }

    var body: some View {
        MacChatComposerControlStrip(
            shell: !classicShell,
            isListening: voiceInput.isListening,
            screenCaptureAllowed: screenCaptureAllowed,
            screenCaptureDisabled: screenCaptureDisabled,
            pendingAttachmentCount: pendingAttachmentCount,
            isRunning: isRunning,
            hasQueuedTurns: hasQueuedTurns,
            isQueuePaused: isQueuePaused,
            canSend: canSend,
            onToggleVoice: onToggleVoice,
            onCaptureScreen: onCaptureScreen,
            onAttach: onAttach,
            onStop: onStop,
            onSend: onSend,
            onFocusRequest: { inputFocused = true },
            isFocused: inputFocused
        ) {
            TextField(
                voiceInput.isListening ? "" : placeholder,
                text: draft.textBinding,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(classicShell ? nil : ShellType.body)
            .lineLimit(1...5)
            .focused($inputFocused)
            .shellComposerKeyboardTarget(isFocused: inputFocused) { inputFocused = true }
            .foregroundStyle(voiceInput.isListening ? .secondary : .primary)
            .italic(voiceInput.isListening)
            .onSubmit { onSend() }
            .onChange(of: voiceInput.transcript) { _, newVal in
                // Only the conversation that started dictating may be written
                // to (2026-09-06).
                guard voiceSessionId == activeSessionId else { return }
                if ChatTranscriptPresentation.hasVisibleText(newVal) {
                    draft.edit(composeVoiceDraft(newVal))
                }
            }
            .onChange(of: draft.text) { _, newVal in
                if newVal.hasPrefix("/") {
                    let afterSlash = String(newVal.dropFirst())
                    let hasArgsAlready = afterSlash.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                    let firstToken = afterSlash.components(separatedBy: .whitespacesAndNewlines).first ?? afterSlash
                    let lowerToken = firstToken.lowercased()
                    let dynamicCommandNames = capabilitiesStore.slashCommandNames
                    let prefixMatch = !hasArgsAlready && (
                        lowerToken.isEmpty
                        || ChatSlashCommandRegistry.commandNames.contains { $0.hasPrefix(lowerToken) }
                        || dynamicCommandNames.contains { $0.hasPrefix(lowerToken) }
                    )
                    if prefixMatch {
                        slashFilter = afterSlash
                        showSlashMenu = true
                    } else {
                        showSlashMenu = false
                        slashFilter = ""
                    }
                } else {
                    showSlashMenu = false
                    slashFilter = ""
                }
            }
            .popover(isPresented: $showSlashMenu, arrowEdge: .bottom) {
                SlashCommandMenu(filter: slashFilter, onSelect: { command in
                    if command.hasSuffix(" ") {
                        draft.edit("/" + command)
                    } else {
                        onSlashCommand(command)
                    }
                    showSlashMenu = false
                    inputFocused = true
                }, onDismiss: {
                    showSlashMenu = false
                }, extraTools: capabilitiesStore.slashCommandTools())
            }
            .background(
                DropZoneView(onDrop: { providers in
                    onDrop(providers)
                }, onToast: { msg in
                    onToast(msg)
                })
            )
        }
    }
}
