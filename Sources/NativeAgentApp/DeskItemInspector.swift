import SwiftUI
import AppKit
import Desk
// Blueprint: | `DeskItemInspector.swift` | `DeskItemInspector` struct |

/// Item-level controls on the primary Desk; all writes use its tool router.
struct DeskItemInspector: View {
    @Environment(AppModel.self) private var appModel
    let item: DeskItem
    let items: [DeskItem]
    let plan: DeskSequencing.Plan
    let now: Date
    let isBusy: Bool
    let mode: DeskPaletteQuery.Verb?
    let perform: (DeskQuickAction) -> Void
    let addNote: (String, @escaping (Bool) -> Void) -> Void
    let veto: () -> Void
    let select: (String) -> Void
    let dismiss: () -> Void

    private var draftSubject: String { "desk-item/\(item.handle)/note" }
    private var noteDraft: String { appModel.editDraft(draftSubject, seed: "") }
    @State private var showingNote = false
    @State private var showingDefer = false
    @State private var copiedRef: String?
    @FocusState private var noteFocused: Bool
    @FocusState private var inspectorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text(item.title).font(.callout.weight(.semibold)).lineLimit(2)
                Spacer()
                Button("Previous", systemImage: "chevron.up") { move(-1) }
                Button("Next", systemImage: "chevron.down") { move(1) }
                Button("Done", action: dismiss).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(item.alias) · \(Self.kindLabel(item.kind)) · \(item.status.displayLabel) · \(item.project) · \(originLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(DeskItemPresentation.freshness(for: item, now: now).text).foregroundStyle(.secondary)
                    if let assignee = item.assignee { Text("Assigned to \(assignee)") }
                    if let progress = item.progress { Text("\(progress.done) of \(progress.total) · \(progress.note ?? "")") }
                    if let reason = item.blockedReason, !reason.isEmpty { Text(reason) }
                    if let waiting = item.waitingOn, !waiting.isEmpty { Text("Waiting on \(waiting)") }
                    if let summary = item.summary, !summary.isEmpty { Text(summary) }
                    if let note = item.notes.last { Text("Note: \(note.text)") }
                    if let itemPlan = plan.byHandle[item.handle] {
                        let aliases = Dictionary(items.map { ($0.handle, $0.alias) }, uniquingKeysWith: { first, _ in first })
                        ForEach(DeskSequencingPillPresentation.pills(
                            item: item, itemPlan: itemPlan, isNextUp: plan.nextUp.contains(item.handle),
                            aliases: aliases, blockerAliasCap: Int.max)) { pill in
                            if let handle = pill.targetHandle {
                                Button(pill.text) { select(handle) }
                            } else { Text(pill.text).foregroundStyle(.secondary) }
                        }
                    }
                    if DeskBoardLayout.isPursuitLaneItem(item), !item.status.isTerminal {
                        pursuitControls
                    }
                    if !item.status.isTerminal {
                        HStack {
                            Button("Close") { perform(.close(handle: item.handle, outcome: DeskQuickAction.deskCloseOutcome)) }
                            Button("Defer") { showingDefer.toggle(); showingNote = false }
                            Button("Note") { beginNote() }
                            if isBusy { ProgressView().controlSize(.small) }
                        }
                        .disabled(isBusy)
                        if showingDefer {
                            HStack {
                                Text("Park until").foregroundStyle(.secondary)
                                ForEach(DeskDeferPreset.allCases) { preset in
                                    Button(preset.label) { perform(.defer_(handle: item.handle, until: preset.day(from: Date()))) }
                                }
                                if item.deferUntil?.isEmpty == false {
                                    Button("Un-park") { perform(.defer_(handle: item.handle, until: nil)) }
                                }
                            }
                            .disabled(isBusy)
                        }
                        if showingNote {
                            HStack {
                                TextField("Note…", text: appModel.editBinding(draftSubject, seed: ""))
                                    .textFieldStyle(.roundedBorder)
                                    .focused($noteFocused)
                                    .onSubmit { submitNote() }
                                    .onAppear { noteFocused = true }
                                Button("Add", action: submitNote)
                                    .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .disabled(isBusy)
                        }
                    }
                    ForEach(item.refs.sorted { $0.priority < $1.priority }, id: \.refId) { ref in
                        let action = DeskRefAffordance.action(for: ref)
                        Button(action.label, systemImage: action.opensExternally ? "arrow.up.right.square" : "doc.on.doc") {
                            switch action {
                            case .open(let url, _):
                                if let parsed = URL(string: url) { NSWorkspace.shared.open(parsed) }
                            case .copy(let text, _):
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                                copiedRef = "Copied \(text)"
                            }
                        }
                    }
                    if let copiedRef { Text(copiedRef).foregroundStyle(.secondary) }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .focusable()
        .focusEffectDisabled()
        .focused($inspectorFocused)
        .onAppear { inspectorFocused = true; applyMode() }
        .onChange(of: mode) { applyMode() }
        .onChange(of: isBusy) { _, busy in
            if !busy {
                showingDefer = false
                if showingNote { noteFocused = true } else { inspectorFocused = true }
            }
        }
        .onKeyPress(.upArrow) { guard !showingNote else { return .ignored }; move(-1); return .handled }
        .onKeyPress(.downArrow) { guard !showingNote else { return .ignored }; move(1); return .handled }
        .onKeyPress("c") {
            guard !showingNote, !isBusy, !item.status.isTerminal else { return .ignored }
            perform(.close(handle: item.handle, outcome: DeskQuickAction.deskCloseOutcome))
            return .handled
        }
        .onKeyPress("d") {
            guard !showingNote, !isBusy, !item.status.isTerminal else { return .ignored }
            showingDefer.toggle()
            return .handled
        }
        .onKeyPress("n") {
            guard !showingNote, !isBusy, !item.status.isTerminal else { return .ignored }
            beginNote()
            return .handled
        }
        .accessibilityIdentifier("desk.item-inspector")
    }

    @ViewBuilder
    private var pursuitControls: some View {
        if item.pursuit == nil {
            Text(DeskPursuitSectionPresentation.unreadablePayloadLabel).foregroundStyle(.orange)
            Text(DeskPursuitSectionPresentation.unreadablePayloadDetail)
        } else {
            if let pursuit = item.pursuit {
                Text(pursuit.why)
                Text("Done when: \(pursuit.doneLooksLike)")
                Text("\(pursuit.sessionsUsed)/\(pursuit.maxSessions) sessions · \(pursuit.workSessionsToday) today")
                if let last = pursuit.lastWorkedAt { Text("Worked \(DeskRelativeTimePresentation.text(forISO: last, now: now))") }
            }
            let rationale = DeskPursuitVetoRationale.row(for: item, now: now)
            if let score = DeskPursuitVetoRationale.scoreLabel(rationale?.score) { Text(score) }
            if let budget = DeskPursuitVetoRationale.budgetLabel(rationale?.budget) { Text(budget) }
            if let reason = DeskPursuitVetoRationale.reasonLabel(rationale?.latestChoiceRationale) { Text("chose: \(reason)") }
            Button("Veto", systemImage: "xmark.circle", action: veto)
                .disabled(isBusy)
                .help(DeskPursuitVetoControl.help)
                .accessibilityIdentifier("desk.pursuit.veto.\(item.handle)")
        }
    }

    static func kindLabel(_ kind: DeskKind) -> String {
        switch kind {
        case .watch: "watch"
        case .plan: "plan"
        case .project: "project"
        case .gh: "GitHub"
        case .standing: "standing"
        }
    }

    private var originLabel: String {
        switch item.origin {
        case .owner: "added by you"
        case .agent: "added by \(appModel.agentDisplayName)"
        case .system: "added automatically"
        }
    }

    private func move(_ delta: Int) {
        let order = DeskPageContent.active(items).map(\.handle)
        if let handle = DeskSelection.move(from: item.handle, by: delta, in: order) { select(handle) }
    }

    private func beginNote() { showingDefer = false; showingNote = true }
    private func applyMode() {
        if mode == .note { beginNote() }
        if mode == .deferItem { showingDefer = true; showingNote = false }
    }
    private func submitNote() {
        let submitted = noteDraft
        let text = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        let subject = draftSubject
        addNote(text) { ok in
            guard ok else { return }
            if appModel.editDraft(subject, seed: "") == submitted { appModel.clearEditDraft(subject) }
            showingNote = false
            inspectorFocused = true
        }
    }
}


enum DeskSelection {

