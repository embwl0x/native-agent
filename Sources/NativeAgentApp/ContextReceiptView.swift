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

/// Value-only receipt rendering rules. Context receipts are diagnostic truth:
/// absent data is unknown, not a confident zero or an omitted field.
enum ContextReceiptPresentation {
    static func metricValue(_ value: Int?) -> String {
        guard let value else { return "unknown" }
        return "\(value)"
    }

    static func hasReceiptIdentity(fingerprint: String?, runID: String?) -> Bool {
        fingerprint != nil || runID != nil
    }

    static func cacheDisplayText(status: String?, hit: Bool?, budgetStatus: String?) -> String? {
        if let status, !status.isEmpty { return status }
        if let hit { return hit ? "cache hit" : "cache miss" }
        if let budgetStatus, !budgetStatus.isEmpty { return budgetStatus }
        return nil
    }

    static func optionalValue(_ value: Int?) -> String {
        value.map(String.init) ?? "unknown"
    }

    static func optionalText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "unknown" }
        return value
    }

    static func remainingCount(total: Int, displayed: Int) -> Int? {
        let remainder = total - displayed
        return remainder > 0 ? remainder : nil
    }
}

struct ContextReceiptView: View {
    var context: ContextReceipt?

    var body: some View {
        NativePanel(title: "Context Receipt", systemImage: "shippingbox") {
            if let context, ContextReceiptPresentation.hasReceiptIdentity(
                fingerprint: context.fingerprint,
                runID: context.runId
            ) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    MetricTile(title: "History", value: ContextReceiptPresentation.metricValue(context.budgets?.historyChars), systemImage: "text.bubble")
                    MetricTile(title: "Memory", value: ContextReceiptPresentation.metricValue(context.budgets?.memoryChars), systemImage: "brain")
                    MetricTile(title: "System Map", value: ContextReceiptPresentation.metricValue(context.budgets?.agentMapChars), systemImage: "map")
                    MetricTile(title: "Budget", value: ContextReceiptPresentation.metricValue(context.budgetTotals?.displayTotal ?? context.budgets?.displayTotal), systemImage: "speedometer")
                    MetricTile(title: "Skills", value: "\(context.selectedSkillsForDisplay.count)", systemImage: "list.bullet.rectangle")
                    MetricTile(title: "Tools", value: ContextReceiptPresentation.metricValue(context.budgets?.toolResultChars), systemImage: "hammer")
                }
                HStack {
                    if let surface = context.surface {
                        InfoPill(text: surface, systemImage: "rectangle.connected.to.line.below")
                    }
                    if let mode = context.contextMode {
                        InfoPill(text: mode, systemImage: "arrow.triangle.branch")
                    }
                    if let cacheText = context.cacheDisplayText {
                        InfoPill(text: cacheText, systemImage: "externaldrive.badge.icloud")
                    }
                    if let persona = context.personaFingerprint {
                        InfoPill(text: "Persona \(persona)", systemImage: "person.wave.2")
                    }
                    if let created = context.createdAt {
                        InfoPill(text: created, systemImage: "clock")
                    }
                }
                .lineLimit(1)

                if let budget = context.budgetTotals ?? context.budgets {
                    ContextBudgetDetailView(budget: budget)
                }

                if let reasons = context.routeReasons, !reasons.isEmpty {
                    ContextStringListView(title: "Route Reasons", systemImage: "arrow.triangle.branch", values: reasons)
                }

                if let sections = context.injectedSections, !sections.isEmpty {
                    ContextInjectedSectionsView(sections: sections)
                }

                ContextSelectionSection(title: "Capabilities", systemImage: "shippingbox", items: context.selectedCapabilities ?? [])
                ContextSelectionSection(title: "Memories", systemImage: "brain", items: context.selectedMemories ?? [])
                ContextSelectionSection(title: "Tools", systemImage: "hammer", items: context.selectedTools ?? [])
                ContextSelectionSection(title: "Skills", systemImage: "list.bullet.rectangle", items: context.selectedSkillsForDisplay)
            } else if context != nil {
                Text("Context receipt is incomplete and cannot be identified.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Send a message to generate a context receipt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension ContextReceipt {
    var selectedSkillsForDisplay: [ContextSelectionRef] {
        let selected = selectedSkills ?? []
        let loaded = (loadedSkills ?? []).map {
            ContextSelectionRef(refId: $0.skillId, name: $0.name, kind: "loaded", detail: nil, reason: nil, score: nil)
        }
        var seen = Set<String>()
        return (selected + loaded).filter { seen.insert($0.id).inserted }
    }

    var cacheDisplayText: String? {
        ContextReceiptPresentation.cacheDisplayText(
            status: cacheState?.status,
            hit: cacheState?.hit ?? budgetTotals?.cached ?? budgets?.cached,
            budgetStatus: budgetTotals?.cacheStatus ?? budgets?.cacheStatus
        )
    }
}

struct ContextBudgetDetailView: View {
    var budget: ContextBudget

    var body: some View {
        HStack(spacing: 8) {
            InfoPill(text: "total \(budget.displayTotal)", systemImage: "sum")
            InfoPill(text: "max \(ContextReceiptPresentation.optionalValue(budget.maxChars))", systemImage: "gauge.with.dots.needle.bottom.50percent")
            InfoPill(text: "remaining \(ContextReceiptPresentation.optionalValue(budget.remainingChars))", systemImage: "minus.forwardslash.plus")
            InfoPill(text: ContextReceiptPresentation.optionalText(budget.cacheStatus), systemImage: "externaldrive.badge.icloud")
            InfoPill(text: ContextReceiptPresentation.optionalText(budget.cacheKey), systemImage: "number")
        }
    }
}

struct ContextStringListView: View {
    var title: String
    var systemImage: String
    var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(values.prefix(6)), id: \.self) { value in
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let remaining = ContextReceiptPresentation.remainingCount(total: values.count, displayed: 6) {
                Text("+\(remaining) more")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(remaining) additional \(title.lowercased()) entries")
            }
        }
    }
}

