import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Desk
import TriggerScheduler

public enum NativeAgentScheduledProactiveScan {
    public struct Opportunity: Sendable, Equatable {
        public let id: String
        public let kind: String
        public let title: String
        public let summary: String
        public let detail: String
        public let source: String
        public let severity: String
        public let score: Double
        public let relatedPaths: [String]
        /// Structured inbox groups are the wire for the Desk's Review Groups
        /// control. They are not reconstructed from presentation prose.
        public let relatedGroups: [JSONValue]

        init(
            id: String,
            kind: String,
            title: String,
            summary: String,
            detail: String,
            source: String,
            severity: String,
            score: Double,
            relatedPaths: [String],
            relatedGroups: [JSONValue] = []
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.summary = summary
            self.detail = detail
            self.source = source
            self.severity = severity
            self.score = score
            self.relatedPaths = relatedPaths
            self.relatedGroups = relatedGroups
        }
    }

    public struct Result: Sendable, Equatable {
        public let scannedCount: Int
        public let eligibleCount: Int
        public let skippedAlreadySurfacedCount: Int
        public let surfaced: [Opportunity]
    }

    public static func inboxActions(for opportunity: Opportunity) -> [JSONValue] {
        switch opportunity.kind.lowercased() {
        case "approval_backlog":
            return [
                inboxAction(id: "view", label: "View", description: "Review the proactive card"),
                inboxAction(id: "open_approvals", label: "Open Approvals", description: "Review pending approvals"),
                inboxAction(id: "archive", label: "Archive", description: "Keep as handled"),
                inboxAction(id: "dismiss", label: "Dismiss", description: "Mark this idea as not useful"),
            ]
        default:
            return []
        }
    }

    // MARK: - W6/G5 — a project-shaped opportunity

    /// Days a `now`/`next` Desk item may sit untouched before the scan asks
    /// about it. Five is deliberately about a working week: shorter and it nags
    /// on work that is simply in progress.
    static let defaultDeskStaleDays = 5

    /// Desk items the scan is allowed to ask about. `now`/`next` only — these
    /// are the statuses that CLAIM to be the current front of the work, so an
    /// untouched one is a real question. `watch`/`todo` are backlog by
    /// definition and asking about them would be nagging.
    static let deskOpportunityStatuses: Set<DeskStatus> = [.now, .next]

    public static func evaluate(
        dataRoot: URL,
        payload: [String: JSONValue],
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: Date = Date(),
        deskItemsProvider: (@Sendable (URL) async -> [DeskItem])? = nil
    ) async throws -> Result {
        let limit = max(1, min(int(payload["limit"], default: 10), 50))
        let surfaceLimit = max(0, min(int(payload["surfaceLimit"] ?? payload["surface_limit"], default: 4), 12))
        guard surfaceLimit > 0 else {
            return Result(scannedCount: 0, eligibleCount: 0, skippedAlreadySurfacedCount: 0, surfaced: [])
        }

        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let schedulerPath = dataRoot
            .appendingPathComponent("scheduler", isDirectory: true)
            .appendingPathComponent("jobs.json")
        let approvalsPath = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("approvals", isDirectory: true)
            .appendingPathComponent("requests.json")

        let inboxRows = (try? await persistence.readJSONL(inboxPath)) ?? []
        let schedulerRaw = try await persistence.readJSON(schedulerPath, ifMissing: .array([]))
        let approvalsRaw = try await persistence.readJSON(approvalsPath, ifMissing: .array([]))

        let deskStaleDays = max(1, int(payload["staleDays"] ?? payload["stale_days"], default: defaultDeskStaleDays))
        let deskItems: [DeskItem]
        if let deskItemsProvider {
            deskItems = await deskItemsProvider(dataRoot)
        } else {
            deskItems = (try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items) ?? []
        }

        let surfacedIDs = alreadySurfacedOpportunityIDs(inboxRows)
        var live = liveOpportunities(
            inboxRows: inboxRows,
            schedulerRaw: schedulerRaw,
            approvalsRaw: approvalsRaw,
            dataRoot: dataRoot
        )
        live.append(contentsOf: deskOpportunities(
            items: deskItems,
            staleDays: deskStaleDays,
            now: now,
            dataRoot: dataRoot
        ))
        let eligible = latestByID(live)
            .filter(isEligible)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.title < rhs.title
            }
        let skipped = eligible.filter { surfacedIDs.contains($0.id) }.count
        let surfaced = eligible
            .filter { !surfacedIDs.contains($0.id) }
            .prefix(limit)
            .prefix(surfaceLimit)