    /// Arrow-key movement over the visible order. CLAMPS rather than wraps:
    /// wrapping from the last row back to the first reads as a jump on a
    /// surface this long, and User holding ↓ should come to rest at the bottom.
    ///
    /// With no current selection, ↓ takes the first row and ↑ the last — the
    /// standard "enter the list from the edge you came from" behavior.
    static func move(from current: String?, by delta: Int, in order: [String]) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let idx = order.firstIndex(of: current) else {
            return delta >= 0 ? order.first : order.last
        }
        let next = idx + delta
        guard next >= 0, next < order.count else { return current }
        return order[next]
    }

}

enum DeskPursuitSectionPresentation {
    static let unreadablePayloadLabel = "Project details unavailable"
    static let unreadablePayloadDetail = "The saved details of this project could not be read. They need to be repaired before you can act on it."

}

enum DeskPursuitVetoControl {
    static let help = "Close this pursuit (canceled) with a user-vetoed note."
}

/// The ordered status-critical facts rendered above a Desk row's free-text
/// detail. The board and pursuits share this exact projection, so a blocker
/// never becomes navigable in one lane but inert or absent in the other.
enum DeskSequencingPillPresentation {
    enum Kind: String, Sendable, Equatable {
        case rollup
        case blocked
        case cycle
        case deferred
        case nextUp
    }

