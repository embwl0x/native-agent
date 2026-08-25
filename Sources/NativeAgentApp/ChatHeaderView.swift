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

enum ChatHeaderPresentation {
    struct Metadata: Equatable {
        let messageCount: String
        let showsContextReady: Bool
    }

    static func title(for session: ChatSession?) -> String {
        let title = session?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Chat" : title
    }

    static func messageCount(_ count: Int?) -> String {
        let value = count ?? 0
        return value == 1 ? "1 message" : "\(value) messages"
    }

    static func hasContextFingerprint(_ fingerprint: String?) -> Bool {
        hasReceiptComponent(fingerprint)
    }

    /// The Context Receipt panel can identify a completed assembly by either
    /// its content fingerprint or its run ID.  Keep the header toggle on that
    /// same truth boundary so a run-ID-only receipt does not leave a usable
    /// panel permanently disabled.
    static func hasContextReceiptIdentity(fingerprint: String?, runID: String?) -> Bool {
        hasReceiptComponent(fingerprint) || hasReceiptComponent(runID)
    }

    static func contextReceiptToggleIsEnabled(_ context: ContextReceipt?) -> Bool {
        guard let context else { return false }
        return hasContextReceiptIdentity(
            fingerprint: context.fingerprint,
            runID: context.runId
        )
    }

    /// Shared action boundary for the header's receipt disclosure.  Keeping
    /// the eligibility check here means the visible disabled state and the
    /// state transition cannot disagree when a receipt is incomplete.
    static func contextReceiptVisibilityAfterToggle(
        isVisible: Bool,
        context: ContextReceipt?
    ) -> Bool {
        guard contextReceiptToggleIsEnabled(context) else { return isVisible }
        return !isVisible
    }

    static func metadata(count: Int?, fingerprint: String?, runID: String? = nil) -> Metadata {
        Metadata(
            messageCount: messageCount(count),
            showsContextReady: hasContextReceiptIdentity(fingerprint: fingerprint, runID: runID)
        )
    }

    private static func hasReceiptComponent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ChatHeaderRenamePresentation {
    static func belongsToCurrentSession(capturedSessionID: String?, renderedSessionID: String?) -> Bool {
        capturedSessionID != nil && capturedSessionID == renderedSessionID
    }
}

/// The chat header's small NextGen affordance is a projection of the same
/// summary/phase state that powers Capabilities. It deliberately has no
/// optimistic local state: an absent or malformed phase source produces no
/// pill instead of a plausible-looking "ready" indicator.
enum ChatHeaderNextGenPillPresentation {
    struct Model: Equatable {
        let label: String
        let tooltip: String
        let status: String

        var accessibilityLabel: String { "NextGen status: \(tooltip)" }
    }

