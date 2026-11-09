import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatComposerInput.swift` | `ChatComposerInput`: draft-local text entry, slash menu, recipient chip and command-key handling |

/// Assemble chrome without reading characters; the field and Send own their observations.
struct ChatComposerInput: View {
    let draft: ChatComposerDraft
    let placeholder: String
    var isActive = true
    var recipient: String? = nil
    let voiceInput: FaceVoiceInput
    /// Dictation may write only to the conversation where it started.
    let voiceSessionId: String
    let activeSessionId: String
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let hasPendingAttachments: Bool
    let isRunning: Bool
    let isCapturing: Bool
    /// Wait for the routing receipt before Send so a turn cannot use old provider settings.
    var isRoutingSaving: Bool = false
    @FocusState.Binding var inputFocused: Bool
    let onToggleVoice: () -> Void
    let onDiscardVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    let onSlashCommand: (String) -> Void
    let onDrop: ([NSItemProvider]) -> Void
    let composeVoiceDraft: (String) -> Void

    /// Tab hands focus to settings words before the rail.
    @State private var focusWordToken = 0

    fileprivate var canSend: Bool {
        !isCapturing && !isRoutingSaving
            && (draft.hasVisibleText || hasPendingAttachments)
    }

    var body: some View {
        MacChatComposerControlStrip(
            isListening: voiceInput.isListening || voiceInput.isStarting,
            isStopping: voiceInput.isStopping,
            screenCaptureAllowed: screenCaptureAllowed,
            screenCaptureDisabled: screenCaptureDisabled,
            pendingAttachmentCount: pendingAttachmentCount,
            isRunning: isRunning,
            canSend: { canSend },
            onToggleVoice: onToggleVoice,
            onDiscardVoice: onDiscardVoice,
            onCaptureScreen: onCaptureScreen,
            onAttach: onAttach,
            onStop: onStop,
            onSend: onSend,
            onFocusRequest: { inputFocused = true },
            isFocused: inputFocused,
            showsConversationSettings: true,
            focusWordToken: focusWordToken
        ) {
            ChatComposerField(input: self, focusWordToken: $focusWordToken)
        }
    }
}

/// Character changes and slash filtering stay in the field's subtree.
private struct ChatComposerField: View {
    let input: ChatComposerInput
    @Environment(AppModel.self) private var appModel
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Binding var focusWordToken: Int
    @State private var showSlashMenu = false
    @State private var slashMenuHeight: CGFloat = 0
    @State private var slashFilter = ""
    @State private var selectedSlashCommandID: String?

    private var slashCommands: [ChatSlashCommandDescriptor] {
        SlashCommandMenu.commands(filter: slashFilter)
    }

    private var selectedSlashCommand: ChatSlashCommandDescriptor? {
        slashCommands.first { $0.id == selectedSlashCommandID } ?? slashCommands.first
    }

    private func selectSlashCommand(_ command: String) {
        guard input.canSend else { return }
        if command.hasSuffix(" ") {
            input.draft.edit("/" + command)
        } else {
            input.onSlashCommand(command)
        }
        showSlashMenu = false
        input.inputFocused = true
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let recipient = input.recipient { ComposerRecipientChip(name: recipient) }
            TextField(
                input.voiceInput.isListening ? "" : input.placeholder,
                text: input.draft.textBinding,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .accessibilityLabel("Message")
            .accessibilityIdentifier(FaceComposerFocus.identifier(session: input.draft.sessionId,
                                                                 active: input.isActive && !quietOffscreenRead))
            .accessibilityHint(showSlashMenu ? selectedSlashCommand?.helpLine ?? "" : "")
            .font(ShellType.body)
            .lineLimit(1...5)
            .focused(input.$inputFocused)
            .shellComposerKeyboardTarget(
                isFocused: input.isActive && input.inputFocused,
                focus: { input.inputFocused = true },
                tabInto: { backwards in
                    guard !backwards else { return false }
                    focusWordToken += 1
                    input.inputFocused = false
                    return true
                },
                suggestionKey: handleSlashKey,
                onPaste: input.onDrop
            )
            .foregroundStyle(input.voiceInput.isListening ? .secondary : .primary)
            .italic(input.voiceInput.isListening)
            .onSubmit { if input.canSend { input.onSend() } }
            .onPasteCommand(of: [.fileURL, .image], perform: input.onDrop)
            .onChange(of: input.voiceInput.transcript) { _, newVal in
                // Keep dictation bound to its starting conversation.
                guard input.voiceSessionId == input.activeSessionId else { return }
                if ChatTranscriptPresentation.hasVisibleText(newVal) {
                    input.composeVoiceDraft(newVal)
                }
            }
            .onChange(of: input.draft.text) { _, newVal in
                if newVal.hasPrefix("/") {
                    let afterSlash = String(newVal.dropFirst())
                    let hasArgsAlready = afterSlash.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                    let firstToken = afterSlash.components(separatedBy: .whitespacesAndNewlines).first ?? afterSlash
                    let lowerToken = firstToken.lowercased()
                    let prefixMatch = !hasArgsAlready && (
                        lowerToken.isEmpty
                        || !SlashCommandMenu.commands(filter: lowerToken).isEmpty
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
            // Use an in-window overlay so filtering preserves field focus.
            .overlay(alignment: .topLeading) {
                if showSlashMenu {
                    SlashCommandMenu(filter: slashFilter, selectedCommand: selectedSlashCommand?.id,
                                     onSelect: selectSlashCommand, onDismiss: {
                        showSlashMenu = false
                    })
                    .fixedSize()
                    .houseSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { slashMenuHeight = $0 }
                    // Keep suggestions above the box so they do not obscure the draft.
                    .offset(y: -(slashMenuHeight + 22))
                    .zIndex(10)
                }
            }
        }
    }
}

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

// MARK: - Visible text

enum ChatTranscriptPresentation {
    static func hasVisibleText(_ text: some StringProtocol) -> Bool {
        text.contains { !$0.isWhitespace }
    }
}
