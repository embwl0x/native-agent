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

struct ContextReceiptView: View {
    var context: ContextReceipt?

    var body: some View {
        NativePanel(title: "Context Receipt", systemImage: "shippingbox") {
            if let context, context.fingerprint != nil || context.runId != nil {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    MetricTile(title: "History", value: "\(context.budgets?.historyChars ?? 0)", systemImage: "text.bubble")
                    MetricTile(title: "Memory", value: "\(context.budgets?.memoryChars ?? 0)", systemImage: "brain")
                    MetricTile(title: "System Map", value: "\(context.budgets?.agentMapChars ?? 0)", systemImage: "map")
                    MetricTile(title: "Budget", value: "\(context.budgetTotals?.displayTotal ?? context.budgets?.displayTotal ?? 0)", systemImage: "speedometer")
                    MetricTile(title: "Skills", value: "\(context.selectedSkillsForDisplay.count)", systemImage: "list.bullet.rectangle")
                    MetricTile(title: "Tools", value: "\(context.budgets?.toolResultChars ?? 0)", systemImage: "hammer")
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

                if let budget = context.budgetTotals ?? context.budgets,
                   budget.maxChars != nil || budget.remainingChars != nil || budget.cacheStatus != nil || budget.cacheKey != nil {
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
        if let status = cacheState?.status, !status.isEmpty {
            return status
        }
        if let hit = cacheState?.hit ?? budgetTotals?.cached ?? budgets?.cached {
            return hit ? "cache hit" : "cache miss"
        }
        if let status = budgetTotals?.cacheStatus ?? budgets?.cacheStatus, !status.isEmpty {
            return status
        }
        return nil
    }
}

struct ContextBudgetDetailView: View {
    var budget: ContextBudget

    var body: some View {
        HStack(spacing: 8) {
            InfoPill(text: "total \(budget.displayTotal)", systemImage: "sum")
            if let maxChars = budget.maxChars {
                InfoPill(text: "max \(maxChars)", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            if let remainingChars = budget.remainingChars {
                InfoPill(text: "remaining \(remainingChars)", systemImage: "minus.forwardslash.plus")
            }
            if let cacheStatus = budget.cacheStatus {
                InfoPill(text: cacheStatus, systemImage: "externaldrive.badge.icloud")
            }
            if let cacheKey = budget.cacheKey {
                InfoPill(text: cacheKey, systemImage: "number")
            }
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
            }
        }
    }
}

struct SessionRow: View {
    var session: ChatSession
    var selected: Bool
    var pinned: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            if let preview = session.lastMessagePreview, !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Label("\(session.messageCount ?? 0)", systemImage: "text.bubble")
                if let source = session.source, source != "app" {
                    Label(source, systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.16)) : AnyShapeStyle(Color.clear))
        }
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
                                running: runningSessionIds.contains(session.id),
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
    @State private var isRenaming = false
    @State private var draftTitle = ""
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
            draftTitle = session.title
        }
        .onChange(of: session.title) { _, newTitle in
            if !isRenaming {
                draftTitle = newTitle
            }
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
        if isRenaming {
            TextField("Session", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(NativeAgentFont.tag.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($titleFocused)
                .onSubmit {
                    commitRename()
                }
                .onExitCommand {
                    cancelRename()
                }
                .onChange(of: titleFocused) { _, focused in
                    if !focused && isRenaming {
                        commitRename()
                    }
                }
                .onAppear {
                    draftTitle = session.title
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
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    beginRename()
                }
            )
            .help("\(session.title) - double-click to rename")
        }
    }

    private func beginRename() {
        draftTitle = session.title
        isRenaming = true
    }

    private func cancelRename() {
        draftTitle = session.title
        isRenaming = false
    }

    private func commitRename() {
        let cleanTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            cancelRename()
            return
        }
        isRenaming = false
        if cleanTitle != session.title {
            onRename(cleanTitle)
        }
    }
}

// PATCH-2026-05-07: ui-polish TypingIndicator — PulsingDot replaces static dots
struct TypingIndicator: View {
    // chat-smoothness phase 4 taste catch: the chip said "NativeAgent is
    // typing" while the floating row used the configured agent name — the persona
    // name is the one the user knows.
    var personaName: String = "NativeAgent"
    var body: some View {
        HStack(spacing: 8) {
            PulsingDot(color: .green, size: 8)
            Text("\(personaName) is typing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: NativeAgentRadius.panel)
                .fill(.regularMaterial)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
