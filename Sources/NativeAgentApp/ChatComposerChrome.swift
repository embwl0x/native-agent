import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

/// Intercept Tab and open slash suggestions while this draft owns the editor.
/// Other typing and modified Return retain their existing dispatch.
struct ComposerTabKeyHandler: NSViewRepresentable {
    var active: Bool
    var move: (Bool) -> Bool
    var suggestionKey: ((UInt16) -> Bool)? = nil

    func makeNSView(context: Context) -> TabView { TabView() }
    func updateNSView(_ view: TabView, context: Context) {
        view.active = active
        view.move = move
        view.suggestionKey = suggestionKey
    }

    static func dismantleNSView(_ view: TabView, coordinator: ()) { view.stop() }

    final class TabView: NSView {
        var active = false
        var move: ((Bool) -> Bool)?
        var suggestionKey: ((UInt16) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, active, !isHiddenOrHasHiddenAncestor, event.window === window,
                      !event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.control),
                      let editor = window?.firstResponder as? NSTextView else { return event }
                if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                   !editor.hasMarkedText(), suggestionKey?(event.keyCode) == true {
                    return nil
                }
                // SwiftUI's vertical TextField submits Shift-Return too. Keep
                // it in the native editor so selection, undo and draft binding
                // receive a newline without accepting or queuing a turn.
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
    var attachment: MultimodalAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: attachment.type == "image" ? "photo" : "doc")
                .font(.caption2)
            Text(attachment.name ?? (attachment.type == "image" ? "image" : "file"))
                .font(.caption2)
                .lineLimit(1)
            if attachment.byteSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
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

// D1 (2026-08-28): a blank chat on a machine with no connected provider used
// to invite a first message ("Say something to …") that could only dead-end in
// "No reply came back". The blank slate now branches: with a provider, the D6
// capability chips; without one, the connect prompt — the same honest guidance
// `missingProviderChatGuidance()` gives AFTER a failed send, moved to before it.
enum ChatEmptyStateMode: Equatable, Sendable {
    case connectProvider
    case suggestions

    static func mode(hasUsableProvider: Bool) -> Self {
        hasUsableProvider ? .suggestions : .connectProvider
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
                detail: Self.detail,
                systemImage: "server.rack"
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
        activeSessionID: String,
        draftText: inout String,
        draftSessionID: inout String
    ) {
        guard !activeSessionID.isEmpty else { return }
        model.injectChatDraft(suggestion, sessionId: activeSessionID)
        draftText = suggestion
        draftSessionID = activeSessionID
    }
}

enum ChatComposerSendAction: Equatable {
    case send
    case queueNext
    case appendToQueue
    case appendToPausedQueue

    static func resolve(isRunning: Bool, hasQueuedTurns: Bool, isQueuePaused: Bool) -> Self {
        if hasQueuedTurns { return isQueuePaused ? .appendToPausedQueue : .appendToQueue }
        return isRunning ? .queueNext : .send
    }

    var label: String {
        switch self {
        case .send: return "Send message"
        case .queueNext: return "Queue message to send next"
        case .appendToQueue: return "Add message to queue"
        case .appendToPausedQueue: return "Add message to paused queue"
        }
    }

    var hint: String {
        switch self {
        case .send: return "Start a response in this conversation"
        case .queueNext: return "Wait for the current response to finish"
        case .appendToQueue: return "Run after the messages already queued in this conversation"
        case .appendToPausedQueue: return "The queue stays paused. Use Send next to resume it."
        }
    }
}

#if DEBUG
/// Capture affordance only: a locked Mac takes neither a click nor a key, so a
/// card can be asked for at launch while the frames are being taken. DEBUG-only,
/// and never a product behaviour.
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

/// One compact, shared composer action hierarchy for main and detached chat.
/// Voice, screen capture, and attachments remain first-class actions (and keep
/// their command-menu shortcuts), but no longer occupy three permanent buttons
/// beside every draft. Stop and Send stay immediately visible because they are
/// the live-turn controls whose timing matters.
struct MacChatComposerControlStrip<InputContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead

    /// Which settings card is open. Shared with the card layer that draws it
    /// above the transcript; absent in the detached panel and the snapshots.
    @Environment(ComposerShellState.self) private var composerCardState: ComposerShellState?



    let isListening: Bool
    let screenCaptureAllowed: Bool
    let screenCaptureDisabled: Bool
    let pendingAttachmentCount: Int
    let isRunning: Bool
    let hasQueuedTurns: Bool
    let isQueuePaused: Bool
    let canSend: Bool
    let onToggleVoice: () -> Void
    let onCaptureScreen: () -> Void
    let onAttach: () -> Void
    let onStop: () -> Void
    let onSend: () -> Void
    /// User 2026-08-20: the visible composer box is taller than the single-line
    /// text field's own hit area, so clicks in the upper region did nothing.
    /// The whole card is now a focus target; interactive children (menu,
    /// stop/send) keep winning inside their own bounds.
    var onFocusRequest: (() -> Void)?
    /// Agent, 2026-09-03: the composer must not look identical with the
    /// keyboard in it as it does at rest. The view cannot own the focus —
    /// the `@FocusState` belongs to the chat that owns the text field — so
    /// the owner reports it here, including the detached panel.
    var isFocused: Bool = false
    var sessionId: String? = nil
    var showsConversationSettings: Bool = false
    /// Incremented by the draft when Tab should move into the settings words.
    var focusWordToken: Int = 0
    let inputContent: InputContent

