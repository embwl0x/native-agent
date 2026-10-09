// PATCH-2026-05-07: proactive-inbox-1 InboxView — proactive inbox card strip
import SwiftUI
import Observation
import NativeAgentShared
import NativeAgentCore
import NotificationInbox
import DeviceSync

// MARK: - Models

/// Presentation over the core inbox card (`NotificationInbox.InboxItemRecord`).
extension InboxItemRecord {
    var isHiddenFromDefaultInbox: Bool {
        normalizedStatus == "archived" || normalizedStatus == "dismissed"
    }
    var hasLinkedApproval: Bool { !(related_approval_id ?? "").isEmpty }
    var isProactiveCard: Bool { source.lowercased().hasPrefix("proactive_autonomy:") }
    var isApprovalBacklogCard: Bool {
        let lowerSource = source.lowercased()
        let lowerDetail = (detail ?? "").lowercased()
        return hasLinkedApproval
            || lowerSource.hasPrefix("proactive_autonomy:approval_backlog:")
            || lowerDetail.contains("suggested action: approvals.triage")
    }

    var fallbackPrimaryAction: InboxActionRecord? {
        if isApprovalBacklogCard {
            return InboxActionRecord(
                id: "open_approvals",
                label: "Open Approvals",
                description: "Review pending approvals"
            )
        }
        if isProactiveCard {
            return nil
        }
        if severity.lowercased() == "actionable" || relatedWorkshopExecutionId != nil {
            return InboxActionRecord(id: "act", label: "Act", description: "Take primary action")
        }
        return nil
    }

    var effectiveActions: [InboxActionRecord] {
        if !actions.isEmpty { return actions }
        var fallback = [InboxActionRecord(id: "view", label: "View", description: "See full detail")]
        if let primary = fallbackPrimaryAction {
            fallback.append(primary)
        }
        fallback.append(contentsOf: [
            InboxActionRecord(id: "archive", label: "Archive", description: "Archive this item"),
            InboxActionRecord(id: "dismiss", label: "Dismiss", description: "Dismiss this item"),
        ])
        return fallback
    }

    var actionIDs: Set<String> {
        Set(effectiveActions.map(\.id))
    }

    var severityColor: Color {
        switch severity {
        case "actionable": return .orange
        case "important":  return .blue
        default:           return .secondary
        }
    }

    /// Everything else — deliberately the DEFAULT. An unrecognized source is a
    /// card nobody has classified yet; putting it in front of User is the
    /// recoverable error, hiding it in a lane he does not open is not.
    var isForYouLane: Bool { !isSystemLane }

    var sourceIcon: String {
        if hasLinkedApproval { return "checkmark.shield.fill" }
        if source.hasPrefix("proactive_autonomy") { return "lightbulb.fill" }
        if source.hasPrefix("harness_learning") { return "wand.and.stars" }
        if source == "dream_cycle"               { return "moon.stars.fill" }
        if source == "rem_cycle"                 { return "sparkles" }
        if source.hasPrefix("trigger:file_watch") { return "doc.text.magnifyingglass" }
        // P2-4: cards already in inbox.jsonl carry `mission_complete:<id>`.
        if ExecutionEventVocabulary.hasKindPrefix(source, WorkshopCompletionTrigger.canonicalKind) {
            return "checkmark.circle.fill"
        }
        if source == "idle_checkin"               { return "clock.fill" }
        if source.hasPrefix("trigger:morning_brief") { return "sun.horizon.fill" }
        if source.hasPrefix("trigger:stuck_pattern") { return "arrow.trianglehead.2.clockwise" }
        if source == "self_test"                  { return "testtube.2" }
        return "bell.fill"
    }

    var sourceBadgeLabel: String {
        InboxSourceBadgePresentation.label(
            source: source,
            readState: sourceReadState,
            hasLinkedApproval: hasLinkedApproval
        )
    }