struct ContextInjectedSectionsView: View {
    var sections: [ContextInjectedSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Injected Sections", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(Array(sections.prefix(8))) { section in
                    HStack(spacing: 6) {
                        Image(systemName: section.cached == true ? "externaldrive.badge.checkmark" : "doc.text")
                            .foregroundStyle(.secondary)
                        Text(section.displayTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if let chars = section.chars {
                            Text("\(chars)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if let remaining = ContextReceiptPresentation.remainingCount(total: sections.count, displayed: 8) {
                Text("+\(remaining) more")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ContextSelectionSection: View {
    var title: String
    var systemImage: String
    var items: [ContextSelectionRef]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.prefix(6))) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.displayName)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                if !item.displayDetail.isEmpty {
                                    Text(item.displayDetail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if let score = item.score {
                                Text(score, format: .number.precision(.fractionLength(2)))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else if let kind = item.kind {
                                StatusBadge(text: kind.uppercased(), status: kind)
                            }
                        }
                    }
                }
                if let remaining = ContextReceiptPresentation.remainingCount(total: items.count, displayed: 6) {
                    Text("+\(remaining) more")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Shared state transitions for the sidebar and pinned-tab rename editors.
/// A structural disappearance is always a cancel, and only one terminal event
/// may escape even when Escape is immediately followed by focus loss.
struct ChatRenameStateMachine: Equatable {
    enum EndResult: Equatable {
        case ignored
        case cancelled
        case committed(String)
    }

    var draftTitle = ""
    private(set) var isRenaming = false
    private var ended = false

    mutating func begin(title: String) {
        draftTitle = title
        isRenaming = true
        ended = false
    }

    mutating func syncExternalTitle(_ title: String) {
        guard !isRenaming else { return }
        draftTitle = title
    }

    mutating func submit(currentTitle: String) -> EndResult {
        let cleaned = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != currentTitle else { return finish(.cancelled) }
        return finish(.committed(cleaned))
    }

    mutating func cancel() -> EndResult {
        finish(.cancelled)
    }

    mutating func focusChanged(isFocused: Bool, currentTitle: String) -> EndResult {
        guard !isFocused, isRenaming else { return .ignored }
        return submit(currentTitle: currentTitle)
    }

    private mutating func finish(_ result: EndResult) -> EndResult {
        guard !ended else { return .ignored }
        ended = true
        isRenaming = false
        return result
    }
}

/// One source of truth for the sidebar row's two rename entry points. The
/// pencil is intentionally hover-only, while the context-menu action remains
/// available whenever a caller supplies a rename handler so keyboard and
/// assistive-technology users never depend on pointer hover.
struct SessionRowRenamePencilPresentation: Equatable {
    let opacity: Double
    let allowsHitTesting: Bool
    let accessibilityHidden: Bool
    let contextMenuRenameAvailable: Bool

    static func make(
        renameAvailable: Bool,
        hovering: Bool,
        renaming: Bool
    ) -> Self {
        let pencilVisible = renameAvailable && hovering && !renaming
        return Self(
            opacity: pencilVisible ? 1 : 0,
            allowsHitTesting: pencilVisible,
            accessibilityHidden: !pencilVisible,
            contextMenuRenameAvailable: renameAvailable
        )
    }
}

/// Session-level origin is a trust boundary. Unlike a message's origin, this
/// follows the whole conversation in the sidebar, so never interpolate a raw
/// stored value or silently hide a missing one.
struct ChatSidebarSessionSourceBadge: Equatable {
    enum Tone: Equatable {
        case remote
        case unknown
    }

    let label: String
    let symbol: String
    let tone: Tone

    static func make(source: String?) -> Self? {
        guard let raw = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return Self(label: "Unknown origin", symbol: "questionmark.circle", tone: .unknown)
        }

        switch raw.lowercased() {
        case "app":
            return nil
        case "telegram":
            return Self(label: "Telegram", symbol: "paperplane.fill", tone: .remote)
        case "ios", "iphone", "ipad":
            return Self(label: "iPhone / iPad", symbol: "iphone", tone: .remote)
        case "slack":
            return Self(label: "Slack", symbol: "bubble.left.and.bubble.right.fill", tone: .remote)
        case "bridge", "agent_bridge":
            return Self(label: "Bridge", symbol: "arrow.left.arrow.right", tone: .remote)
        default:
            return Self(label: "External source", symbol: "exclamationmark.triangle", tone: .unknown)
        }
    }
}

// sidebar-density 2026-08-10 (User): one line per session so the list shows
// more. The preview text is gone from the ROW but stays in the search filter —
// finding a session by remembered content still works. Rename mirrors
// PinnedSessionTab's contract exactly (pencil/menu begins, Enter
// commits, Esc cancels, focus-loss commits, empty reverts) so the two
// surfaces never teach conflicting muscle memory.
struct SessionRow: View {
    enum PinState {
        case unpinned
        case pinned(onUnpin: () -> Void)

        var isPinned: Bool {
            if case .pinned = self { return true }
            return false
        }

        func performUnpin() {
            guard case let .pinned(onUnpin) = self else { return }
            onUnpin()
        }
    }

    var session: ChatSession
    var selected: Bool
    var pinState: PinState
    var renaming: Bool = false
    var onRenameBegin: (() -> Void)? = nil
    /// nil = rename canceled/no-op; non-nil = commit this cleaned title.
    var onRenameEnd: ((String?) -> Void)? = nil

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var renameState = ChatRenameStateMachine()
    @FocusState private var titleFocused: Bool
    // One rename ends exactly once. Esc fires onExitCommand AND the resulting
    // focus loss fires the onChange commit before the parent's renaming=false
    // re-render lands — without this guard a canceled edit could still
    // commit. (PinnedSessionTab gets this for free from its local isRenaming;
    // this row's rename state lives in the parent, so the sync guard is local.)

    private var renamePencil: SessionRowRenamePencilPresentation {
        SessionRowRenamePencilPresentation.make(
            renameAvailable: onRenameBegin != nil,
            hovering: hovering,
            renaming: renaming
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            if pinState.isPinned {
                Button(action: pinState.performUnpin) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Unpin session")
                .accessibilityLabel("Unpin session")
            }
            titleView
            Spacer(minLength: 4)
            // Rename affordance is a hover pencil, deliberately NOT a
            // double-click: a count-2 gesture sharing the row with the
            // single-tap select is racy (the select's state rebuild resets
            // the recognizer — live-verified 2026-08-10), and prioritizing
            // it would lag every selection by the double-click window.
            // The slot is always reserved and only fades in, so hovering
            // never reflows or re-truncates the title.
            if onRenameBegin != nil {
                Button {
                    onRenameBegin?()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 14)
                .opacity(renamePencil.opacity)
                .allowsHitTesting(renamePencil.allowsHitTesting)
                .help("Rename session")
                .accessibilityLabel("Rename session")
                .accessibilityIdentifier("chat.sidebar.session.rename-pencil.\(session.id)")
                .accessibilityHidden(renamePencil.accessibilityHidden)
            }
            if let sourceBadge = ChatSidebarSessionSourceBadge.make(source: session.source) {
                Label(sourceBadge.label, systemImage: sourceBadge.symbol)
                    .font(.caption2)
                    .foregroundStyle(sourceBadge.tone == .remote ? Color.orange : Color.red)
                    .lineLimit(1)
                    .accessibilityLabel("Session origin: \(sourceBadge.label)")
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            // Liquid Feel W1: the row answers the cursor — hover fill on
            // unselected rows, spring-animated (reduce-motion aware).
            RoundedRectangle(cornerRadius: 8)
                .fill(selected
                    ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                    : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0)))
        }
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.snappy, reduceMotion: reduceMotion),
            value: hovering
        )
        .onHover { hovering = $0 }
        // LazyVStack recycles rows by identity — clear hover on disappear so a
        // recycled row can't reappear pre-lit with the rename pencil showing.
        .onDisappear { hovering = false }
    }

    @ViewBuilder
    private var titleView: some View {
        if renaming {
            TextField("Session", text: $renameState.draftTitle)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .focused($titleFocused)
                .onSubmit { endRename(renameState.submit(currentTitle: session.title)) }
                // COMMIT only on deliberate signals: Enter, or genuine focus
                // loss (clicking the search field / composer — real focus
                // targets). Everything structural CANCELS: Esc, clicking
                // another row (parent clears renamingSessionId), the row
                // scrolling out of the LazyVStack, or a search filter
                // removing it — a disappearance can't tell click-away from
                // recycling, and committing a half-typed title on a scroll
                // is worse than dropping an edit (review round 3).
                // The shared state machine keeps every end path single-fire.
                .onKeyPress(.escape) {
                    endRename(renameState.cancel())
                    return .handled
                }
                .onExitCommand { endRename(renameState.cancel()) }
                .onChange(of: titleFocused) { _, focused in
                    endRename(renameState.focusChanged(
                        isFocused: focused,
                        currentTitle: session.title
                    ))
                }
                .onAppear {
                    renameState.begin(title: session.title)
                    DispatchQueue.main.async { titleFocused = true }
                }
                .onDisappear { endRename(renameState.cancel()) }
        } else {
            Text(session.displayTitle)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func endRename(_ result: ChatRenameStateMachine.EndResult) {
        switch result {
        case .ignored:
            return
        case .cancelled:
            onRenameEnd?(nil)
        case .committed(let title):
            onRenameEnd?(title)
        }
    }
}

enum PinnedSessionTabPresentation {
    static func tabAccessibilityLabel(for session: ChatSession) -> String {
        session.displayTitle
    }

    static func closeAccessibilityLabel(for session: ChatSession) -> String {
        "Close pinned tab \(session.displayTitle)"
    }

    static func showsRunningIndicator(
        sessionID: String,
        streamingSessionIDs: Set<String>
    ) -> Bool {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return streamingSessionIDs.contains(sessionID)
    }
}

struct PinnedSessionTabStrip: View {
    var sessions: [ChatSession]
    var activeSessionId: String
    var runningSessionIds: Set<String>
    var dropTargeted: Bool
    var onSelect: (ChatSession) -> Void
    var onClose: (ChatSession) -> Void
    var onRename: (ChatSession, String) -> Void

    var body: some View {
        Group {
            if sessions.isEmpty {
                // ui-polish 2026-05-22 — drop-target empty state in the
                // same 10-radius vocabulary as the populated strip + tabs.
                HStack {
                    Image(systemName: "pin")
                        .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                }
                .frame(height: 32)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                        .fill(dropTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                        .strokeBorder(
                            dropTargeted ? Color.accentColor.opacity(0.40) : Color.primary.opacity(0.12),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(sessions) { session in
                            PinnedSessionTab(
                                session: session,
                                selected: session.id == activeSessionId,
                                running: PinnedSessionTabPresentation.showsRunningIndicator(
                                    sessionID: session.id,
                                    streamingSessionIDs: runningSessionIds
                                ),
                                onSelect: { onSelect(session) },
                                onClose: { onClose(session) },
                                onRename: { title in onRename(session, title) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 40)
                // ui-polish 2026-05-22 — material chrome strip (matches iOS
                // .bar treatment), 10-radius corners, softer 0.5pt divider so
                // the strip reads as layered tab chrome, not a banded box.
                .background {
                    RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                        .fill(
                            dropTargeted
                                ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                                : AnyShapeStyle(.bar)
                        )
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                }
            }
        }
        .animation(NativeAgentMotion.snappy, value: sessions.map(\.id))
        .animation(NativeAgentMotion.snappy, value: dropTargeted)
    }
}

private struct PinnedSessionTab: View {
    var session: ChatSession
    var selected: Bool
    var running: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    var onRename: (String) -> Void
    @State private var renameState = ChatRenameStateMachine()
    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            tabTitle

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Unpin tab")
            .accessibilityLabel(PinnedSessionTabPresentation.closeAccessibilityLabel(for: session))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 156, height: 32)
        .contextMenu {
            Button("Rename Tab", systemImage: "pencil") {
                beginRename()
            }
            Button("Unpin Tab", systemImage: "pin.slash") {
                onClose()
            }
        }
        .onAppear {
            renameState.syncExternalTitle(session.title)
        }
        .onChange(of: session.title) { _, newTitle in
            renameState.syncExternalTitle(newTitle)
        }
        // ui-polish 2026-05-22 — replace flat 7-radius fill+stroke with the
        // design-system material vocabulary (cf. NativePanel/GlassCard):
        // 10-radius continuous corners, material lift on selected, soft accent
        // wash, hover state, and a 2pt indicator stripe under the selected tab.
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                    .fill(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear))
                RoundedRectangle(cornerRadius: NativeAgentRadius.panel, style: .continuous)
                    .fill(
                        selected
                            ? Color.accentColor.opacity(0.12)
                            : (hovering ? Color.primary.opacity(0.05) : Color.clear)
                    )
            }
        }
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 16)
                .opacity(selected ? 1 : 0)
        }
        .shadow(color: selected ? Color.black.opacity(0.08) : .clear, radius: 4, y: 1)
        .onHover { hovering = $0 }
        .animation(NativeAgentMotion.snappy, value: selected)
        .animation(NativeAgentMotion.snappy, value: hovering)
    }

