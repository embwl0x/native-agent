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
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

enum ChatEmptyStatePresentation {
    /// A blank chat is where a first-timer decides what this app is for, so
    /// each chip names something the agent can really do today. Every one is
    /// grounded in a shipped tool: mac_calendar_list_upcoming, read_file /
    /// file_excerpt, commit_memory / recall_memory, and desk_add_item.
    static let suggestions = [
        "What's on my calendar today?",
        "Summarize a file on my Mac",
        "Remember something about me",
        "Add a task to my Desk",
    ]
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

// PATCH-2026-05-09: chat-ux-polish — Chat empty state with persona name + suggestion chips
struct ChatEmptyState: View {
    var personaName: String
    var onSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: NativeAgentSpacing.xl) {
            NativeEmptyState(
                title: "Say something to \(personaName)",
                detail: "Start with a goal, a question, or a task. Each conversation is kept separate and comes back after you quit and reopen the app.",
                systemImage: "bubble.left.and.bubble.right"
            )

            // Four chips overflow a narrow chat pane in one fixed row, so they
            // wrap instead of clipping the last capability off-screen.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: NativeAgentSpacing.sm)],
                spacing: NativeAgentSpacing.sm
            ) {
                ForEach(ChatEmptyStatePresentation.suggestions, id: \.self) { suggestion in
                    Button {
                        onSuggestion(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(NativeAgentFont.label)
                            .padding(.horizontal, NativeAgentSpacing.md)
                            .padding(.vertical, NativeAgentSpacing.sm)
                            .glassEffect(.regular.interactive(), in: Capsule())  // Liquid Feel W2
                            .overlay(Capsule().strokeBorder(NativeAgentBrand.accent.opacity(0.25), lineWidth: 0.8))
                    }
                    .buttonStyle(.borderless)
                    .help("Start with: \(suggestion)")
                }
            }
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// One compact, shared composer action hierarchy for main and detached chat.
/// Voice, screen capture, and attachments remain first-class actions (and keep
/// their command-menu shortcuts), but no longer occupy three permanent buttons
/// beside every draft. Stop and Send stay immediately visible because they are
/// the live-turn controls whose timing matters.
struct MacChatComposerControlStrip<InputContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// ui-simplify 2026-09-02 (Lane A). ON: one material, 16pt radius, a single
    /// hairline, a soft shadow, plus and mic on the left and a plain send arrow
    /// on the right — the thing you sit down at. OFF: the previous GlassCard
    /// strip, unchanged, for the `uiClassicShell` kill switch and the detached
    /// panels that have not been reshaped yet.
    var shell: Bool = false

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
    /// the owner reports it here. One value, one call site (ChatView); the
    /// detached panel is on the classic body and keeps the default.
    var isFocused: Bool = false
    let inputContent: InputContent

    init(
        shell: Bool = false,
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
        @ViewBuilder inputContent: () -> InputContent
    ) {
        self.shell = shell
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

    var body: some View {
        if shell {
            shellBody
        } else {
            classicBody
        }
    }

    // MARK: - The shell composer

    private var shellBody: some View {
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

                Spacer(minLength: 8)

                if isRunning {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(ShellType.labelSemibold)
                            .frame(width: 36, height: 36)
                            .background(
                                Color.red.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generation")
                    .accessibilityLabel("Stop generation")
                }

                Button(action: onSend) {
                    Image(systemName: "arrow.right")
                        .font(ShellType.body)
                        .frame(width: 36, height: 36)
                        .background(
                            canSend ? Color.primary.opacity(0.12) : NativeAgentShell.quietFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .foregroundStyle(canSend ? NativeAgentShell.text : NativeAgentShell.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .animation(
                    NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                    value: canSend
                )
                .help("\(sendAction.label). \(sendAction.hint)")
                .accessibilityLabel(sendAction.label)
                .accessibilityHint(sendAction.hint)
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
        .background {
            if reduceTransparency {
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
        }
        .glassEffect(
            reduceTransparency ? .identity : .regular.interactive(),
            in: RoundedRectangle(
                cornerRadius: NativeAgentShellLayout.composerRadius,
                style: .continuous
            )
        )
        // Agent, 2026-09-03: held. One hairline lift when the field has the
        // keyboard — not a tint, not a glow, not a second shadow. Reduce
        // transparency already draws this border permanently on its opaque
        // fill, so the focused state stays out of its way there.
        .overlay {
            if isFocused, !reduceTransparency {
                // Agent, 2026-09-03: the hairline only showed on the top rim
                // over glass; one step of fill reads as "held" all round.
                RoundedRectangle(
                    cornerRadius: NativeAgentShellLayout.composerRadius,
                    style: .continuous
                )
                .fill(Color.primary.opacity(0.04))
                .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isFocused)
        .contentShape(Rectangle())
        .onTapGesture { onFocusRequest?() }
    }

    // MARK: - The classic composer (unchanged)

    private var classicBody: some View {
        GlassCard(tint: NativeAgentBrand.accent.opacity(0.2)) {
            HStack(alignment: .bottom, spacing: NativeAgentSpacing.sm) {
                Menu {
                    Button(action: onToggleVoice) {
                        Label(
                            isListening ? "Stop Listening" : "Voice Input",
                            systemImage: isListening ? "mic.fill" : "mic"
                        )
                    }

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
                        Image(systemName: isListening ? "mic.fill" : "plus.circle")
                            .foregroundStyle(isListening ? Color.red : Color.primary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())

                        if pendingAttachmentCount > 0 {
                            Text("\(pendingAttachmentCount)")
                                .font(NativeAgentFont.tag)
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(NativeAgentBrand.accent, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Voice, screen capture, and attachments")
                .accessibilityLabel(optionsAccessibilityLabel)

                inputContent

                if isRunning {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(
                                Color.red.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: NativeAgentRadius.control)
                            )
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop generation")
                    .accessibilityLabel("Stop generation")
                }

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(
                            canSend ? NativeAgentBrand.accentDeep : Color.secondary.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: NativeAgentRadius.control)
                        )
                        .foregroundStyle(canSend ? .white : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .animation(
                    NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
                    value: canSend
                )
                .help("\(sendAction.label). \(sendAction.hint)")
                .accessibilityLabel(sendAction.label)
                .accessibilityHint(sendAction.hint)
            }
        }
        // The whole visible box focuses the field. contentShape covers the
        // card padding; a click on the menu/stop/send still routes to those
        // controls first, and a click already on the text field just
        // re-asserts the focus it produced.
        .contentShape(Rectangle())
        .onTapGesture { onFocusRequest?() }
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
            .animation(NativeAgentMotion.gentle, value: visible.map { $0.id })
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
                        .transition(.scale.combined(with: .opacity))
                } else if isRunning {
                    PulsingDot(color: NativeAgentBrand.accent, size: 6, animates: true)
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
            .glassEffect(.regular.interactive(), in: Capsule())  // Liquid Feel W2
            .overlay(
                Capsule()
                    .strokeBorder(
                        isCompleted ? Color.green.opacity(0.45) :
                        isRunning   ? NativeAgentBrand.accent.opacity(0.45) :
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
        .animation(NativeAgentMotion.snappy, value: isRunning)
        .animation(NativeAgentMotion.snappy, value: isCompleted)
    }
}

// PATCH-2026-05-06: multimodal-ui Sprint 3.4/3.5 — macOS NSView drop zone overlay for drag-drop
