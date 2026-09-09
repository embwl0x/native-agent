// PATCH-2026-05-07: proactive-inbox-1 InboxView — proactive inbox card strip
import SwiftUI
import Observation
import NativeAgentShared
import NativeAgentCore

// MARK: - Models

/// The inbox reader deliberately keeps cards with a bad optional source rather
/// than dropping the whole record. Preserve why the source is unavailable so
/// the visible provenance badge does not turn a bad wire value into silence.
enum InboxSourceReadState: Hashable {
    case present
    case missing
    case malformed
}

struct InboxItemRecord: Identifiable, Codable, Hashable {
    let id: String
    let created_at: String
    let source: String
    let sourceReadState: InboxSourceReadState
    let severity: String      // info | important | actionable
    let title: String
    let summary: String
    let detail: String?
    let relatedWorkshopExecutionId: String?
    let related_approval_id: String?
    let related_paths: [String]?
    let related_groups: [InboxRelatedGroup]?
    let actions: [InboxActionRecord]
    // ui-honesty 2026-06-10: `var` so the UI can patch a row to "read" locally
    // after a successful read action, without waiting on a full reload.
    var status: String        // unread | read | archived | dismissed
    let read_at: String?

    enum CodingKeys: String, CodingKey {
        case id, created_at, source, severity, title, summary, detail
        case relatedWorkshopExecutionId = "related_mission_id" // compatibility wire ID
        case related_approval_id, related_paths, related_groups
        case actions, status, read_at
    }

    /// Wave 4 (phase A) read-both: accept the FUTURE `related_execution_id`
    /// spelling as well as the on-wire `related_mission_id` above. Decode-only —
    /// `encode(to:)` below still writes `related_mission_id`, so the inbox
    /// snapshot a 0.3.7 iOS install reads is byte-identical.
    private enum FutureCodingKeys: String, CodingKey {
        case related_execution_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        created_at = (try? c.decode(String.self, forKey: .created_at)) ?? ""
        if !c.contains(.source) {
            source = ""
            sourceReadState = .missing
        } else if let decodedSource = try? c.decode(String.self, forKey: .source) {
            source = decodedSource
            sourceReadState = .present
        } else {
            source = ""
            sourceReadState = .malformed
        }
        severity = (try? c.decode(String.self, forKey: .severity)) ?? "info"
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        let futureRelatedExecutionId: String? = {
            guard let future = try? decoder.container(keyedBy: FutureCodingKeys.self) else {
                return nil
            }
            return try? future.decodeIfPresent(String.self, forKey: .related_execution_id)
        }()
        relatedWorkshopExecutionId = futureRelatedExecutionId
            ?? (try? c.decodeIfPresent(String.self, forKey: .relatedWorkshopExecutionId))
            ?? nil
        related_approval_id = try? c.decodeIfPresent(String.self, forKey: .related_approval_id)
        related_paths = try? c.decodeIfPresent([String].self, forKey: .related_paths)
        related_groups = try? c.decodeIfPresent([InboxRelatedGroup].self, forKey: .related_groups)
        actions = (try? c.decode([InboxActionRecord].self, forKey: .actions)) ?? []
        status = (try? c.decode(String.self, forKey: .status)) ?? "unread"
        read_at = try? c.decodeIfPresent(String.self, forKey: .read_at)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(created_at, forKey: .created_at)
        try c.encode(source, forKey: .source)
        try c.encode(severity, forKey: .severity)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(relatedWorkshopExecutionId, forKey: .relatedWorkshopExecutionId)
        try c.encodeIfPresent(related_approval_id, forKey: .related_approval_id)
        try c.encodeIfPresent(related_paths, forKey: .related_paths)
        try c.encodeIfPresent(related_groups, forKey: .related_groups)
        try c.encode(actions, forKey: .actions)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(read_at, forKey: .read_at)
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isUnread: Bool { normalizedStatus == "unread" }
    var isActivityPending: Bool {
        normalizedStatus == "unread" || normalizedStatus == "active"
    }
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

    // MARK: - W6/G12 — "For you" vs "System"