        return Result(
            scannedCount: live.count,
            eligibleCount: eligible.count,
            skippedAlreadySurfacedCount: skipped,
            surfaced: Array(surfaced)
        )
    }

    private static func liveOpportunities(
        inboxRows: [JSONValue],
        schedulerRaw: JSONValue,
        approvalsRaw: JSONValue,
        dataRoot: URL
    ) -> [Opportunity] {
        var opportunities: [Opportunity] = []

        let actionableInbox = inboxRows.filter { row in
            guard case .object(let obj) = row else { return false }
            return isAttentionWorthyInboxBacklogItem(obj)
        }
        if !actionableInbox.isEmpty {
            let id = stableID(kind: "inbox_digest", seed: "visible-unread-\(actionableInbox.count)")
            let memberIDs = actionableInbox.compactMap { row -> String? in
                guard case .object(let object) = row else { return nil }
                return nonEmptyString(object["id"])
            }
            let relatedGroups: [JSONValue] = memberIDs.isEmpty ? [] : [.object([
                "id": .string("digest-actionable-\(id)"),
                "title": .string("Actionable inbox items"),
                "count": .int(Int64(memberIDs.count)),
                "item_ids": .array(memberIDs.map(JSONValue.string)),
                "source": .string("proactive_inbox_digest"),
            ])]
            opportunities.append(Opportunity(
                id: id,
                kind: "inbox_digest",
                title: "Review inbox blockers",
                summary: "\(actionableInbox.count) actionable inbox item(s) are waiting for the user or assistant to handle.",
                detail: "Current scan found \(actionableInbox.count) unresolved attention-worthy inbox item(s), excluding routine receipts and prior proactive scan cards.",
                source: source(kind: "inbox_digest", id: id),
                severity: actionableInbox.count >= 3 ? "actionable" : "important",
                score: actionableInbox.count >= 3 ? 0.74 : 0.62,
                relatedPaths: [dataRoot.appendingPathComponent("notifications/inbox.jsonl").path],
                relatedGroups: relatedGroups
            ))
        }

        let schedulerIssues: [[String: JSONValue]]
        if case .array(let rows) = schedulerRaw {
            schedulerIssues = rows.compactMap { row in
                guard case .object(let obj) = row else { return nil }
                return isActionableSchedulerIssue(obj) ? obj : nil
            }
        } else {
            schedulerIssues = []
        }
        if !schedulerIssues.isEmpty {
            let names = schedulerIssues.prefix(3).compactMap { nonEmptyString($0["name"]) }
            let id = stableID(kind: "scheduler_health", seed: names.joined(separator: "|") + "|\(schedulerIssues.count)")
            opportunities.append(Opportunity(
                id: id,
                kind: "scheduler_health",
                title: "Review scheduler errors",
                summary: "\(schedulerIssues.count) scheduled job(s) have actionable error status.",
                detail: names.isEmpty
                    ? "Current scan found scheduler rows with actionable errors."
                    : "Current scan found scheduler rows with actionable errors: \(names.joined(separator: ", ")).",
                source: source(kind: "scheduler_health", id: id),
                severity: "important",
                score: 0.68,
                relatedPaths: [dataRoot.appendingPathComponent("scheduler/jobs.json").path]
            ))
        }

        let pendingApprovals: Int
        if case .array(let rows) = approvalsRaw {
            pendingApprovals = rows.filter { row in
                guard case .object(let obj) = row else { return false }
                let status = (nonEmptyString(obj["status"]) ?? "").lowercased()
                return ["pending", "open", "requested", "waiting"].contains(status)
            }.count
        } else {
            pendingApprovals = 0
        }
        if pendingApprovals > 0 {
            let id = stableID(kind: "approval_backlog", seed: "pending-\(pendingApprovals)")
            opportunities.append(Opportunity(
                id: id,
                kind: "approval_backlog",
                title: "Clear pending approvals",
                summary: "\(pendingApprovals) approval request(s) are waiting. The assistant should avoid duplicate asks and surface the oldest meaningful blocker.",
                detail: "Current scan found \(pendingApprovals) pending approval request(s).",
                source: source(kind: "approval_backlog", id: id),
                severity: "actionable",
                score: 0.72,
                relatedPaths: [dataRoot.appendingPathComponent("workflows/approvals/requests.json").path]
            ))
        }

        return opportunities
    }

    // MARK: - G5: the first non-self-referential producer

    /// A `now`/`next` Desk item that has not moved in `staleDays`.
    ///
    /// Every other kind this scan produces reads the app's own state files —
    /// inbox.jsonl, jobs.json, requests.json — and asks User to tidy the app
    /// that generated the card. This one reads his actual work and asks a
    /// question only he can answer: the item claims to be the current front of
    /// a project and nothing has happened to it for a week.
    ///
    /// Deliberately excluded: `deferUntil` items (parked ON PURPOSE — half of
    /// Agent's "stale" complaints were these), terminal items, and pursuits
    /// (agent-authored; asking User about the agent's own project is the exact
    /// self-referential shape G5 is trying to leave behind).
    static func deskOpportunities(
        items: [DeskItem],
        staleDays: Int,
        now: Date,
        dataRoot: URL
    ) -> [Opportunity] {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        return items.compactMap { item -> Opportunity? in
            guard deskOpportunityStatuses.contains(item.status), !item.status.isTerminal else { return nil }
            guard !item.isPursuit else { return nil }
            // A parked item is not stale. `deferUntil` is either `yyyy-MM-dd` or
            // a full ISO stamp; either way its presence means "not now, and
            // that is intentional".
            guard (item.deferUntil ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let updated = parseDeskInstant(item.updatedAt), updated < cutoff else { return nil }

            let project = item.project.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let label = project.isEmpty ? title : "\(project) · \(title)"
            let since = staleSinceLabel(updated, now: now)
            let days = max(staleDays, Int(now.timeIntervalSince(updated) / 86_400))

            // Seeded on the handle AND the updatedAt stamp: the moment the item
            // moves, the id changes, so a card for the OLD stall never
            // resurrects and a genuinely re-stalled item gets a fresh one.
            let id = stableID(kind: "desk_stale", seed: "\(item.handle)|\(item.updatedAt)")
            return Opportunity(
                id: id,
                kind: "desk_stale",
                title: label,
                summary: "\(label) hasn't moved since \(since) — still the right next thing?",
                detail: "This item is marked \(item.status.rawValue) and its last update was \(item.updatedAt) (\(days) day(s) ago). If it is still the next thing, it needs a step; if it is not, it should move off now/next.",
                source: source(kind: "desk_stale", id: id),
                severity: "important",
                score: 0.66,
                relatedPaths: [dataRoot.appendingPathComponent("desk").path]
            )
        }
    }

    /// Desk stamps are ISO-8601, sometimes with fractional seconds.
    static func parseDeskInstant(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }

    /// "Tuesday" while the weekday is still unambiguous, an explicit date once
    /// it is not. A card that says "hasn't moved since Tuesday" about something
    /// three weeks old would be a small lie.
    static func staleSinceLabel(_ updated: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        if now.timeIntervalSince(updated) < 7 * 86_400 {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "MMMM d"
        }
        return formatter.string(from: updated)
    }

    private static func isAttentionWorthyInboxBacklogItem(_ obj: [String: JSONValue]) -> Bool {
        let status = (nonEmptyString(obj["status"]) ?? "unread").lowercased()
        guard status == "unread" else { return false }

        let source = nonEmptyString(obj["source"]) ?? ""
        guard source != "scheduled_proactive_scan",
              !source.hasPrefix("proactive_autonomy:") else {
            return false
        }

        let severity = (nonEmptyString(obj["severity"]) ?? "info").lowercased()
        if ["actionable", "critical"].contains(severity) { return true }

        if nonEmptyString(obj["related_approval_id"]) != nil ||
            nonEmptyString(obj["related_mission_id"]) != nil {
            return true
        }

        return hasUsefulAction(obj["actions"])
    }

    private static func hasUsefulAction(_ raw: JSONValue?) -> Bool {
        guard case .array(let actions)? = raw else { return false }
        let passive = Set(["view", "read", "archive", "dismiss"])
        return actions.contains { value in
            guard case .object(let obj) = value,
                  let id = nonEmptyString(obj["id"])?.lowercased() else {
                return false
            }
            return !passive.contains(id)
        }
    }

    private static func isActionableSchedulerIssue(_ obj: [String: JSONValue]) -> Bool {
        guard SchedulerJobRuntime.bool(obj["enabled"], default: true) else { return false }
        let status = (nonEmptyString(obj["lastRunStatus"]) ?? "").lowercased()
        guard status == "error" else { return false }
        return true
    }

    private static func latestByID(_ opportunities: [Opportunity]) -> [Opportunity] {
        var order: [String] = []
        var latest: [String: Opportunity] = [:]
        for opportunity in opportunities {
            if latest[opportunity.id] == nil { order.append(opportunity.id) }
            latest[opportunity.id] = opportunity
        }
        return order.compactMap { latest[$0] }
    }

    private static func alreadySurfacedOpportunityIDs(_ rows: [JSONValue]) -> Set<String> {
        var ids = Set<String>()
        for row in rows {
            guard case .object(let obj) = row,
                  let source = nonEmptyString(obj["source"]),
                  source.hasPrefix("proactive_autonomy:") else {
                continue
            }
            let parts = source.split(separator: ":", omittingEmptySubsequences: false)
            if let id = parts.last, !id.isEmpty {
                ids.insert(String(id))
            }
        }
        return ids
    }

    private static func isEligible(_ opportunity: Opportunity) -> Bool {
        !opportunity.id.isEmpty
    }

    private static func source(kind: String, id: String) -> String {
        "proactive_autonomy:\(sourceComponent(kind)):\(sourceComponent(id))"
    }

    private static func sourceComponent(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
        return String((cleaned.isEmpty ? "unknown" : cleaned).prefix(120))
    }

    private static func inboxAction(id: String, label: String, description: String) -> JSONValue {
        .object([
            "id": .string(id),
            "label": .string(label),
            "description": .string(description),
        ])
    }

    private static func stableID(kind: String, seed: String) -> String {
        let digest = SHA256.hash(data: Data("\(kind):\(seed)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        return "opp-\(sourceComponent(kind))-\(digest)"
    }

    private static func int(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        switch raw {
        case .int(let value): return Int(value)
        case .double(let value): return Int(exactly: value.rounded(.towardZero)) ?? defaultValue
        case .string(let value): return Int(value) ?? defaultValue
        default: return defaultValue
        }
    }

    private static func nonEmptyString(_ raw: JSONValue?) -> String? {
        guard case .string(let value)? = raw else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
