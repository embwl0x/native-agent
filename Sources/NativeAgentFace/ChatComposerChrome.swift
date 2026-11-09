import Foundation
import SwiftUI
import AppKit
import NativeAgentShared
// Blueprint: | `ChatComposerChrome.swift` | `ComposerKeys`: editor-scoped Tab, slash, Shift-Return and attachment paste interception; shared composer chrome |

/// Intercept draft-owned keys only; preserve dispatch for ordinary typing and modified Return.
struct ComposerKeys: NSViewRepresentable {
    var active: Bool
    var move: (Bool) -> Bool
    var suggestionKey: ((UInt16) -> Bool)? = nil
    var onPaste: (([NSItemProvider]) -> Void)? = nil

    func makeNSView(context: Context) -> TabView { TabView() }
    func updateNSView(_ view: TabView, context: Context) {
        view.active = active
        view.move = move
        view.suggestionKey = suggestionKey
        view.onPaste = onPaste
    }

    static func dismantleNSView(_ view: TabView, coordinator: ()) { view.stop() }

    final class TabView: NSView {
        var active = false
        var move: ((Bool) -> Bool)?
        var suggestionKey: ((UInt16) -> Bool)?
        var onPaste: (([NSItemProvider]) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, active, !isHiddenOrHasHiddenAncestor, event.window === window,
                      let editor = window?.firstResponder as? NSTextView else { return event }
                if let onPaste,
                   event.charactersIgnoringModifiers?.lowercased() == "v",
                   event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
                    let providers = ChatAttachmentTypeResolver.clipboardAttachmentProviders()
                    guard !providers.isEmpty else { return event }
                    onPaste(providers)
                    return nil
                }
                guard !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.control) else { return event }
                if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                   !editor.hasMarkedText(), suggestionKey?(event.keyCode) == true {
                    return nil
                }
                // Keep Shift-Return in the native editor so newline insertion preserves selection, undo and binding without accepting a turn.
                if (event.keyCode == 36 || event.keyCode == 76),
                   event.modifierFlags.contains(.shift),
                   !event.modifierFlags.contains(.option),
                   !editor.hasMarkedText() {
                    editor.insertText("\n", replacementRange: editor.selectedRange())
                    return nil
                }
                guard event.keyCode == 48 else { return event }
                if event.modifierFlags.contains(.option) {
                    editor.insertText("\t", replacementRange: editor.selectedRange())
                } else if move?(event.modifierFlags.contains(.shift)) != true {
                    if event.modifierFlags.contains(.shift) {
                        window?.selectPreviousKeyView(editor)
                    } else {
                        window?.selectNextKeyView(editor)
                    }
                }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
struct AttachmentChip: View {
    var attachment: FaceAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                .font(.caption2)
            Text(attachment.name)
                .font(.caption2)
                .lineLimit(1)
            if attachment.byteCount > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button { onRemove() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct ChatProviderConnectEmptyState: View {
    static let title = "Connect an AI provider to start chatting"
    static let detail = """
    Nothing is connected yet, so a message sent now would not get a reply. \
    Open Providers to get connected. Sign in with an account you already use, \
    or add an API key.
    """
    static let actionTitle = "Open Providers"

    var onConnect: () -> Void

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            NativeEmptyState(
                title: Self.title,
                detail: Self.detail
            )

            Button(Self.actionTitle, action: onConnect)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("chat.empty-state.connect-provider")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum ChatSessionListEmptyStatePresentation {
    static func message(totalSessionCount: Int, searchQuery: String) -> String {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if totalSessionCount == 0 && query.isEmpty {
            return "No conversations yet"
        }
        return "No matching sessions"
    }
}

enum ChatEmptyStateSuggestionAction {
    @MainActor
    static func apply(
        _ suggestion: String,
        model: AppModel,
        activeSessionID: String
    ) {
        guard !activeSessionID.isEmpty else { return }
        model.composerDraft(for: activeSessionID).edit(suggestion)
    }
}

enum ChatComposerSendAction: Equatable {
    case send
    case steer

    static func resolve(isRunning: Bool) -> Self {
        isRunning ? .steer : .send
    }

    var label: String {
        switch self {
        case .send: return "Send message"
        case .steer: return "Send into reply in progress"
        }
    }

    var hint: String {
        switch self {
        case .send: return "Start a response in this conversation"
        case .steer: return "The reply in progress takes this at its next step"
        }
    }
}

#if DEBUG
/// DEBUG capture may request a card at launch because a locked Mac cannot accept clicks or keys.
func composerCardRequestedForCapture() -> ChatComposerCard? {
    switch ProcessInfo.processInfo.environment["COMPOSER_CARD_OPEN"] {
    case "context": .context
    case "model": .model
    case "effort": .effort
    case "trust": .trust
    default: nil
    }
}
#endif

/// Keep Stop and Send immediately visible because live-turn timing matters; share secondary actions across composers.
struct MacChatComposerControlStrip<InputContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    /// Detached chat has no settings menu or context receipt.
    @Environment(ComposerShellState.self) private var composerCardState: ComposerShellState?

    let isListening: Bool
    let isStopping: Bool
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let isRunning: Bool
    let canSend: () -> Bool
    let onToggleVoice: () -> Void
    let onDiscardVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    /// Focus card padding without taking hit areas from interactive children.
    var onFocusRequest: (() -> Void)?
    /// Use the text field owner's focus report so the composer reflects actual editor state.
    var isFocused: Bool = false
    var sessionId: String? = nil
    var showsConversationSettings: Bool = false
    var focusWordToken: Int = 0
    let inputContent: InputContent

    init(
        isListening: Bool,
        isStopping: Bool,
        screenCaptureAllowed: Bool,
        screenCaptureDisabled: Bool,
        pendingAttachmentCount: Int,
        isRunning: Bool,
        canSend: @escaping () -> Bool,
        onToggleVoice: @escaping () -> Void,
        onDiscardVoice: @escaping () -> Void,
        onCaptureScreen: @escaping () -> Void,
        onAttach: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onSend: @escaping () -> Void,
        onFocusRequest: (() -> Void)? = nil,
        isFocused: Bool = false,
        sessionId: String? = nil,
        showsConversationSettings: Bool = false,
        focusWordToken: Int = 0,
        @ViewBuilder inputContent: () -> InputContent
    ) {
        self.isListening = isListening
        self.isStopping = isStopping
        self.screenCaptureAllowed = screenCaptureAllowed
        self.screenCaptureDisabled = screenCaptureDisabled
        self.pendingAttachmentCount = pendingAttachmentCount
        self.isRunning = isRunning
        self.canSend = canSend
        self.onToggleVoice = onToggleVoice
        self.onDiscardVoice = onDiscardVoice
        self.onCaptureScreen = onCaptureScreen
        self.onAttach = onAttach
        self.onStop = onStop
        self.onSend = onSend
        self.onFocusRequest = onFocusRequest
        self.isFocused = isFocused
        self.sessionId = sessionId
        self.showsConversationSettings = showsConversationSettings
        self.focusWordToken = focusWordToken
        self.inputContent = inputContent()
    }

    private var optionsAccessibilityLabel: String {
        var parts = ["Message options"]
        if isListening { parts.append("voice input active") }
        if pendingAttachmentCount > 0 {
            parts.append("\(pendingAttachmentCount) attachment\(pendingAttachmentCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputContent
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Menu {
                    Button {
                        if screenCaptureAllowed { onCaptureScreen() }
                        else { SettingsLink.open(.trust) }
                    } label: {
                        Label(
                            screenCaptureAllowed ? "Show Agent My Screen" : "Enable Screen Capture in Trust",
                            systemImage: "camera.viewfinder"
                        )
                    }
                    .disabled(screenCaptureAllowed && screenCaptureDisabled)
                    Button(action: onAttach) {
                        Label("Attach Image or File…", systemImage: "paperclip")
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "plus")
                            .font(ShellType.bodyMedium)
                            .foregroundStyle(NativeAgentShell.secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                        if pendingAttachmentCount > 0 {
                            Text("\(pendingAttachmentCount)")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(NativeAgentBrand.accent, in: Circle())
                                .offset(x: 4, y: -2)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Screen capture and attachments")
                .accessibilityLabel(optionsAccessibilityLabel)

                Button(action: onToggleVoice) {
                    Image(systemName: isListening ? "mic.fill" : "mic")
                        .font(ShellType.bodyMedium)
                        .foregroundStyle(isListening ? Color.red : NativeAgentShell.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isListening ? "Stop listening" : "Voice input")
                .accessibilityLabel(isListening ? "Stop listening" : "Voice input")
                .disabled(isStopping)

                if isListening {
                    if isStopping {
                        Text("Waiting for transcript")
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                    Button(action: onDiscardVoice) {
                        Image(systemName: "xmark")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .help("Discard voice input")
                    .accessibilityLabel("Discard voice input")
                }

                // Let settings words own the row so cards anchor to the opening word and remain inside the window.
                if showsConversationSettings {
                    ChatComposerSettings(focusWordToken: focusWordToken)
                } else {
                    Spacer(minLength: 0)
                }

                MacChatComposerSendButton(isRunning: isRunning, canSend: canSend, onStop: onStop, onSend: onSend)
            }
        }
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.top, 12)
        .padding(.bottom, 11)
        // Use opaque fill for reduced transparency and reliable bitmap capture.
        .background {
            // Focus only padding; refocusing the field on mouse-up can restart its editor and move the caret before new typing.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    composerCardState?.dismiss()
                    onFocusRequest?()
                }
            if reduceTransparency || quietOffscreenRead {
                RoundedRectangle(
                    cornerRadius: NativeAgentShellLayout.composerRadius,
                    style: .continuous
                )
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: NativeAgentShellLayout.composerRadius,
                        style: .continuous
                    )
                    .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                }
            }
            // Place glow below draft text so it remains readable.
            HazeBottomGlow(cornerRadius: NativeAgentShellLayout.composerRadius)
            ThinkingGlow(kind: .shimmer, cornerRadius: NativeAgentShellLayout.composerRadius, sessionId: sessionId)
        }
        // Avoid interactive glass because field clicks dim the entire card on macOS 27.
        .glassEffect(
            reduceTransparency || quietOffscreenRead ? .identity : HouseGlass.plate,
            in: RoundedRectangle(
                cornerRadius: NativeAgentShellLayout.composerRadius,
                style: .continuous
            )
        )
        // Keep held keyboard focus visible on glass and opaque fill.
        .overlay {
            RoundedRectangle(
                cornerRadius: NativeAgentShellLayout.composerRadius,
                style: .continuous
            )
            .strokeBorder(NativeAgentShell.text, lineWidth: isFocused ? 2 : 0)
            .animation(reduceMotion ? nil : NativeAgentMotion.quick, value: isFocused)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // Keep the travelling rim outside focus animation scope so it owns its fade.
        .overlay { ThinkingGlow(kind: .rim, cornerRadius: NativeAgentShellLayout.composerRadius, sessionId: sessionId) }
        #if DEBUG
        .onAppear {
            if showsConversationSettings, let card = composerCardRequestedForCapture(),
               let state = composerCardState {
                state.open(card)
            }
        }
        #endif
        // Reaching for the draft dismisses its open card.
        .onChange(of: isFocused) { _, focused in
            if focused { composerCardState?.dismiss() }
        }
        .onChange(of: isRunning) { _, running in
            if running { composerCardState?.dismiss() }
        }
    }

}

/// Availability changes redraw the button without rebuilding composer settings or text entry.
private struct MacChatComposerSendButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isRunning: Bool
    let canSend: () -> Bool
    let onStop: () -> Void
    let onSend: () -> Void

    private var sendAction: ChatComposerSendAction { .resolve(isRunning: isRunning) }

    /// Keep the circle stable while swapping Send and Stop; Reduce Motion disables the glyph animation.
    private var glyphSwap: AnyTransition {
        reduceMotion ? .identity
            : .scale(scale: 0.5).combined(with: .opacity).animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.2))
    }

    var body: some View {
        let canSend = self.canSend()
        // Return sends into the live conversation while Stop keeps its button.
        let lit = isRunning || canSend
        Button(action: isRunning ? onStop : onSend) {
            ZStack {
                if isRunning {
                    Image(systemName: "stop.fill")
                        .font(ShellType.label)
                        .transition(glyphSwap)
                } else {
                    Image(systemName: "arrow.right")
                        .font(ShellType.body)
                        .transition(glyphSwap)
                }
            }
            .frame(width: 36, height: 36)
            .background(lit ? Color.primary.opacity(0.12) : NativeAgentShell.quietFill, in: Circle())
            .foregroundStyle(lit ? NativeAgentShell.text : NativeAgentShell.tertiary)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .shellKeyboardTarget(.send)
        .disabled(!lit)
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.quick, reduceMotion: reduceMotion),
            value: lit
        )
        .help(isRunning ? "Stop generation" : "\(sendAction.label). \(sendAction.hint)")
        .accessibilityLabel(isRunning ? "Stop generation" : sendAction.label)
        .accessibilityHint(isRunning ? "" : sendAction.hint)
        .contextMenu {
            if isRunning {
                Button(sendAction.label, action: onSend)
                    .disabled(!canSend)
            }
        }
    }
}

/// Share one glass tray with the composer so inner rows do not stack glass.
struct ChatComposerTray: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Quiet capture needs an opaque tray, as with the composer.
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Namespace private var glass