    /// The badge said as a word: "MORNING-BRIEF" is "Morning brief".
    var sourceWord: String {
        let label = sourceBadgeLabel
        guard label != "REM" else { return label }
        let words = label.replacingOccurrences(of: "-", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "Idea · Actionable" over the detail sheet's title.
    var detailEyebrow: String {
        let level = severity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !level.isEmpty, level.lowercased() != "info" else { return sourceWord }
        return "\(sourceWord) · \(AdvancedStatusWords.label(level))"
    }
}

/// Canonical, bounded source-to-badge projection used by every Inbox item.
/// A category is assigned only for an exact known source/prefix; unknown but
/// valid source vocabulary is shown as a safe humanized label, while missing
/// and malformed wire values remain explicit adverse states.
enum InboxSourceBadgePresentation {
    static func label(
        source: String,
        readState: InboxSourceReadState,
        hasLinkedApproval: Bool
    ) -> String {
        if hasLinkedApproval { return "APPROVAL" }
        switch readState {
        case .missing:
            return "SOURCE MISSING"
        case .malformed:
            return "SOURCE INVALID"
        case .present:
            break
        }

        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "SOURCE UNKNOWN" }
        guard isSafeSourceToken(normalized) else { return "SOURCE INVALID" }

        if normalized.hasPrefix("proactive_autonomy:") { return "IDEA" }
        if normalized.hasPrefix("harness_learning:") { return "LEARNING" }
        if normalized == "dream_cycle" { return "DREAM" }
        if normalized == "rem_cycle" { return "REM" }
        if normalized.hasPrefix("trigger:file_watch") { return "FILE-WATCH" }
        if normalized.hasPrefix("trigger:morning_brief") { return "MORNING-BRIEF" }
        if normalized.hasPrefix("trigger:stuck_pattern") { return "STUCK-PATTERNS" }
        if normalized == "idle_checkin" { return "IDLE-CHECKIN" }
        if ExecutionEventVocabulary.hasKindPrefix(normalized, WorkshopCompletionTrigger.canonicalKind) {
            return "WORKSHOP"
        }
        if normalized == "scheduled_proactive_scan" { return "PROACTIVE SCAN" }
        return boundedHumanizedLabel(normalized)
    }

    private static func isSafeSourceToken(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_:-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func boundedHumanizedLabel(_ source: String) -> String {
        let words = source
            .split(whereSeparator: { $0 == "_" || $0 == ":" || $0 == "-" })
            .map { $0.uppercased() }
        guard !words.isEmpty else { return "SOURCE UNKNOWN" }

        var label = ""
        for word in words {
            let candidate = label.isEmpty ? word : label + " " + word
            if candidate.count > 16 { break }
            label = candidate
        }
        return label.isEmpty ? "SOURCE UNKNOWN" : label
    }
}

typealias InboxRelatedGroup = NativeAgentShared.InboxRelatedGroup
typealias InboxActionRecord = NativeAgentShared.InboxActionRecord

extension InboxRelatedGroup {
    func matches(_ item: InboxItemRecord) -> Bool {
        matches(itemID: item.id, title: item.title)
    }
}

/// The persisted inbox action list includes control verbs which the Desk owns
/// itself: opening a card marks it read, and viewing/replying are not direct
/// button operations. Project once at the presentation boundary so every Desk
/// surface offers exactly the native action that its button will invoke.
enum InboxVisibleActionsPresentation {
    private static let hiddenActionIDs: Set<String> = ["view", "read", "reply"]
    private static let executableActionIDs: Set<String> = Set([
        "act", "approve", "reject",
    ]).union(HeartbeatCardAction.ids)

    static func actions(for item: InboxItemRecord) -> [InboxActionRecord] {
        guard !item.isHiddenFromDefaultInbox else { return [] }
        var seen: Set<String> = []
        var visible: [InboxActionRecord] = []

        for action in item.effectiveActions {
            let normalizedID = action.id
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let canonicalID = normalizedID == "deny" ? "reject" : normalizedID
            guard !hiddenActionIDs.contains(canonicalID),
                  executableActionIDs.contains(canonicalID)
            else { continue }

            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(canonicalID).inserted else { continue }
            visible.append(InboxActionRecord(
                id: canonicalID,
                label: label,
                description: action.description
            ))
        }
        return visible
    }
}

struct InboxTriggerConfig: Identifiable, Codable, Hashable {
    let name: String
    var enabled: Bool
    let kind: String?
    // config is dynamic — stored as [String: String] for watched paths access
    var config: [String: String]?   // only string-valued keys used in UI
    let description: String?

    var id: String { name }

    // Custom decoder to tolerate any config value types (arrays, bools, ints)
    // by only capturing string-valued keys
    enum CodingKeys: String, CodingKey {
        case name, enabled, kind, config, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        kind = try? c.decode(String.self, forKey: .kind)
        description = try? c.decode(String.self, forKey: .description)
        // config may have mixed types; use global AnyCodable to capture string-valued keys
        if let raw = try? c.decode([String: AnyCodable].self, forKey: .config) {
            var stringMap: [String: String] = [:]
            for (k, v) in raw {
                if let s = v.value as? String {
                    stringMap[k] = s
                } else if let arr = v.value as? [Any] {
                    stringMap[k] = arr.compactMap { $0 as? String }.joined(separator: "\n")
                } else if let i = v.value as? Int {
                    stringMap[k] = String(i)
                } else if let b = v.value as? Bool {
                    stringMap[k] = b ? "true" : "false"
                }
            }
            config = stringMap.isEmpty ? nil : stringMap
        } else {
            config = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(config, forKey: .config)
    }

    // Memberwise initializer for non-Codable paths
    init(name: String, enabled: Bool, kind: String? = nil, config: [String: String]? = nil, description: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.config = config
        self.description = description
    }

    var displayName: String {
        switch name {
        case "file_watch":       return "File watcher"
        case "idle_checkin":     return "Idle check-in"
        case "morning_brief":    return "Morning brief"
        case WorkshopCompletionTrigger.canonicalName,
             WorkshopCompletionTrigger.legacyName: return "Desk follow-up"
        case "stuck_pattern":    return "Stuck pattern"
        default:                 return Self.humanized(name)
        }
    }

    /// An id with no spelled-out name still reads as words: underscores become
    /// spaces and the first letter is capitalized.
    static func humanized(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return id }
        return String(first).uppercased() + words.dropFirst()
    }

    var systemImage: String {
        switch name {
        case "file_watch":       return "doc.text.magnifyingglass"
        case "idle_checkin":     return "clock"
        case "morning_brief":    return "sun.horizon"
        case WorkshopCompletionTrigger.canonicalName,
             WorkshopCompletionTrigger.legacyName: return "checkmark.circle"
        case "stuck_pattern":    return "arrow.trianglehead.2.clockwise"
        default:                 return "bolt"
        }
    }
}

// MARK: - Notes capsule (fluid glass A2: one notice lane)

/// Unread notes as one small glass capsule in the chat header, shown only
/// while something is unread. It opens a list, newest first; a row opens the
/// note's detail and its actions. Nothing stacks over the transcript.
struct InboxNotesCapsule: View {
    let items: [InboxItemRecord]
    let onAction: @MainActor (String, String) async throws -> Void

    @State private var showsList = false
    @State private var selectedItem: InboxItemRecord?
    @State private var actionFlight = InboxRowActionFlight()

    private static let rowHeight: CGFloat = 44

    var body: some View {
        // Newest first: the inbox already lists that way.
        let unread = items.filter(\.isUnread)
        ZStack {
            if !unread.isEmpty {
                Button { showsList.toggle() } label: {
                    Text("\(unread.count) \(unread.count == 1 ? "update" : "updates")")
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .houseSurface(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .help("Unread notes")
                .accessibilityLabel("\(unread.count) unread \(unread.count == 1 ? "update" : "updates")")
                .accessibilityIdentifier("chat.notes.capsule")
                .transition(NativeAgentMotion.fade)
                .popover(isPresented: $showsList, arrowEdge: .bottom) {
                    list(unread)
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            InboxItemDetailSheet(
                item: item,
                allItems: items,
                onAction: { actionID in
                    await actionFlight.perform {
                        try await onAction(item.id, actionID)
                    }
                },
                onClose: { selectedItem = nil }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func list(_ unread: [InboxItemRecord]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Updates")
                    .font(ShellType.labelSemibold)
                Spacer()
                // Marked read, they stay in Notifications; nothing is lost.
                Button("Mark all read") {
                    showsList = false
                    let ids = unread.map(\.id)
                    Task { for id in ids { try? await onAction(id, "read") } }
                }
                .buttonStyle(.link)
                .font(ShellType.label)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(unread) { item in
                        Button {
                            showsList = false
                            // Let the popover close before the sheet opens.
                            DispatchQueue.main.async { selectedItem = item }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.sourceIcon)
                                    .foregroundStyle(item.severityColor)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(ShellType.labelSemibold)
                                        .lineLimit(1)
                                    Text(item.summary)
                                        .font(ShellType.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: min(CGFloat(unread.count), 8) * Self.rowHeight)
        }
        .frame(width: 320)
    }
}

// MARK: - Detail sheet

/// One note, read in full: what it is, what it says, the files and related
/// notes it points at, and its actions along the bottom. The shell's type and
/// the alive kit's cards on the sheet; a failed action is one line above the
/// buttons, not an alert.
struct InboxItemDetailSheet: View {
    let item: InboxItemRecord
    var allItems: [InboxItemRecord] = []
    let onAction: @MainActor (String) async -> InboxRowActionFlight.Outcome
    var onOpenGroup: ((InboxRelatedGroup) -> Void)? = nil
    var closesOnGroupSelection = true
    let onClose: () -> Void

    @State private var isActing = false
    @State private var actionError: String?

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    private var relatedGroups: [InboxRelatedGroup] {
        InboxDetailGroupProjection.groups(item: item, allItems: allItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                        AliveEyebrow(item.detailEyebrow)
                        Text(item.title)
                            .font(ShellType.title)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(item.summary)
                            .font(ShellType.body)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let paths = item.related_paths, !paths.isEmpty {
                        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                            AliveEyebrow("Files")
                            AliveGroupCard {
                                ForEach(paths.prefix(5), id: \.self) { path in
                                    Text(path)
                                        .font(ShellType.code)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if let onOpenGroup, !relatedGroups.isEmpty {
                        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
                            AliveEyebrow("Related notes")
                            AliveGroupCard {
                                ForEach(relatedGroups) { group in
                                    Button {
                                        onOpenGroup(group)
                                        if closesOnGroupSelection { onClose() }
                                    } label: {
                                        HStack(spacing: NativeAgentSpacing.sm) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(group.title)
                                                    .font(ShellType.labelMedium)
                                                    .foregroundStyle(NativeAgentShell.text)
                                                    .multilineTextAlignment(.leading)
                                                Text("\(group.displayCount) \(group.displayCount == 1 ? "note" : "notes")")
                                                    .font(ShellType.caption)
                                                    .foregroundStyle(NativeAgentShell.secondary)
                                            }
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(ShellType.caption)
                                                .foregroundStyle(NativeAgentShell.secondary)
                                                .accessibilityHidden(true)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NativeAgentSpacing.xl)
            }
            Divider()
            VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
                if let actionError {
                    Text(actionError)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: NativeAgentSpacing.sm) {
                    // `.onAppear` below already marks the item read when the
                    // sheet opens; Close only closes.
                    Button("Close") { onClose() }
                        .keyboardShortcut(.cancelAction)
                    Spacer(minLength: 0)
                    ForEach(visibleActions.filter { !InboxActionWords.isPrimary($0.id) }, id: \.id) { action in
                        Button(action.label) { perform(action.id, closesOnSuccess: true) }
                            .disabled(isActing)
                    }
                    ForEach(visibleActions.filter { InboxActionWords.isPrimary($0.id) }, id: \.id) { action in
                        Button(action.label) { perform(action.id, closesOnSuccess: true) }
                            .buttonStyle(.borderedProminent)
                            .hazeTinted(.button)
                            .disabled(isActing)
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.vertical, NativeAgentSpacing.lg)
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 320, idealHeight: 480)
        .animation(NativeAgentMotion.standard, value: actionError)
        .onAppear { perform("read", closesOnSuccess: false) }
    }

    private func perform(_ actionID: String, closesOnSuccess: Bool) {
        guard !isActing else { return }
        isActing = true
        actionError = nil
        Task { @MainActor in
            defer { isActing = false }
            let outcome = await onAction(actionID)
            switch InboxDetailActionPresentation.effect(
                for: outcome,
                closesOnSuccess: closesOnSuccess
            ) {
            case .dismiss:
                onClose()
            case .showError:
                actionError = InboxActionWords.failure(actionID)
            case .keepOpen:
                break
            }
        }
    }

}

/// What a note's action buttons say, and what a failed one says: what didn't
/// happen and what to do, never the writer's own error text.
enum InboxActionWords {
    static func isPrimary(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

    static func failure(_ actionID: String) -> String {
        let what: String
        switch actionID {
        case "read": what = "mark this note read"
        case "archive": what = "archive this note"
        case "dismiss": what = "dismiss this note"
        case "approve": what = "approve this"
        case "reject", "deny": what = "decline this"
        default: what = "do that"
        }
        return "Couldn't \(what). Try again in a moment."
    }
}

/// A sheet only dismisses after its action's durable write succeeds. Failures
/// stay mounted with the error so an inbox card cannot falsely disappear.
enum InboxDetailActionPresentation {
    enum Effect: Equatable {
        case keepOpen
        case dismiss
        case showError(String)
    }

    static func effect(
        for outcome: InboxRowActionFlight.Outcome,
        closesOnSuccess: Bool
    ) -> Effect {
        switch outcome {
        case .succeeded: return closesOnSuccess ? .dismiss : .keepOpen
        case .failed(let message): return .showError(message)
        case .dropped: return .keepOpen
        }
    }
}

enum InboxDetailGroupProjection {
    static func groups(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        InboxDigestGroupProjection.groups(item: item, allItems: allItems)
    }

    static func legacyGroups(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        InboxDigestGroupProjection.legacyGroups(item: item, allItems: allItems)
    }
}

// MARK: - Full inbox list (accessible from chat header or settings)

/// W6/G12 — the two reading lanes. Not a filter over severity or status: a
/// filter over *who the card is addressed to*.
enum InboxLane: String, CaseIterable, Identifiable {
    case forYou
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forYou: return "For you"
        case .system: return "System"
        }
    }

    func matches(_ item: InboxItemRecord) -> Bool {
        switch self {
        case .forYou: return item.isForYouLane
        case .system: return item.isSystemLane
        }
    }
}

/// Production seam for the value emitted by a Review Groups button and the
/// same list population InboxView renders. Keeping it here prevents a group
/// selection from becoming a detail-sheet-only presentation effect.
enum InboxReviewGroupSelection {
    static func select(_ group: InboxRelatedGroup) -> InboxRelatedGroup {
        group
    }

    static func displayItems(
        items: [InboxItemRecord],
        lane: InboxLane,
        showAll: Bool,
        groupFilter: InboxRelatedGroup?
    ) -> [InboxItemRecord] {
        let base = (showAll ? items : items.filter { !$0.isHiddenFromDefaultInbox })
            .filter { lane.matches($0) }
        guard let groupFilter else { return base }
        return base.filter { groupFilter.matches($0) }
    }
}

/// WHAT STILL NEEDS THE PERSON, as opposed to what she has already told him.
///
/// The inbox was one flat list per lane in arrival order, and opening a card
/// marked it read — so an approval he opened, thought about and did not act on
/// sank under the next hour of notices and was gone. READING IS NOT
/// RESOLVING. This derives prominence from the authoritative records the card
/// already carries (its linked approval, and the actions that resolve real
/// work), never from read state, and it deliberately spans BOTH lanes: a
/// request that happens to have been filed under System is still a request.
///
/// Resolution is what removes it. A resolved approval's card stops coming back
/// from the reload, which is the existing tombstone path — no second source of
/// truth about what is outstanding.
enum InboxNeedsYou {
    /// Action ids that mean the person still has to do something. `read` and
    /// `dismiss` are deliberately absent: acknowledging is not deciding.
    static let resolvingActionIDs: Set<String> = [
        "act", "approve", "reject", "open_approvals", "repair",
    ]

    struct Sections {
        let needsYou: [InboxItemRecord]
        let rest: [InboxItemRecord]

        var isEmpty: Bool { needsYou.isEmpty && rest.isEmpty }
    }

    static func needsYou(_ item: InboxItemRecord) -> Bool {
        guard !item.isHiddenFromDefaultInbox else { return false }
        if item.hasLinkedApproval { return true }
        return item.actions.contains { resolvingActionIDs.contains($0.id) }
    }

    /// - Parameter everywhere: the visible population across every lane, so a
    ///   System-lane request is not hidden from the person it is waiting on.
    /// - Parameter lane: the lane's own visible population, which keeps its
    ///   arrival order below.
    static func sections(
        everywhere: [InboxItemRecord],
        lane: [InboxItemRecord]
    ) -> Sections {
        let needsYou = everywhere
            .filter(needsYou)
            .sorted { $0.created_at > $1.created_at }
        let claimed = Set(needsYou.map(\.id))
        return Sections(needsYou: needsYou, rest: lane.filter { !claimed.contains($0.id) })
    }
}

/// One population definition for every Inbox lane count visible at once.  The
/// segment badge and the empty-state pointer both describe unread, default-
/// visible cards; using different filters made a quiet lane claim it had work
/// while its own badge said nothing.
enum InboxLanePresentation {
    /// Inbox navigation is view-local, so every fresh presentation must begin
    /// in the human lane. Keep the default and segment order explicit instead
    /// of inheriting declaration order from `CaseIterable`.
    static let initialLane: InboxLane = .forYou
    static let pickerLanes: [InboxLane] = [.forYou, .system]

    static func unreadVisibleCount(in lane: InboxLane, items: [InboxItemRecord]) -> Int {
        items.count {
            lane.matches($0) && $0.isUnread && !$0.isHiddenFromDefaultInbox
        }
    }
}

/// `engine.inbox.items` is a shared snapshot for badges and compact surfaces;
/// the mounted Inbox also owns an action-time copy. A confirmed reload can
/// remove a card before a stale shared snapshot arrives, so that old snapshot
/// must not put the resolved card back on screen.
enum InboxAppModelMirror {
    struct Snapshot: Equatable {
        let items: [InboxItemRecord]
        let locallyResolvedIDs: Set<String>
    }

    /// A successful Inbox read is authoritative. IDs present before the read
    /// but absent from its result were resolved durably and become tombstones
    /// for later stale AppModel mirror copies.
    static func successfulReload(
        localItems: [InboxItemRecord],
        reloadedItems: [InboxItemRecord],
        locallyResolvedIDs: Set<String>
    ) -> Snapshot {
        let localIDs = Set(localItems.map(\.id))
        let reloadedIDs = Set(reloadedItems.map(\.id))
        let resolved = locallyResolvedIDs.union(localIDs.subtracting(reloadedIDs))
        return Snapshot(
            items: reloadedItems.filter { !resolved.contains($0.id) },
            locallyResolvedIDs: resolved
        )
    }

    /// The shared model is allowed to report a genuine empty inbox. The state
    /// owner equality-gates repeated empty copies, while resolved IDs cannot
    /// be resurrected by a stale mirror snapshot.
    static func modelUpdate(
        modelItems: [InboxItemRecord],
        locallyResolvedIDs: Set<String>
    ) -> Snapshot {
        Snapshot(
            items: modelItems.filter { !locallyResolvedIDs.contains($0.id) },
            locallyResolvedIDs: locallyResolvedIDs
        )
    }
}

/// Visible wording for a failed inbox read, one line: what happened and what
/// to do. When a refresh fails over already rendered cards, say so plainly:
/// those cards are last-known data, not proof the inbox is current. The
/// reader's own error text goes to the log, not the page.
enum InboxLoadFailurePresentation {
    static func banner(error: any Error, retainedItemCount: Int) -> String {
        nativeLog("%@", "[inbox] read failed: \(error.localizedDescription)")
        return retainedItemCount > 0
            ? "Couldn't refresh, so these notes may be out of date. Try Refresh."
            : "Couldn't read your notes. Try Refresh."
    }
}

/// The InboxView's actual refresh boundary. Keeping records and failure state
/// together prevents a failed refresh from leaving last-known rows looking
/// current, and a successful retry clears that adverse state before it
/// publishes replacement rows.
@MainActor @Observable
final class InboxLoadState {
    enum ContentPresentation: Equatable {
        case loading
        case unavailable
        case empty
        case content
    }

    private(set) var items: [InboxItemRecord]
    private(set) var errorText: String?
    private(set) var locallyResolvedIDs: Set<String> = []
    private(set) var hasLoadedSnapshot = false
    private(set) var isLoading = false
    @ObservationIgnored private var refreshGeneration: UInt64 = 0

    init(items: [InboxItemRecord] = []) {
        self.items = items
        hasLoadedSnapshot = !items.isEmpty
    }

    func contentPresentation(hasVisibleItems: Bool) -> ContentPresentation {
        if hasVisibleItems { return .content }
        if errorText != nil { return .unavailable }
        return hasLoadedSnapshot ? .empty : .loading
    }

    @discardableResult
    func reload(
        read: @escaping @MainActor () async throws -> [InboxItemRecord]
    ) async -> Bool {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let priorItems = items
        isLoading = true
        defer {
            if refreshGeneration == generation { isLoading = false }
        }
        do {
            let loaded = try await read()
            guard !Task.isCancelled, refreshGeneration == generation else { return false }
            _ = adopt(InboxAppModelMirror.successfulReload(
                localItems: priorItems,
                reloadedItems: loaded,
                locallyResolvedIDs: locallyResolvedIDs
            ))
            hasLoadedSnapshot = true
            errorText = nil
            return true
        } catch {
            guard !Task.isCancelled, refreshGeneration == generation else { return false }
            errorText = InboxLoadFailurePresentation.banner(
                error: error,
                retainedItemCount: items.count)
            return false
        }
    }

    @discardableResult
    func replaceItems(_ latest: [InboxItemRecord]) -> Bool {
        adopt(InboxAppModelMirror.modelUpdate(
            modelItems: latest,
            locallyResolvedIDs: locallyResolvedIDs
        ))
    }

    func markRead(_ id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }), items[idx].isUnread {
            items[idx].status = "read"
        }
    }

    @discardableResult
    private func adopt(_ snapshot: InboxAppModelMirror.Snapshot) -> Bool {
        var changed = false
        if locallyResolvedIDs != snapshot.locallyResolvedIDs {
            locallyResolvedIDs = snapshot.locallyResolvedIDs
            changed = true
        }
        if items != snapshot.items {
            items = snapshot.items
            changed = true
        }
        return changed
    }
}

/// The two locations that talk about another inbox lane must use one bounded
/// population: visible unread cards. This is a rendered truth contract, not a
/// second inbox state owner.
struct InboxView: View {
    init(initialGroup: InboxRelatedGroup? = nil) {
        _groupFilter = State(initialValue: initialGroup)
    }

    @Environment(AppModel.self) private var appModel

    @State private var inboxLoadState = InboxLoadState()
    @State private var showAll = false
    @State private var groupFilter: InboxRelatedGroup?
    // G12: defaults to the human lane. The operations feed is one click away,
    // it is just no longer the thing User's day opens with.
    @State private var lane: InboxLane = InboxLanePresentation.initialLane

    // R22: source the client from AppModel's canonical `client`.
    private var client: NativeClient { appModel.client }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The sheet around this page already says what it is; one row of
            // controls, then the notes.
            HStack(spacing: NativeAgentSpacing.md) {
                // G12: the segmented control. Unread counts live ON the
                // segments so the System lane is never a silent hiding place.
                Picker("Notification category", selection: $lane) {
                    ForEach(InboxLanePresentation.pickerLanes) { candidate in
                        Text(laneLabel(candidate)).tag(candidate)
                    }
                }
                .accessibilityLabel("Notification category")
                .pickerStyle(.segmented)
                .hazeTinted(.segments)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                if inboxLoadState.isLoading {
                    ProgressView().controlSize(.small)
                }
                Toggle("Show archived", isOn: $showAll)
                    .toggleStyle(.checkbox)
                    .help("Also show notes you archived or dismissed")
                Button("Refresh") { Task { await load() } }
                    .disabled(inboxLoadState.isLoading)
            }
            .font(ShellType.label)
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.vertical, NativeAgentSpacing.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                    if let groupFilter {
                        groupFilterRow(groupFilter)
                    }
                    // Lane-aware: an empty "For you" lane with a full System
                    // lane says which lane is empty and points at the other.
                    switch inboxLoadState.contentPresentation(hasVisibleItems: !prioritySections.isEmpty) {
                    case .loading:
                        AdvancedWaitingLine("Reading your notes…")
                    case .unavailable:
                        AdvancedEmptyState(
                            title: "Couldn't read your notes",
                            detail: "Try again to see what needs you.",
                            actionTitle: "Try again",
                            action: { Task { await load() } }
                        )
                    case .empty:
                        AdvancedEmptyState(
                            title: lane == .forYou ? "Nothing for you right now" : "No system notes",
                            detail: emptyStateDetail
                        )
                    case .content:
                        if let err = inboxLoadState.errorText {
                            Text(err)
                                .font(ShellType.label)
                                .foregroundStyle(NativeAgentShell.trouble)
                        }
                        // Outstanding requests sit above notification history
                        // and stay there once read. Only resolving them clears
                        // them.
                        if !prioritySections.needsYou.isEmpty {
                            section("Needs you", prioritySections.needsYou, waiting: true)
                        }
                        if !prioritySections.rest.isEmpty {
                            section(prioritySections.needsYou.isEmpty ? nil : lane.title, prioritySections.rest)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(NativeAgentSpacing.xl)
            }
        }
        .task { await load() }
        .onChange(of: appModel.engine.inbox.items) { _, latest in
            inboxLoadState.replaceItems(latest)
        }
    }

    private func groupFilterRow(_ group: InboxRelatedGroup) -> some View {
        HStack(spacing: NativeAgentSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(ShellType.labelSemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text("\(displayItems.filter { $0.isUnread }.count) unread, \(displayItems.filter { !$0.isUnread }.count) earlier")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            Spacer(minLength: 0)
            Button("Show all notes") { self.groupFilter = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, AliveMetrics.rowInsetH)
        .padding(.vertical, AliveMetrics.rowInsetV)
        .aliveCard()
    }

    private func section(_ title: String?, _ items: [InboxItemRecord], waiting: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AliveMetrics.eyebrowGap) {
            if let title { AliveEyebrow(title) }
            LazyVStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
                ForEach(items) { row($0, waiting: waiting) }
            }
        }
    }

    private func row(_ item: InboxItemRecord, waiting: Bool) -> some View {
        InboxListRow(
            item: item,
            waiting: waiting,
            allItems: inboxLoadState.items,
            client: client,
            onAction: { Task { await loadAndSync() } },
            onMarkedRead: { markRead(item.id) },
            onSelectGroup: { group in
                groupFilter = InboxReviewGroupSelection.select(group)
            }
        )
    }

    private var displayItems: [InboxItemRecord] {
        InboxReviewGroupSelection.displayItems(
            items: inboxLoadState.items,
            lane: lane,
            showAll: showAll,
            groupFilter: groupFilter
        )
    }

    /// The same visibility rules, across every lane, so a request filed under
    /// System still reaches the person it is waiting on.
    private var visibleEverywhere: [InboxItemRecord] {
        InboxLanePresentation.pickerLanes.flatMap {
            InboxReviewGroupSelection.displayItems(
                items: inboxLoadState.items,
                lane: $0,
                showAll: showAll,
                groupFilter: groupFilter
            )
        }
    }

    private var prioritySections: InboxNeedsYou.Sections {
        InboxNeedsYou.sections(everywhere: visibleEverywhere, lane: displayItems)
    }

    private var emptyStateDetail: String {
        let other: InboxLane = lane == .forYou ? .system : .forYou
        let otherCount = InboxLanePresentation.unreadVisibleCount(in: other, items: inboxLoadState.items)
        if otherCount > 0 {
            return "\(otherCount) unread \(otherCount == 1 ? "note is" : "notes are") in \(other.title)."
        }
        return "When I notice something useful, I'll leave it here."
    }

    /// Unread count per lane, over the same visibility rules the list uses —
    /// a dismissed card must not inflate the segment it sits behind.
    private func laneLabel(_ candidate: InboxLane) -> String {
        let unread = InboxLanePresentation.unreadVisibleCount(in: candidate, items: inboxLoadState.items)
        return unread > 0 ? "\(candidate.title) (\(unread))" : candidate.title
    }

    func load() async {
        let loaded = await inboxLoadState.reload {
            try await appModel.engine.inbox.list()
        }
        if loaded && appModel.engine.inbox.items != inboxLoadState.items {
            appModel.engine.inbox.items = inboxLoadState.items
        }
    }

    func loadAndSync() async {
        await load()
        await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
    }

    // ui-honesty 2026-06-10: after the detail sheet's "read" action succeeds,
    // patch the local copy (and the appModel mirror so badges elsewhere agree)
    // — the unread dot/bold clear immediately without a full reload.
    private func markRead(_ id: String) {
        inboxLoadState.markRead(id)
        appModel.engine.inbox.markRead(id)
    }
}

/// Serializes the direct action buttons on an inbox row.  Keeping the complete
/// success/failure branch here means the visible row can neither double-submit
/// a slow action nor present a failed write as a resolved card.
@MainActor @Observable
final class InboxRowActionFlight {
    enum Outcome: Equatable {
        case dropped
        case succeeded
        case failed(message: String)
    }

    private(set) var isInFlight = false

    func perform(operation: @escaping @MainActor () async throws -> Void) async -> Outcome {
        guard !isInFlight else { return .dropped }
        isInFlight = true
        defer { isInFlight = false }

        do {
            try await operation()
            return .succeeded
        } catch {
            // The writer's text goes to the log; the page says what to do.
            nativeLog("%@", "[inbox] action failed: \(error.localizedDescription)")
            return .failed(message: "That didn't go through. Try again in a moment.")
        }
    }
}

/// Applies the one visible success consequence after an inbox write settles.
/// The inline buttons and detail sheet both call `performAction(_:)`, which
/// uses this owner; a failed/dropped write has no route to a local read patch
/// or a resolved-row reload.
@MainActor
enum InboxRowActionCompletion {
    @discardableResult
    static func apply(
        _ outcome: InboxRowActionFlight.Outcome,
        actionID: String,
        onResolved: () -> Void,
        onMarkedRead: () -> Void
    ) -> InboxRowActionFlight.Outcome {
        guard case .succeeded = outcome else { return outcome }
        if actionID == "read" {
            onMarkedRead()
        } else {
            onResolved()
        }
        return outcome
    }
}

/// One note on the Inbox page: an alive card, with the soft teal top only
/// when it waits on the person. Tapping it opens the detail sheet.
struct InboxListRow: View {
    let item: InboxItemRecord
    var waiting = false
    let allItems: [InboxItemRecord]
    let client: NativeClient
    let onAction: () -> Void
    // ui-honesty 2026-06-10: fired after a successful "read" action so the
    // parent can patch the local item instead of doing a full reload.
    let onMarkedRead: () -> Void
    let onSelectGroup: (InboxRelatedGroup) -> Void

    @State private var showDetail = false
    // The shared action flight owns the row's visible busy state and terminal
    // outcome, rather than relying on a button-local best-effort guard.
    @State private var actionFlight = InboxRowActionFlight()
    // A failed action stays visible as one line under the row's buttons; the
    // row never dismisses on a write that didn't land.
    @State private var actionError: String? = nil

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    @ViewBuilder
    var body: some View {
        if item.source == InteractionCardDelivery.source {
            InteractionInboxCard(item: item)
        } else {
            ordinaryRow
        }
    }

    private var ordinaryRow: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: NativeAgentSpacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(item.isUnread ? ShellType.bodySemibold : ShellType.body)
                        .foregroundStyle(NativeAgentShell.text)
                    Text(item.summary)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .lineLimit(2)
                    Text(item.isUnread ? "New · \(item.sourceWord)" : item.sourceWord)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .accessibilityHidden(true)
            }

            if !visibleActions.isEmpty {
                // One main button, the rest in the Mac's own menu (User 09-27:
                // all controls native; no sideways-scrolling button strip).
                let primary = visibleActions.filter { InboxActionWords.isPrimary($0.id) }
                let others = visibleActions.filter { !InboxActionWords.isPrimary($0.id) }
                HStack(spacing: NativeAgentSpacing.sm) {
                    ForEach(primary, id: \.id) { action in
                        Button(action.label) { runAction(action.id) }
                            .buttonStyle(.borderedProminent)
                            .hazeTinted(.button)
                            .controlSize(.small)
                            .disabled(actionFlight.isInFlight)
                    }
                    if !others.isEmpty {
                        Menu {
                            ForEach(others, id: \.id) { action in
                                Button(action.label) { runAction(action.id) }
                            }
                        } label: {
                            Text(primary.isEmpty ? "Actions" : "More")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(actionFlight.isInFlight)
                    }
                }
            }

            if let actionError {
                Text(actionError)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.trouble)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AliveMetrics.rowInsetH)
        .padding(.vertical, AliveMetrics.rowInsetV)
        .aliveCard(waiting: waiting)
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .sheet(isPresented: $showDetail) {
            InboxItemDetailSheet(
                item: item,
                allItems: allItems,
                onAction: { actionID in
                    await performAction(actionID)
                },
                onOpenGroup: onSelectGroup,
                onClose: { showDetail = false }
            )
            .presentationDetents([.medium, .large])
        }
    }

    private func runAction(_ actionID: String) {
        actionError = nil
        Task { @MainActor in
            let outcome = await performAction(actionID)
            if case .failed = outcome { actionError = InboxActionWords.failure(actionID) }
        }
    }

    /// The only native-client action path for both inline row buttons and the
    /// detail sheet. Success callbacks are deliberately chosen here, after the
    /// durable write, so the two surfaces cannot drift on read vs. resolution.
    private func performAction(_ actionID: String) async -> InboxRowActionFlight.Outcome {
        let outcome = await actionFlight.perform {
            try await client.inboxAction(item.id, action: actionID)
        }
        return InboxRowActionCompletion.apply(
            outcome,
            actionID: actionID,
            onResolved: onAction,
            onMarkedRead: onMarkedRead
        )
    }
}