    static func model(summary: NextGenSummary?, phases: [NextGenPhase]) -> Model? {
        let summaryPhase = normalized(summary?.currentPhaseName)
            ?? normalized(summary?.currentPhaseId)
        let fallbackPhase = phases.first(where: { phase in
            phase.displayStatus.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() != "ready"
        }) ?? phases.last
        guard let rawPhase = summaryPhase ?? fallbackPhase.map(\.displayName) else { return nil }
        let phase = normalized(rawPhase)
        guard let phase else { return nil }

        let status = normalized(summary?.status)
            ?? normalized(summary?.readiness)
            ?? normalized(fallbackPhase?.displayStatus)
            ?? "warn"
        let total = positive(summary?.totalPhaseCount) ?? (phases.isEmpty ? nil : phases.count)
        let reportedReady = nonnegative(summary?.readyPhaseCount)
            ?? phases.filter { $0.displayStatus.lowercased() == "ready" }.count
        let ready = total.map { min(reportedReady, $0) } ?? reportedReady
        let tooltip = total.map { "Phase \(ready) of \($0) · \(status)" }
            ?? "NextGen · \(status)"
        let label = phase.lowercased().hasPrefix("phase ")
            ? phase
            : "Phase \(phase)"
        return Model(label: label, tooltip: tooltip, status: status)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

// PATCH-2026-05-07: ui-polish ChatHeaderView — gradient agent name + aurora background
// PATCH-2026-05-09: nextgen-surface — NextGen status pill on the right side of header
struct ChatHeaderView: View {
    @Environment(AppModel.self) private var appModel
    var session: ChatSession?
    var compiled: CompiledPersonality?
    var context: ContextReceipt?
    var nextGenSummary: NextGenSummary? = nil
    var nextGenPhases: [NextGenPhase] = []
    @Binding var showContext: Bool
    @Binding var showConversationControls: Bool
    var onRename: (String) -> Void = { _ in }
    var onFind: () -> Void = {}
    @State private var isRenamingTitle = false
    @State private var titleDraft = ""
    @State private var renameSessionID: String? = nil
    @FocusState private var titleFocused: Bool

    private func nextGenPillColor(status: String) -> Color {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ready":       return .green
        case "in_progress": return .orange
        case "planning":    return .blue
        default:            return .purple
        }
    }

    private var sessionTitle: String {
        ChatHeaderPresentation.title(for: session)
    }
    private var headerMetadata: ChatHeaderPresentation.Metadata {
        ChatHeaderPresentation.metadata(
            count: session?.messageCount,
            fingerprint: context?.fingerprint,
            runID: context?.runId
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                headerTitle
                HStack(spacing: 4) {
                    Text(headerMetadata.messageCount)
                    if let source = session?.source {
                        Text("·")
                        Text(source == "app" ? "Mac app" : source.capitalized)
                    }
                    if let compiled {
                        Text("·")
                        Text(appModel.agentDisplayName)
                            .help("Persona fingerprint \(compiled.fingerprint) · Surface \(compiled.surface)")
                    }
                    if headerMetadata.showsContextReady, let fingerprint = context?.fingerprint {
                        Text("· Context ready")
                            .help("Context fingerprint \(fingerprint)")
                    }
                }
                .font(NativeAgentFont.tag)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if let nextGenPill = ChatHeaderNextGenPillPresentation.model(
                summary: nextGenSummary,
                phases: nextGenPhases
            ) {
                Button {
                    NotificationCenter.default.post(name: .openNextGenRequest, object: nil)
                } label: {
                    Text(nextGenPill.label)
                        .font(NativeAgentFont.tag)
                        .padding(.horizontal, NativeAgentSpacing.sm)
                        .padding(.vertical, NativeAgentSpacing.xs)
                        .background(nextGenPillColor(status: nextGenPill.status).opacity(0.18), in: Capsule())
                        .foregroundStyle(nextGenPillColor(status: nextGenPill.status))
                        .overlay(Capsule().strokeBorder(nextGenPillColor(status: nextGenPill.status).opacity(0.35), lineWidth: 0.7))
                }
                .buttonStyle(.borderless)
                .help(nextGenPill.tooltip)
                .accessibilityLabel(nextGenPill.accessibilityLabel)
                .accessibilityIdentifier("chat-header-nextgen-pill")
                .accessibilityHint("Open NextGen in Capabilities")
            }

            Button(action: onFind) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Search conversation (Command-F)")
            .accessibilityLabel("Search conversation")

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    showConversationControls.toggle()
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(showConversationControls ? NativeAgentBrand.accentDeep : Color.secondary)
            .help(showConversationControls ? "Hide conversation settings" : "Conversation settings")
            // Keep the control's AX identity stable across the state change.
            // A changing label makes an automation client lose the very
            // element it just pressed; state belongs in its value instead.
            .accessibilityLabel("Conversation settings")
            .accessibilityValue(showConversationControls ? "Shown" : "Hidden")
            .accessibilityHint("Shows or hides the conversation brain controls")
            .accessibilityIdentifier("chat.header.conversation-settings-toggle")

            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    showContext = ChatHeaderPresentation.contextReceiptVisibilityAfterToggle(
                        isVisible: showContext,
                        context: context
                    )
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(showContext ? NativeAgentBrand.accentDeep : Color.secondary)
            .disabled(!ChatHeaderPresentation.contextReceiptToggleIsEnabled(context))
            .help(showContext ? "Hide context receipt" : "Show context receipt")
            .accessibilityLabel(showContext ? "Hide context receipt" : "Show context receipt")
        }
        .onAppear {
            titleDraft = sessionTitle
        }
        .onChange(of: session?.id) { _, _ in
            if !isRenamingTitle {
                titleDraft = sessionTitle
            }
        }
        .onChange(of: session?.title) { _, _ in
            if !isRenamingTitle {
                titleDraft = sessionTitle
            }
        }
    }

    @ViewBuilder
    private var headerTitle: some View {
        if isRenamingTitle {
            HStack(spacing: 4) {
                TextField("Session name", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(NativeAgentFont.section)
                    .frame(maxWidth: 420, alignment: .leading)
                    .focused($titleFocused)
                    .onSubmit {
                        commitTitleRename()
                    }
                    .onExitCommand {
                        cancelTitleRename()
                    }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused && isRenamingTitle {
                            commitTitleRename()
                        }
                    }
                    .onAppear {
                        titleDraft = sessionTitle
                        DispatchQueue.main.async {
                            titleFocused = true
                        }
                    }
                Button(action: commitTitleRename) {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Commit session rename")
                Button(action: cancelTitleRename) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel session rename")
            }
        } else {
            HStack(spacing: 6) {
                Text(sessionTitle)
                .font(NativeAgentFont.section)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    beginTitleRename()
                }

                Button {
                    beginTitleRename()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(session == nil)
                .help("Rename session")
                .accessibilityLabel("Rename session")
            }
        }
    }

    private func beginTitleRename() {
        guard let session else { return }
        renameSessionID = session.id
        titleDraft = sessionTitle
        isRenamingTitle = true
    }

    private func cancelTitleRename() {
        titleDraft = sessionTitle
        renameSessionID = nil
        isRenamingTitle = false
    }

    private func commitTitleRename() {
        // A selection change can rebuild this header while its edit state is
        // still alive. Never apply the old title to the newly active session.
        guard ChatHeaderRenamePresentation.belongsToCurrentSession(
            capturedSessionID: renameSessionID,
            renderedSessionID: session?.id
        ) else {
            cancelTitleRename()
            return
        }
        let cleanTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            cancelTitleRename()
            return
        }
        renameSessionID = nil
        isRenamingTitle = false
        if cleanTitle != sessionTitle {
            onRename(cleanTitle)
        }
    }
}