    init(
        isListening: Bool,
        screenCaptureAllowed: Bool,
        screenCaptureDisabled: Bool,
        pendingAttachmentCount: Int,
        isRunning: Bool,
        hasQueuedTurns: Bool = false,
        isQueuePaused: Bool = false,
        canSend: Bool,
        onToggleVoice: @escaping () -> Void,
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
        self.screenCaptureAllowed = screenCaptureAllowed
        self.screenCaptureDisabled = screenCaptureDisabled
        self.pendingAttachmentCount = pendingAttachmentCount
        self.isRunning = isRunning
        self.hasQueuedTurns = hasQueuedTurns
        self.isQueuePaused = isQueuePaused
        self.canSend = canSend
        self.onToggleVoice = onToggleVoice
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

    private var sendAction: ChatComposerSendAction {
        .resolve(isRunning: isRunning, hasQueuedTurns: hasQueuedTurns, isQueuePaused: isQueuePaused)
    }

    /// Send ↔ Stop: the glyph swaps, the circle stays. None under Reduce Motion.
    private var glyphSwap: AnyTransition {
        reduceMotion ? .identity
            : .scale(scale: 0.5).combined(with: .opacity).animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            inputContent
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Menu {
                    Button(action: onCaptureScreen) {
                        Label(
                            screenCaptureAllowed ? "Show Agent My Screen" : "Enable Screen Capture in Trust",
                            systemImage: "camera.viewfinder"
                        )
                    }
                    .disabled(screenCaptureDisabled)
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

                // The words own the rest of the row so a card can be anchored
                // to the word that opened it and clamped to the room's edge at
                // any window width.
                if showsConversationSettings {
                    ChatComposerSettings(focusWordToken: focusWordToken)
                } else {
                    Spacer(minLength: 0)
                }

                // Alive glass, 2026-09-23: Stop takes Send's slot while a turn
                // runs — same place, same size — so nothing on the row moves
                // when a turn starts. A calm circle in the send button's fill,
                // the glyph in the text colour; red was the loudest thing on
                // screen. Return still queues a draft during a turn.
                // Wave 3 (after Grok): one circle; only the glyph changes,
                // scaling from half size as it fades, 200ms quint-out.
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
            }
        }
        // The room's gutter, inside the glass: the field's first character
        // lands on the first character of her replies and the box's inner
        // right edge on their last (708 + 2 x 16 = the 740 column).
        // Agent, 2026-09-03: the box was 87,360px of fill against 76,291px of
        // ink in a full screen of her reply — the emptiest object on screen
        // was also the heaviest. Three of those points come back off the
        // vertical padding (91 -> 88).
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.top, 12)
        .padding(.bottom, 11)
        // User, 2026-09-03: the composer floats over content — the functional
        // layer — so it is real glass now, not a painted slab. Glass carries
        // its own lensing and shadow, so the hairline and the hand shadow are
        // gone with it. Reduce transparency still gets the opaque fill: that
        // setting asks for more opacity, never less.
        // A quiet screenshot draws that opaque fill too: tinted glass drawn
        // into a bitmap blanks the WHOLE capture, not just itself, so the
        // chat page came back as an empty (black) image.
        .background {
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
            // User, 2026-09-23 ("alive glass"): a faint inner glow of the haze
            // along the bottom edge, and while she thinks before replying, a
            // caustic shimmer drifting through the glass. Both sit between the
            // glass and the words, so neither washes the draft. Leaves only:
            // see ThinkingGlow.swift.
            HazeBottomGlow(cornerRadius: NativeAgentShellLayout.composerRadius)
            ThinkingGlow(kind: .shimmer, cornerRadius: NativeAgentShellLayout.composerRadius, sessionId: sessionId)
        }
        // The card holds independent controls; interactive glass makes a
        // click in the field press/dim the entire card on macOS 27.
        .glassEffect(
            reduceTransparency || quietOffscreenRead ? .identity : HouseGlass.plate,
            in: RoundedRectangle(
                cornerRadius: NativeAgentShellLayout.composerRadius,
                style: .continuous
            )
        )
        // Held keyboard focus stays visible on both glass and the opaque plate.
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
        // The thinking rim: one arc of light travelling round the edge. Outside
        // the focus animation's scope; it carries its own fade.
        .overlay { ThinkingGlow(kind: .rim, cornerRadius: NativeAgentShellLayout.composerRadius, sessionId: sessionId) }
        .contentShape(Rectangle())
        .onTapGesture {
            composerCardState?.dismiss()
            onFocusRequest?()
        }
        #if DEBUG
        .onAppear {
            if showsConversationSettings, let card = composerCardRequestedForCapture(),
               let state = composerCardState {
                state.activePane = .opening(
                    card,
                    provider: ProcessInfo.processInfo.environment["COMPOSER_FLYOUT_PROVIDER"] ?? ""
                )
            }
        }
        #endif
        // Reaching for the draft is the same gesture as putting a card away.
        .onChange(of: isFocused) { _, focused in
            if focused { composerCardState?.dismiss() }
        }
        .onChange(of: isRunning) { _, running in
            if running { composerCardState?.dismiss() }
        }
    }

}

// PATCH-2026-05-09: nextgen-surface — Horizontal row of suggested NextGen action chips above composer
enum NextGenActionChipsPresentation {
    static let maxVisible = 4