    /// Sources whose vocabulary is OPERATIONS, not work.
    ///
    /// G12's finding is a ratio problem, not a producer problem: count the
    /// producers and the machine-health lanes outnumber the human-shaped ones,
    /// so User opens his day to *Background loop "heartbeat" started failing ·
    /// Disk hygiene · Review scheduler errors*. This predicate is the whole
    /// split — no producer changes, no new store, no new card shape.
    ///
    /// The seven named in the L5 evidence, plus the operational sources found
    /// in the live feed that the doc's enumeration predates (`provider_vitals`,
    /// the `memory_*` maintenance jobs, `self_test`). Every one of them reports
    /// on the app's own machinery.
    static let systemLaneSources: Set<String> = [
        "background_loop",
        "disk_hygiene",
        "doctor",
        "heartbeat",
        "provider_vitals",
        "self_test",
        "memory_consolidation",
        "memory_repair",
        "memory_kind_backfill",
    ]

    /// Proactive-scan kinds that are self-referential housekeeping. These
    /// arrive as `proactive_autonomy:<kind>:<opportunityId>`, so the lane test
    /// has to read the KIND component — matching on the raw source would put
    /// every proactive card in one lane regardless of what it is about.
    static let systemLaneProactiveKinds: Set<String> = [
        "scheduler_health",
        "approval_backlog",
        "inbox_digest",
    ]

    var isSystemLane: Bool {
        let lower = source.lowercased()
        if Self.systemLaneSources.contains(lower) { return true }
        if lower.hasPrefix("proactive_autonomy:") {
            let parts = lower.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 2, Self.systemLaneProactiveKinds.contains(String(parts[1])) {
                return true
            }
        }
        // `loop-failure:*` and the maintenance producers prefix rather than
        // match exactly.
        if lower.hasPrefix("background_loop") || lower.hasPrefix("loop-failure:") { return true }
        return false
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

    var supportsRealManualFire: Bool {
        kind == "time" || kind == "idle" || name == "morning_brief" || name == "idle_checkin"
    }

    var displayName: String {
        switch name {
        case "file_watch":       return "File Watcher"
        case "idle_checkin":     return "Idle Check-In"
        case "morning_brief":    return "Morning Brief"
        case WorkshopCompletionTrigger.canonicalName,
             WorkshopCompletionTrigger.legacyName: return "Desk Follow-up"
        case "stuck_pattern":    return "Stuck Pattern"
        default:                 return name
        }
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

// MARK: - Compact inbox strip (shown above chat messages)

/// The compact strip is deliberately a projection of the unread set, rather
/// than two independently filtered collections. That makes the visible cards
/// and the overflow badge account for the same bounded result.
struct InboxStripDisplay: Equatable {
    static let visibleLimit = 3

    let visibleItems: [InboxItemRecord]
    let overflowCount: Int
    let unreadCount: Int

    init(items: [InboxItemRecord]) {
        let unreadItems = items.filter(\.isUnread)
        unreadCount = unreadItems.count
        visibleItems = Array(unreadItems.prefix(Self.visibleLimit))
        overflowCount = max(0, unreadCount - visibleItems.count)
    }

    var isQuiet: Bool { unreadCount == 0 }
}

struct InboxStripView: View {
    let items: [InboxItemRecord]
    let onAction: @MainActor (String, String) async throws -> Void

    @State private var selectedItem: InboxItemRecord?
    @State private var showSheet = false
    @State private var actionFlight = InboxRowActionFlight()

    private var display: InboxStripDisplay {
        InboxStripDisplay(items: items)
    }

    var body: some View {
        if display.isQuiet { EmptyView() }
        else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(display.visibleItems) { item in
                            InboxCardView(item: item) {
                                selectedItem = item
                                showSheet = true
                            }
                        }
                        if display.overflowCount > 0 {
                            Text("+\(display.overflowCount) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                Divider()
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
    }
}

// MARK: - Single inbox card
// PATCH-2026-05-07: polish-InboxView GlassCard tinted by severity, PulsingDot for unread

struct InboxCardView: View {
    let item: InboxItemRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            GlassCard(tint: item.severityColor) {
                HStack(alignment: .top, spacing: 8) {
                    ZStack {
                        Image(systemName: item.sourceIcon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.severityColor)
                            .frame(width: 18)
                            .padding(.top, 1)
                        if item.isUnread {
                            PulsingDot(color: item.severityColor, size: 6)
                                .offset(x: 8, y: -6)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        Text(item.summary)
                            .font(.caption2)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 200, alignment: .leading)
            }
        }
        .buttonStyle(.naFeel)
        .frame(width: 224)
    }
}

// MARK: - Detail sheet
// PATCH-2026-05-07: polish-InboxView AuroraBackground + GlassCard header in detail sheet

struct InboxItemDetailSheet: View {
    let item: InboxItemRecord
    var allItems: [InboxItemRecord] = []
    let onAction: @MainActor (String) async -> InboxRowActionFlight.Outcome
    var onOpenGroup: ((InboxRelatedGroup) -> Void)? = nil
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
        NavigationStack {
            ZStack {
                AuroraBackground(colors: [item.severityColor, .purple])
                    .opacity(0.12)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header card
                        GlassCard(tint: item.severityColor) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.sourceIcon)
                                    .font(.title2)
                                    .foregroundStyle(item.severityColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(NativeAgentFont.section)
                                    Text(item.sourceBadgeLabel)
                                        .font(NativeAgentFont.label)
                                        .foregroundStyle(item.severityColor)
                                }
                                Spacer()
                                StatusBadge(text: item.severity, status: item.severity == "actionable" ? "warn" : "info")
                            }
                        }

                        NativePanel(tint: item.severityColor) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.summary)
                                    .font(NativeAgentFont.body)
                                    .foregroundStyle(.primary)

                                if let detail = item.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 4)
                                }
                            }
                        }