    let attachments: [FaceAttachment]
    let onRemoveAttachment: (String) -> Void
    let onGoTo: (String) -> Void

    /// Keep the tray gap inside the merge distance so both glass shapes fuse.
    static let gap: CGFloat = 6
    static let radius: CGFloat = 16

    /// Animate tray identity changes only so a chip's wording cannot move the tray.
    private struct Contents: Equatable {
        var attachments: [String]
        var others: [String]
        var isEmpty: Bool {
            attachments.isEmpty && others.isEmpty
        }
    }

    private var contents: Contents {
        Contents(
            attachments: attachments.map(\.id),
            others: appModel.turnSessionsFace?.movements(outside: appModel.activeChatSessionId).map(\.id) ?? []
        )
    }

    var body: some View {
        let contents = contents
        VStack(spacing: 0) {
            if !contents.isEmpty {
                rows(contents)
                    .padding(.horizontal, NativeAgentShellLayout.roomGutter)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if reduceTransparency || quietOffscreenRead {
                            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                        .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
                                }
                        }
                    }
                    .glassEffect(
                        reduceTransparency || quietOffscreenRead ? .identity : HouseGlass.plate,
                        in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    )
                    .glassEffectID("composer.tray", in: glass)
                    .glassEffectTransition(reduceMotion ? .identity : .materialize)
                    .transition(.opacity)
                    .padding(.bottom, Self.gap)
            }
        }
        .animation(NativeAgentMotion.respecting(NativeAgentMotion.glide, reduceMotion: reduceMotion),
                   value: contents)
    }

    private func rows(_ contents: Contents) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NativeAgentSpacing.sm) {
                            ForEach(attachments, id: \.id) { att in
                                AttachmentChip(attachment: att) { onRemoveAttachment(att.id) }
                                    .transition(.opacity)
                            }
                        }
                    }
                    if attachments.count >= 2 {
                        Text("\(appModel.agentDisplayName) will treat these as one combined input.")
                            .font(ShellType.caption)
                            .foregroundStyle(NativeAgentShell.secondary)
                    }
                }
                .transition(.opacity)
            }
            if !contents.others.isEmpty {
                MacChatOtherSessionsBanner(
                    sessionID: appModel.activeChatSessionId,
                    onGoTo: onGoTo
                )
            }
        }
    }
}