    static func normalizedID(_ actionID: String) -> String {
        actionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isTracked(_ actionID: String, in ids: Set<String>) -> Bool {
        ids.contains(actionID) || ids.contains(normalizedID(actionID))
    }

    /// This is the same executor-backed filter used by the full Capabilities
    /// surface. A chat chip is an executable promise, so catalog-only,
    /// completed, or non-dry-run rows cannot enter this presentation.
    static func eligibleActions(summary: NextGenSummary?) -> [NextGenAction] {
        var seenIDs = Set<String>()
        return (summary?.actions ?? []).filter { action in
            let actionID = normalizedID(action.id)
            return action.dryRunAvailable == true
                && action.status?.lowercased() != "completed"
                && NativeClient.isNextGenActionBacked(actionID)
                && seenIDs.insert(actionID).inserted
        }
    }

    static func visibleActions(summary: NextGenSummary?) -> [NextGenAction] {
        Array(eligibleActions(summary: summary).prefix(maxVisible))
    }

    static func hasMore(summary: NextGenSummary?) -> Bool {
        eligibleActions(summary: summary).count > maxVisible
    }

    static func canRun(
        actionID: String,
        runningIDs: Set<String>,
        completedIDs: Set<String>,
        isGlobalActionRunning: Bool
    ) -> Bool {
        let id = normalizedID(actionID)
        return !id.isEmpty
            && NativeClient.isNextGenActionBacked(id)
            && !isGlobalActionRunning
            && !isTracked(actionID, in: runningIDs)
            && !isTracked(actionID, in: completedIDs)
    }
}

/// Fluid glass A2: what waits above the composer — queued sends, pending
/// attachments, chats running elsewhere, suggested actions — is ONE tray of
/// the composer's own glass, fused to its top edge. It used to be four rows,
/// each at its own width (760 against the room's 740), stacked over the
/// composer and pushing the transcript as they came and went. The caller puts
/// this and the composer in one `GlassEffectContainer`, so the two read as a
/// single object; the tray materializes, grows and shrinks on a smooth spring.
/// Glass is the tray's alone: nothing inside it wears glass of its own.
struct ChatComposerTray: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// A quiet screenshot takes the opaque tray, as the composer does.
    @Environment(\.quietOffscreenRead) private var quietOffscreenRead
    @Namespace private var glass

    let sessionId: String
    let isBusy: Bool
    let attachments: [MultimodalAttachment]
    let onRemoveAttachment: (String) -> Void
    let otherRunning: [String]
    let routes: ([String]) -> [MacChatRunningSessionRoute]
    let onGoTo: (String) -> Void
    let onStop: (String) -> Void

    /// The gap between the tray and the composer under it. Inside the
    /// container's merge distance, so the two glass shapes fuse.
    static let gap: CGFloat = 6
    static let radius: CGFloat = 16

    /// What is in the tray, by identity. The spring keys on this and nothing
    /// else, so a chip that only changes its words does not move the tray.
    private struct Contents: Equatable {
        var queued: [String]
        var attachments: [String]
        var others: [String]
        var actions: [String]
        var isEmpty: Bool {
            queued.isEmpty && attachments.isEmpty && others.isEmpty && actions.isEmpty
        }
    }

    private var contents: Contents {
        Contents(
            queued: ChatQueuePresentation.visibleTurns(
                appModel.engine.turns.queued(for: sessionId)).map(\.id),
            attachments: attachments.map(\.id),
            others: otherRunning,
            actions: NextGenActionChipsPresentation.visibleActions(
                summary: appModel.nextGenSummary).map(\.id)
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
            if !contents.queued.isEmpty {
                ChatQueuedTurnsView(sessionId: sessionId, isBusy: isBusy)
                    .transition(.opacity)
            }
            if !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NativeAgentSpacing.sm) {
                            ForEach(attachments) { att in
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
                    otherRunning: otherRunning,
                    routes: routes,
                    onGoTo: onGoTo,
                    onStop: onStop
                )
            }
            if !contents.actions.isEmpty {
                NextGenActionChipsRow(appModel: appModel)
                    .transition(.opacity)
            }
        }
    }
}

struct NextGenActionChipsRow: View {
    var appModel: AppModel
    /// Test-only injection remains behind the row's production tap gate. A
    /// nil runner always dispatches through the real app model.
    var actionRunner: (@MainActor (String) async -> Bool)? = nil

    // Per-chip running state (actionId -> true while running)
    @State private var runningIds: Set<String> = []
    // Per-chip completed state (actionId -> timestamp) for checkmark flash
    @State private var completedIds: Set<String> = []

    private var visibleActions: [NextGenAction] {
        NextGenActionChipsPresentation.visibleActions(summary: appModel.nextGenSummary)
    }

    private var hasMore: Bool {
        NextGenActionChipsPresentation.hasMore(summary: appModel.nextGenSummary)
    }

