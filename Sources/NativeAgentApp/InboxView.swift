// PATCH-2026-05-07: proactive-inbox-1 InboxView — proactive inbox card strip
import SwiftUI
import NativeAgentShared
import NativeAgentCore

// MARK: - Models

struct InboxItemRecord: Identifiable, Codable, Hashable {
    let id: String
    let created_at: String
    let source: String
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
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
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
        if hasLinkedApproval { return "APPROVAL" }
        if source.hasPrefix("proactive_autonomy") { return "IDEA" }
        if source.hasPrefix("harness_learning") { return "LEARNING" }
        if source == "dream_cycle" { return "DREAM" }
        if source == "rem_cycle" { return "REM" }
        if source.hasPrefix("trigger:file_watch") { return "FILE-WATCH" }
        if source.hasPrefix("trigger:morning_brief") { return "MORNING-BRIEF" }
        if source.hasPrefix("trigger:stuck_pattern") { return "STUCK-PATTERNS" }
        if source == "idle_checkin" { return "IDLE-CHECKIN" }
        if ExecutionEventVocabulary.hasKindPrefix(source, WorkshopCompletionTrigger.canonicalKind) {
            return "WORKSHOP"
        }
        // ui-taste-sweep 2026-06-07: previously fell through to
        // `String(source.uppercased().prefix(14))` which truncated
        // "scheduled_proactive_scan" → "SCHEDULED_PROA" (mid-word, leaking
        // a raw enum). Now: replace underscores with spaces and truncate
        // on whole-word boundaries so the badge reads as a label.
        if source == "scheduled_proactive_scan" { return "PROACTIVE SCAN" }
        let humanized = source.uppercased().replacingOccurrences(of: "_", with: " ")
        if humanized.count <= 16 { return humanized }
        // Truncate to last full word that fits in 16 chars.
        var truncated = ""
        for word in humanized.split(separator: " ") {
            let candidate = truncated.isEmpty ? String(word) : truncated + " " + word
            if candidate.count > 16 { break }
            truncated = candidate
        }
        return truncated.isEmpty ? String(humanized.prefix(16)) : truncated
    }
}

struct InboxRelatedGroup: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let count: Int
    let item_ids: [String]?
    let source: String?

    var itemIDs: Set<String> {
        Set(item_ids ?? [])
    }

    var displayCount: Int {
        max(count, item_ids?.count ?? 0)
    }

    func matches(_ item: InboxItemRecord) -> Bool {
        if item.id == id { return false }
        let ids = itemIDs
        if !ids.isEmpty && ids.contains(item.id) {
            return true
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTitle.isEmpty && item.title == cleanTitle
    }
}

struct InboxActionRecord: Codable, Hashable {
    let id: String
    let label: String
    let description: String?
}

struct InboxTriggerConfig: Identifiable, Codable, Hashable {
    let name: String
    var enabled: Bool
    // config is dynamic — stored as [String: String] for watched paths access
    var config: [String: String]?   // only string-valued keys used in UI
    let description: String?

    var id: String { name }

    // Custom decoder to tolerate any config value types (arrays, bools, ints)
    // by only capturing string-valued keys
    enum CodingKeys: String, CodingKey {
        case name, enabled, config, description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
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
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(config, forKey: .config)
    }

    // Memberwise initializer for non-Codable paths
    init(name: String, enabled: Bool, config: [String: String]? = nil, description: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.config = config
        self.description = description
    }