    struct Pill: Identifiable, Sendable, Equatable {
        let kind: Kind
        let text: String
        let targetHandle: String?

        var id: String { kind.rawValue }
    }

    static func pills(
        item: DeskItem,
        itemPlan: DeskSequencing.ItemPlan,
        isNextUp: Bool,
        aliases: [String: String],
        blockerAliasCap: Int = 3
    ) -> [Pill] {
        var result: [Pill] = []
        if itemPlan.totalCount > 0 {
            result.append(Pill(
                kind: .rollup,
                text: "\(itemPlan.doneCount)/\(itemPlan.totalCount) closed",
                targetHandle: nil
            ))
        }
        if let blocked = DeskItemPresentation.blockedPill(
            plan: itemPlan,
            aliases: aliases,
            cap: blockerAliasCap
        ) {
            result.append(Pill(
                kind: .blocked,
                text: blocked.text,
                targetHandle: blocked.targetHandle
            ))
        }
        if itemPlan.blockedByCycle {
            result.append(Pill(
                kind: .cycle,
                text: "⚠ these block each other",
                targetHandle: nil
            ))
        }
        if itemPlan.isDeferred {
            let day = item.deferUntil.flatMap(DeskSequencing.deferDisplayDay)
            result.append(Pill(
                kind: .deferred,
                text: day.map { "until \($0)" } ?? "deferred; date unavailable",
                targetHandle: nil
            ))
        }
        if isNextUp {
            result.append(Pill(kind: .nextUp, text: "start here", targetHandle: nil))
        }
        return result
    }
}

extension DeskPursuitVetoRationale {

    /// "score 1.83" — nil when the pursuit payload gave no score, so the row
    /// says nothing rather than showing a misleading 0.
    static func scoreLabel(_ score: WorkshopScoreView?) -> String? {
        guard let score else { return nil }
        return "score \(String(format: "%.2f", score.total))"
    }

    /// "2/3 sessions · 1/2 today" — the two hard caps the pursuit lives under.
    static func budgetLabel(_ budget: WorkshopBudget?) -> String? {
        guard let budget else { return nil }
        return "\(budget.sessionsUsed)/\(budget.maxSessions) sessions · "
            + "\(budget.todayCount)/\(budget.perDayCap) today"
    }

    /// Her most recent recorded "chose: …" rationale, stripped of the marker.
}