    var body: some View {
        let visible = visibleActions
        guard !visible.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NativeAgentSpacing.sm) {
                    ForEach(visible) { action in
                        NextGenChip(
                            action: action,
                            isRunning: NextGenActionChipsPresentation.isTracked(
                                action.id, in: runningIds
                            ),
                            isCompleted: NextGenActionChipsPresentation.isTracked(
                                action.id, in: completedIds
                            ),
                            isGlobalActionRunning: appModel.isRunningNextGenAction
                        ) {
                            guard NextGenActionChipsPresentation.canRun(
                                actionID: action.id,
                                runningIDs: runningIds,
                                completedIDs: completedIds,
                                isGlobalActionRunning: appModel.isRunningNextGenAction
                            ) else { return }
                            let actionID = NextGenActionChipsPresentation.normalizedID(action.id)
                            runningIds.insert(actionID)
                            Task { @MainActor in
                                let succeeded: Bool
                                if let actionRunner {
                                    succeeded = await actionRunner(actionID)
                                } else {
                                    succeeded = await appModel.runNextGenAction(id: actionID, dryRun: true)
                                }
                                runningIds.remove(actionID)
                                if succeeded {
                                    completedIds.insert(actionID)
                                    // Flash checkmark for 2s then clear.
                                    Task {
                                        try? await Task.sleep(for: .seconds(2))
                                        completedIds.remove(actionID)
                                    }
                                }
                            }
                        }
                    }
                    if hasMore {
                        Button {
                            NotificationCenter.default.post(name: .openNextGenRequest, object: nil)
                        } label: {
                            Text("More\u{2026}")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, NativeAgentSpacing.sm)
                                .padding(.vertical, NativeAgentSpacing.xs)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("chat.nextgen-more-actions")
                        .help("View all NextGen actions in Capabilities")
                    }
                }
            }
            .animation(NativeAgentMotion.standard, value: visible.map { $0.id })
        )
    }
}

struct NextGenChip: View {
    var action: NextGenAction
    var isRunning: Bool
    var isCompleted: Bool
    var isGlobalActionRunning: Bool
    var onTap: () -> Void

    private var chipIcon: String {
        switch action.kind?.lowercased() {
        case let k where k?.contains("build") == true || k?.contains("repair") == true:
            return "wrench.and.screwdriver"
        case let k where k?.contains("audit") == true || k?.contains("check") == true:
            return "doc.text.magnifyingglass"
        case let k where k?.contains("generate") == true || k?.contains("gen") == true:
            return "sparkles"
        default:
            return "play.fill"
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: NativeAgentSpacing.xs) {
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.green)
                        .transition(NativeAgentMotion.reveal())
                } else if isRunning {
                    PulsingDot(color: NativeAgentShell.secondary, size: 6, animates: true)
                } else {
                    Image(systemName: chipIcon)
                        .font(NativeAgentFont.tag)
                        .foregroundStyle(.secondary)
                }
                Text(action.displayName.prefix(30))
                    .font(NativeAgentFont.tag)
                    .foregroundStyle(isCompleted ? .green : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, NativeAgentSpacing.sm)
            .padding(.vertical, NativeAgentSpacing.xs)
            // Fluid glass A2: the chips ride in the composer tray's glass, so
            // they take a fill, not glass of their own (never glass on glass).
            .background(NativeAgentShell.softFill, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isCompleted ? Color.green.opacity(0.45) :
                        isRunning   ? NativeAgentShell.secondary.opacity(0.45) :
                                      Color.primary.opacity(0.10),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: isCompleted ? .green.opacity(0.15) : .clear, radius: 4)
        }
        .buttonStyle(.borderless)
        .disabled(isRunning || isCompleted || isGlobalActionRunning)
        .accessibilityIdentifier("chat.nextgen-action.\(action.id)")
        .help(action.displayDetail)
        .animation(NativeAgentMotion.quick, value: isRunning)
        .animation(NativeAgentMotion.quick, value: isCompleted)
    }
}

// PATCH-2026-05-06: multimodal-ui Sprint 3.4/3.5 — macOS NSView drop zone overlay for drag-drop