    @ViewBuilder
    private var tabTitle: some View {
        if renameState.isRenaming {
            TextField("Session", text: $renameState.draftTitle)
                .textFieldStyle(.plain)
                .font(NativeAgentFont.tag.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($titleFocused)
                .onSubmit {
                    finishRename(renameState.submit(currentTitle: session.title))
                }
                // Esc gets both SwiftUI cancel paths, matching SessionRow.
                .onKeyPress(.escape) {
                    finishRename(renameState.cancel())
                    return .handled
                }
                .onExitCommand {
                    finishRename(renameState.cancel())
                }
                .onChange(of: titleFocused) { _, focused in
                    finishRename(renameState.focusChanged(
                        isFocused: focused,
                        currentTitle: session.title
                    ))
                }
                .onAppear {
                    renameState.begin(title: session.title)
                    DispatchQueue.main.async {
                        titleFocused = true
                    }
                }
        } else {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if running {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    }
                    Text(session.displayTitle)
                        .font(NativeAgentFont.tag.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PinnedSessionTabPresentation.tabAccessibilityLabel(for: session))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    beginRename()
                }
            )
            .help("\(session.title) - double-click to rename")
        }
    }

    private func beginRename() {
        renameState.begin(title: session.title)
    }

    private func finishRename(_ result: ChatRenameStateMachine.EndResult) {
        if case .committed(let title) = result {
            onRename(title)
        }
    }
}
