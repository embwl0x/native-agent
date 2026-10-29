import Dispatcher
import SwiftUI
import AppKit
import ChatTurnRuntime
import ChatSessionWork
import NativeAgentShared

// Blueprint: | `ChatComposerInput.swift` | `ChatComposerInput`: draft-local text entry, slash menu, recipient chip and command-key handling |

/// Draft reads stay inside the composer so keystrokes leave transcript and
/// conversation rows untouched; `ChatView` owns focus and keyboard reach.
struct ChatComposerInput: View {
    let draft: ChatComposerDraft
    let placeholder: String
    var isActive = true
    /// "To: <agent>" before the field (Simple view); nil hides it.
    var recipient: String? = nil
    let voiceInput: VoiceInputCapture
    /// Speech may only write into the conversation's composer where dictation started.
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
    let composeVoiceDraft: (String) -> Void

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

    private var slashCommands: [ChatSlashCommandDescriptor] {
        SlashCommandMenu.commands(filter: slashFilter)
    }

    private var selectedSlashCommand: ChatSlashCommandDescriptor? {
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
                suggestionKey: handleSlashKey,
                onPaste: onDrop
            )
            .foregroundStyle(voiceInput.isListening ? .secondary : .primary)
            .italic(voiceInput.isListening)
            .onSubmit { if canSend { onSend() } }
            .onPasteCommand(of: ChatAttachmentTypeResolver.attachmentContentTypes, perform: onDrop)
            .onChange(of: voiceInput.transcript) { _, newVal in
                // Dictation stays bound to its starting conversation.
                guard voiceSessionId == activeSessionId else { return }
                if ChatTranscriptPresentation.hasVisibleText(newVal) {
                    composeVoiceDraft(newVal)
                }
            }
            .onChange(of: draft.text) { _, newVal in
                if newVal.hasPrefix("/") {
                    let afterSlash = String(newVal.dropFirst())
                    let hasArgsAlready = afterSlash.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                    let firstToken = afterSlash.components(separatedBy: .whitespacesAndNewlines).first ?? afterSlash
                    let lowerToken = firstToken.lowercased()
                    let prefixMatch = !hasArgsAlready && (
                        lowerToken.isEmpty
                        || ChatSlashCommandRegistry.commandNames.contains { $0.hasPrefix(lowerToken) }
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
            // An in-window overlay keeps keyboard focus in the field while the menu filters.
            .overlay(alignment: .topLeading) {
                if showSlashMenu {
                    SlashCommandMenu(filter: slashFilter, selectedCommand: selectedSlashCommand?.id,
                                     onSelect: selectSlashCommand, onDismiss: {
                        showSlashMenu = false
                    })
                    .fixedSize()
                    .houseSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { slashMenuHeight = $0 }
                    // Keep the menu above the box, clear of the draft.
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