                        if let paths = item.related_paths, !paths.isEmpty {
                            NativePanel(title: "Related Files", systemImage: "doc.text", tint: .blue) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(paths.prefix(5), id: \.self) { p in
                                        Text(p)
                                            .font(NativeAgentFont.mono)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if let onOpenGroup, !relatedGroups.isEmpty {
                            NativePanel(title: "Review Groups", systemImage: "tray.full", tint: item.severityColor) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(relatedGroups) { group in
                                        Button {
                                            onOpenGroup(group)
                                            onClose()
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "tray.full")
                                                    .foregroundStyle(item.severityColor)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(group.title)
                                                        .font(NativeAgentFont.label)
                                                        .foregroundStyle(.primary)
                                                        .multilineTextAlignment(.leading)
                                                    Text("\(group.displayCount) item\(group.displayCount == 1 ? "" : "s")")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Image(systemName: "chevron.right")
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(item.severityColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                        }
                                        .buttonStyle(.naFeel)
                                    }
                                }
                            }
                        }

                        // Action buttons
                        if !visibleActions.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(visibleActions, id: \.id) { action in
                                        if isPrimaryAction(action.id) {
                                            Button(action.label) {
                                                perform(action.id, closesOnSuccess: true)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.orange)
                                            .disabled(isActing)
                                        } else {
                                            Button(action.label) {
                                                perform(action.id, closesOnSuccess: true)
                                            }
                                            .buttonStyle(.bordered)
                                            .disabled(isActing)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Inbox item")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // `.onAppear` below already marks the item read when the
                    // sheet opens; marking it again on Close double-fired the
                    // read action for every sheet the user opened.
                    Button("Close") { onClose() }
                }
            }
        }
        .onAppear { perform("read", closesOnSuccess: false) }
        .alert(
            "Inbox action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            actions: { Button("OK", role: .cancel) { actionError = nil } },
            message: { Text(actionError ?? "") }
        )
    }

    private func isPrimaryAction(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

    private func perform(_ actionID: String, closesOnSuccess: Bool) {
        guard !isActing else { return }
        isActing = true
        Task { @MainActor in
            defer { isActing = false }
            let outcome = await onAction(actionID)
            switch InboxDetailActionPresentation.effect(
                for: outcome,
                closesOnSuccess: closesOnSuccess
            ) {
            case .dismiss:
                onClose()
            case .showError(let message):
                actionError = message
            case .keepOpen:
                break
            }
        }
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

/// The only route from a persisted digest card to its Review Groups controls.
/// New cards use the structured wire; prose remains compatibility for existing
/// JSONL cards only.
extension InboxItemRecord: InboxDigestItem {}
extension InboxRelatedGroup: InboxDigestGroup {}

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

/// `AppModel.inboxItems` is a shared snapshot for badges and compact surfaces;
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

/// Visible, bounded wording for a failed inbox read. When a refresh fails over
/// already rendered cards, say so plainly: those cards are last-known data,
/// not proof that the current inbox is healthy.
enum InboxLoadFailurePresentation {
    static let maxDetailCharacters = 240

    static func banner(error: any Error, retainedItemCount: Int) -> String {
        let rawDetail = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = rawDetail.isEmpty
            ? "The inbox reader returned no error details."
            : String(rawDetail.prefix(maxDetailCharacters))
        let retained = retainedItemCount == 1
            ? "Inbox couldn't refresh — showing 1 previously loaded item."
            : retainedItemCount > 1
                ? "Inbox couldn't refresh — showing \(retainedItemCount) previously loaded items."
                : "Inbox couldn't load."
        return "\(retained) \(detail)"
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
            HStack {
                GradientText(
                    text: "Inbox",
                    colors: [.orange, .pink],
                    font: NativeAgentFont.title
                )
                Spacer()
                Toggle("All", isOn: $showAll)
                    .toggleStyle(.button)
                    .font(.caption)
                    .controlSize(.small)
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(inboxLoadState.isLoading)
                .help("Refresh inbox")
                .accessibilityLabel("Refresh inbox")
                if inboxLoadState.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // G12: the segmented control. Unread counts live ON the segments so
            // the System lane is never a silent hiding place — User can see it
            // has three things in it without switching to it.
            Picker("Notification category", selection: $lane) {
                ForEach(InboxLanePresentation.pickerLanes) { candidate in
                    Text(laneLabel(candidate)).tag(candidate)
                }
            }
            .accessibilityLabel("Notification category")
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let err = inboxLoadState.errorText {
                Text(err).font(NativeAgentFont.label).foregroundStyle(NativeAgentTheme.fail).padding(.horizontal)
            }

            if let groupFilter {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(groupFilter.title)
                            .font(NativeAgentFont.label.weight(.semibold))
                        Text("\(displayItems.filter { $0.isUnread }.count) unread, \(displayItems.filter { !$0.isUnread }.count) earlier")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") { self.groupFilter = nil }
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Divider()

            // Lane-aware: an empty "For you" lane with a full System lane must
            // not render a blank List. It says which lane is empty and, when
            // the other one has something, points at it.
            switch inboxLoadState.contentPresentation(hasVisibleItems: !displayItems.isEmpty) {
            case .loading:
                ProgressView("Loading inbox")
                    .frame(maxWidth: .infinity, minHeight: 200)
            case .unavailable:
                NativeEmptyState(
                    title: "Inbox unavailable",
                    detail: "These notifications could not be checked. Retry to see what needs your attention.",
                    systemImage: "exclamationmark.triangle",
                    actionTitle: "Retry",
                    actionImage: "arrow.clockwise",
                    action: { Task { await load() } }
                )
                .frame(minHeight: 200)
            case .empty:
                NativeEmptyState(
                    title: lane == .forYou ? "Nothing for you right now" : "No system notices",
                    detail: emptyStateDetail,
                    systemImage: "tray",
                    actionTitle: nil, actionImage: nil, action: nil
                )
                .frame(minHeight: 200)
            case .content:
                List(displayItems) { item in
                    InboxListRow(
                        item: item,
                        allItems: inboxLoadState.items,
                        client: client,
                        onAction: { Task { await loadAndSync() } },
                        onMarkedRead: { markRead(item.id) },
                        onSelectGroup: { group in
                            groupFilter = InboxReviewGroupSelection.select(group)
                        }
                    )
                }
                .listStyle(.plain)
            }
        }
        .task { await load() }
        .onChange(of: appModel.inboxItems) { _, latest in
            inboxLoadState.replaceItems(latest)
        }
    }

    private var displayItems: [InboxItemRecord] {
        InboxReviewGroupSelection.displayItems(
            items: inboxLoadState.items,
            lane: lane,
            showAll: showAll,
            groupFilter: groupFilter
        )
    }

    private var emptyStateDetail: String {
        let other: InboxLane = lane == .forYou ? .system : .forYou
        let otherCount = InboxLanePresentation.unreadVisibleCount(in: other, items: inboxLoadState.items)
        if otherCount > 0 {
            return "\(otherCount) item(s) are waiting in \(other.title)."
        }
        return "When \(appModel.personality?.name ?? "your agent") notices something useful, it will appear here."
    }

    /// Unread count per lane, over the same visibility rules the list uses —
    /// a dismissed card must not inflate the segment it sits behind.
    private func laneLabel(_ candidate: InboxLane) -> String {
        let unread = InboxLanePresentation.unreadVisibleCount(in: candidate, items: inboxLoadState.items)
        return unread > 0 ? "\(candidate.title) (\(unread))" : candidate.title
    }

    func load() async {
        let loaded = await inboxLoadState.reload {
            try await client.getInboxItems(unreadOnly: false)
        }
        if loaded && appModel.inboxItems != inboxLoadState.items {
            appModel.inboxItems = inboxLoadState.items
        }
    }

    func loadAndSync() async {
        await load()
        await MacSyncEngine.shared.writeSnapshots()
    }

    // ui-honesty 2026-06-10: after the detail sheet's "read" action succeeds,
    // patch the local copy (and the appModel mirror so badges elsewhere agree)
    // — the unread dot/bold clear immediately without a full reload.
    private func markRead(_ id: String) {
        inboxLoadState.markRead(id)
        if let idx = appModel.inboxItems.firstIndex(where: { $0.id == id }),
           appModel.inboxItems[idx].isUnread {
            appModel.inboxItems[idx].status = "read"
        }
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
            let message = "Inbox action failed: \(error.localizedDescription)"
            return .failed(message: message)
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

// PATCH-2026-05-07: polish-InboxView GlassCard list rows tinted by severity, PulsingDot for unread
struct InboxListRow: View {
    let item: InboxItemRecord
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
    // gpt-5.5 review-2 R2-#1 follow-up: ContentView's InboxStripView already
    // surfaces inbox-action errors (e.g. the new -410 "primary-action resolver
    // not wired" from inboxAction(act:)). The main InboxView used `try?` and
    // swallowed everything — the user pressed "Act," saw the row dismiss,
    // and never learned the action didn't fire. Mirror the strip pattern.
    @State private var actionError: String? = nil

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    var body: some View {
        GlassCard(tint: item.isUnread ? item.severityColor : nil, scrollRow: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: item.sourceIcon)
                            .font(.body)
                            .foregroundStyle(item.severityColor)
                            .frame(width: 22)
                            .padding(.top, 2)
                        if item.isUnread {
                            PulsingDot(color: item.severityColor, size: 6)
                                .offset(x: 6, y: -2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(NativeAgentFont.body.weight(item.isUnread ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        Text(item.summary)
                            .font(NativeAgentFont.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !visibleActions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(visibleActions, id: \.id) { action in
                                if isPrimaryAction(action.id) {
                                    Button(action.label) {
                                        runAction(action.id)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                    .controlSize(.small)
                                    .disabled(actionFlight.isInFlight)
                                } else {
                                    Button(action.label) {
                                        runAction(action.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(actionFlight.isInFlight)
                                }
                            }
                        }
                    }
                }
            }
        }
        .naInteractive()
        .onTapGesture { showDetail = true }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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
        .alert(
            "Inbox action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ),
            actions: { Button("OK", role: .cancel) { actionError = nil } },
            message: { Text(actionError ?? "") }
        )
    }

    private func isPrimaryAction(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

    private func runAction(_ actionID: String) {
        Task { @MainActor in
            let outcome = await performAction(actionID)
            if case .failed(let message) = outcome { actionError = message }
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
