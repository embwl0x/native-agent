import SwiftUI
import AppKit

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
    let placeholder: String
    var isActive = true
    /// "To: <agent>" before the field (Simple view); nil hides it.
    var recipient: String? = nil
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
    /// True while a model/provider/effort write is still landing. Send waits
    /// for the canonical receipt so a turn cannot go out on the old routing.
    var isRoutingSaving: Bool = false
    @FocusState.Binding var inputFocused: Bool
    let onToggleVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let onSlashCommand: (String) -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let composeVoiceDraft: (String) -> String

    // The slash menu is composer-local state; nothing outside this view reads
    // it, so it no longer invalidates the chat.
    @State private var showSlashMenu = false
    @State private var slashMenuHeight: CGFloat = 0
    @State private var slashFilter = ""
    @State private var selectedSlashCommandID: String?
    /// Bumped when Tab leaves the draft: the composer's settings words are the
    /// next stop, not the rail.
    @State private var focusWordToken = 0

    private var canSend: Bool {
        !isCapturing && !isRoutingSaving
            && (ChatTranscriptPresentation.hasVisibleText(draft.text) || hasPendingAttachments)
    }

    private var slashCommands: [SlashCommandMenu.SlashCmd] {
        SlashCommandMenu.commands(filter: slashFilter, extraTools: capabilitiesStore.slashCommandTools())
    }

    private var selectedSlashCommand: SlashCommandMenu.SlashCmd? {
        slashCommands.first { $0.id == selectedSlashCommandID } ?? slashCommands.first
    }

    private func selectSlashCommand(_ command: String) {
        guard canSend else { return }
        if command.hasSuffix(" ") {
            draft.edit("/" + command)
        } else {
            onSlashCommand(command)
        }
        showSlashMenu = false
        inputFocused = true
    }

    private func handleSlashKey(_ keyCode: UInt16) -> Bool {
        guard showSlashMenu else { return false }
        switch keyCode {
        case 126, 125:
            let commands = slashCommands
            guard !commands.isEmpty else { return false }
            let index = commands.firstIndex { $0.id == selectedSlashCommandID } ?? 0
            let next = min(max(index + (keyCode == 126 ? -1 : 1), 0), commands.count - 1)
            selectedSlashCommandID = commands[next].id
            NSAccessibility.post(element: NSApp, notification: .announcementRequested, userInfo: [
                .announcement: commands[next].helpLine,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        case 36, 76:
            guard let command = selectedSlashCommand else { return false }
            selectSlashCommand(command.selection)
        case 53:
            showSlashMenu = false
        default:
            return false
        }
        return true
    }

    var body: some View {
        MacChatComposerControlStrip(
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
            isFocused: inputFocused,
            showsConversationSettings: true,
            focusWordToken: focusWordToken
        ) {
            // Simple view says who a message goes to, as contact threads do.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let recipient { ComposerRecipientChip(name: recipient) }
            TextField(
                voiceInput.isListening ? "" : placeholder,
                text: draft.textBinding,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .accessibilityLabel("Message")
            .accessibilityHint(showSlashMenu ? selectedSlashCommand?.helpLine ?? "" : "")
            .font(ShellType.body)
            .lineLimit(1...5)
            .focused($inputFocused)
            .shellComposerKeyboardTarget(
                isFocused: isActive && inputFocused,
                focus: { inputFocused = true },
                tabInto: { backwards in
                    guard !backwards else { return false }
                    focusWordToken += 1
                    inputFocused = false
                    return true
                },
                suggestionKey: handleSlashKey
            )
            .foregroundStyle(voiceInput.isListening ? .secondary : .primary)
            .italic(voiceInput.isListening)
            .onSubmit { if canSend { onSend() } }
            .onPasteCommand(of: ChatComposerSupport.attachmentContentTypes, perform: onDrop)
            .background(ChatAttachmentPasteHandler(isFocused: isActive && inputFocused, onPaste: onDrop))
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
                        selectedSlashCommandID = slashCommands.first?.id
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
            // Drawn in the window, not a popover: a macOS popover takes key
            // focus, so typing stopped the moment the menu appeared (User
            // 09-27). The field keeps the keyboard; the list filters as you
            // type and still takes a click.
            .overlay(alignment: .topLeading) {
                if showSlashMenu {
                    SlashCommandMenu(filter: slashFilter, selectedCommand: selectedSlashCommand?.id,
                                     onSelect: selectSlashCommand, onDismiss: {
                        showSlashMenu = false
                    }, extraTools: capabilitiesStore.slashCommandTools())
                    .fixedSize()
                    .houseSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { slashMenuHeight = $0 }
                    // Above the box, clear of the draft (User 09-27, like Claude Code).
                    .offset(y: -(slashMenuHeight + 22))
                    .zIndex(10)
                }
            }
            }
        }
    }
}

/// The "To:" chip Simple view's composers lead with.
struct ComposerRecipientChip: View {
    let name: String
    var body: some View {
        Text("To: \(name)")
            .font(ShellType.captionMedium)
            .foregroundStyle(NativeAgentShell.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NativeAgentShell.softFill, in: Capsule())
            .fixedSize()
    }
}