    var displayName: String {
        switch name {
        case "file_watch":       return "File Watcher"
        case "idle_checkin":     return "Idle Check-In"
        case "morning_brief":    return "Morning Brief"
        case WorkshopCompletionTrigger.canonicalName,
             WorkshopCompletionTrigger.legacyName: return "Workshop Follow-up"
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

struct InboxStripView: View {
    let items: [InboxItemRecord]
    let onAction: (String, String) async -> Void

    @State private var selectedItem: InboxItemRecord?
    @State private var showSheet = false

    private var visibleItems: [InboxItemRecord] {
        items.filter { $0.isUnread }.prefix(3).map { $0 }
    }

    private var overflowCount: Int {
        max(0, items.filter { $0.isUnread }.count - 3)
    }

    var body: some View {
        if visibleItems.isEmpty { EmptyView() }
        else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleItems) { item in
                            InboxCardView(item: item) {
                                selectedItem = item
                                showSheet = true
                            }
                        }
                        if overflowCount > 0 {
                            Text("+\(overflowCount) more")
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
                        Task {
                            await onAction(item.id, actionID)
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
        .buttonStyle(.plain)
        .frame(width: 224)
    }
}

// MARK: - Detail sheet
// PATCH-2026-05-07: polish-InboxView AuroraBackground + GlassCard header in detail sheet

struct InboxItemDetailSheet: View {
    let item: InboxItemRecord
    var allItems: [InboxItemRecord] = []
    let onAction: (String) -> Void
    var onOpenGroup: ((InboxRelatedGroup) -> Void)? = nil
    let onClose: () -> Void

    private var visibleActions: [InboxActionRecord] {
        item.effectiveActions.filter { action in
            !["view", "read", "reply"].contains(action.id)
        }
    }

    private var relatedGroups: [InboxRelatedGroup] {
        if let groups = item.related_groups, !groups.isEmpty {
            return groups
        }
        return Self.groupsFromDigestDetail(item: item, allItems: allItems)
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
                                        .buttonStyle(.plain)
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
                                                performAndClose(action.id)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(.orange)
                                        } else {
                                            Button(action.label) {
                                                performAndClose(action.id)
                                            }
                                            .buttonStyle(.bordered)
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
        .onAppear { onAction("read") }
    }

    private func isPrimaryAction(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

    private func performAndClose(_ actionID: String) {
        onAction(actionID)
        onClose()
    }

    private static func groupsFromDigestDetail(item: InboxItemRecord, allItems: [InboxItemRecord]) -> [InboxRelatedGroup] {
        guard item.source == "autonomy_maintenance:inbox_digest",
              let detail = item.detail,
              detail.contains("Top groups:")
        else { return [] }
        let lines = detail.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Top groups:" }) else {
            return []
        }
        var groups: [InboxRelatedGroup] = []
        for rawLine in lines.dropFirst(start + 1) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            guard line.hasPrefix("- ") else { break }
            let entry = String(line.dropFirst(2))
            let parsed = parseDigestGroupLine(entry)
            let matchingIDs = allItems
                .filter { $0.id != item.id && $0.title == parsed.title }
                .map(\.id)
            groups.append(InboxRelatedGroup(
                id: "digest-\(groups.count)-\(parsed.title)",
                title: parsed.title,
                count: parsed.count,
                item_ids: matchingIDs,
                source: nil
            ))
        }
        return groups
    }

    private static func parseDigestGroupLine(_ entry: String) -> (title: String, count: Int) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return (trimmed, 0)
        }
        let title = String(trimmed[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        let countText = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        return (title, Int(String(countText)) ?? 0)
    }
}

// MARK: - Full inbox list (accessible from chat header or settings)

struct InboxView: View {
    @Environment(AppModel.self) private var appModel

    @State private var items: [InboxItemRecord] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var showAll = false
    @State private var groupFilter: InboxRelatedGroup?

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
                .disabled(isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let err = errorText {
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

            if items.isEmpty && !isLoading {
                NativeEmptyState(
                    title: "Nothing here yet",
                    detail: "When \(appModel.personality?.name ?? "your agent") notices something useful, it will appear here.",
                    systemImage: "tray",
                    actionTitle: nil, actionImage: nil, action: nil
                )
                .frame(minHeight: 200)
            } else {
                List(displayItems) { item in
                    InboxListRow(
                        item: item,
                        allItems: items,
                        client: client,
                        onAction: { Task { await loadAndSync() } },
                        onMarkedRead: { markRead(item.id) },
                        onSelectGroup: { group in groupFilter = group }
                    )
                }
                .listStyle(.plain)
            }
        }
        .task { await load() }
        .onChange(of: appModel.inboxItems) { _, latest in
            guard !latest.isEmpty || !items.isEmpty else { return }
            items = latest
        }
    }

    private var displayItems: [InboxItemRecord] {
        let base = showAll ? items : items.filter { !$0.isHiddenFromDefaultInbox }
        guard let groupFilter else { return base }
        return base.filter { groupFilter.matches($0) }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // ui-honesty 2026-06-10: clear the previous error at the start of
        // every load — a stale failure banner used to persist over a
        // subsequent successful refresh.
        errorText = nil
        do {
            items = try await client.getInboxItems(unreadOnly: false)
            appModel.inboxItems = items
        } catch {
            errorText = error.localizedDescription
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
        if let idx = items.firstIndex(where: { $0.id == id }), items[idx].isUnread {
            items[idx].status = "read"
        }
        if let idx = appModel.inboxItems.firstIndex(where: { $0.id == id }),
           appModel.inboxItems[idx].isUnread {
            appModel.inboxItems[idx].status = "read"
        }
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
    // ui-honesty 2026-06-10: in-flight guard — disables the row's action
    // buttons while a request runs so a double-click can't double-fire.
    @State private var isActing = false
    // gpt-5.5 review-2 R2-#1 follow-up: ContentView's InboxStripView already
    // surfaces inbox-action errors (e.g. the new -410 "primary-action resolver
    // not wired" from inboxAction(act:)). The main InboxView used `try?` and
    // swallowed everything — the user pressed "Act," saw the row dismiss,
    // and never learned the action didn't fire. Mirror the strip pattern.
    @State private var actionError: String? = nil

    private var visibleActions: [InboxActionRecord] {
        item.effectiveActions.filter { action in
            !["view", "read", "reply"].contains(action.id)
        }
    }

    var body: some View {
        GlassCard(tint: item.isUnread ? item.severityColor : nil) {
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
                                    .disabled(isActing)
                                } else {
                                    Button(action.label) {
                                        runAction(action.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isActing)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onTapGesture { showDetail = true }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .sheet(isPresented: $showDetail) {
            InboxItemDetailSheet(
                item: item,
                allItems: allItems,
                onAction: { actionID in
                    Task {
                        do {
                            try await client.inboxAction(item.id, action: actionID)
                        } catch {
                            // gpt-5.5 review-2 R2-#1 follow-up: surface the
                            // failure instead of swallowing — same pattern
                            // as InboxStripView in ContentView.swift. Do NOT
                            // call onAction() on failure (would mark the row
                            // resolved when it isn't).
                            actionError = "Inbox action failed: \(error.localizedDescription)"
                            return
                        }
                        if actionID == "read" {
                            // ui-honesty 2026-06-10: patch the local copy so
                            // the unread dot/bold clear immediately — the
                            // server write succeeded but no reload runs for
                            // the read action.
                            onMarkedRead()
                        } else {
                            onAction()
                        }
                    }
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
        // ui-honesty 2026-06-10: in-flight guard — a second click while the
        // request is running double-fired the action.
        guard !isActing else { return }
        isActing = true
        Task {
            defer { isActing = false }
            do {
                try await client.inboxAction(item.id, action: actionID)
            } catch {
                // gpt-5.5 review-2 R2-#1 follow-up: surface, don't swallow.
                actionError = "Inbox action failed: \(error.localizedDescription)"
                return
            }
            onAction()
        }
    }
}
