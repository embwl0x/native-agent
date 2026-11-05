import NativeAgentShared
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import Desk
import TriggerScheduler
import NotificationInbox
import Experiences
import ApprovalInbox
// Blueprint: | `NativeAgentScheduledProactiveScan.swift` | Checked source opportunities; ProactiveScanArguments owns admission and execution |

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
        /// The record ids this digest stands on, without another inbox group store.
        public let relatedMatters: [String]

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
            relatedMatters: [String] = []
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
            self.relatedMatters = relatedMatters
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

    /// Five days gives active work about a working week before asking, avoiding progress-time nagging. Only now/next claim to be current work; watch/todo are
    /// intentionally backlog.
    static let deskOpportunityStatuses: Set<DeskStatus> = [.now, .next]

    public static func evaluate(
        dataRoot: URL,
        payload: [String: JSONValue],
        now: Date = Date()
    ) async throws -> Result {
        let arguments = try ProactiveScanArguments(payload)
        let limit = arguments.limit
        let surfaceLimit = arguments.surfaceLimit
        guard surfaceLimit > 0 else {
            return Result(scannedCount: 0, eligibleCount: 0, skippedAlreadySurfacedCount: 0, surfaced: [])
        }

        let inboxRows = try await ForPerson.at(dataRoot).inbox()
        let schedulerRows = try await SwiftNativeTriggerScheduler(root: dataRoot).listJobs()
        let schedulerIssues = try schedulerRows.compactMap { row -> ScheduledJob? in
            let job = try ScheduledJob(row: row)
            let status = try JSONRow(row).optionalString("lastRunStatus")
            return job.enabled && status == "error" ? job : nil
        }
        let pendingApprovals = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: .pending).count

        let deskStaleDays = arguments.staleDays
        let deskItems = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items

        let surfacedIDs = alreadySurfacedOpportunityIDs(inboxRows)
        var live = try liveOpportunities(
            inboxRows: inboxRows,
            schedulerIssues: schedulerIssues,
            pendingApprovals: pendingApprovals,
            dataRoot: dataRoot
        )
        live.append(contentsOf: deskOpportunities(
            items: deskItems,
            staleDays: deskStaleDays,
            now: now,
            dataRoot: dataRoot
        ))
        let eligible = latestByID(live)
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
        inboxRows: [InboxItemRecord],
        schedulerIssues: [ScheduledJob],
        pendingApprovals: Int,
        dataRoot: URL
    ) throws -> [Opportunity] {
        var opportunities: [Opportunity] = []

        let actionableInbox = inboxRows.filter(\.isAttentionWorthyBacklogItem)
        if !actionableInbox.isEmpty {
            let id = stableID(kind: "inbox_digest", seed: "visible-unread-\(actionableInbox.count)")
            let memberIDs = actionableInbox.map(\.id)
            opportunities.append(Opportunity(
                id: id,
                kind: "inbox_digest",
                title: "Review inbox blockers",
                summary: "\(actionableInbox.count) actionable inbox item(s) are waiting for the user or assistant to handle.",
                detail: """
                    Current scan found \(actionableInbox.count) unresolved attention-worthy inbox item(s), excluding routine receipts and prior \
                    proactive scan cards.
                    """,
                source: source(kind: "inbox_digest", id: id),
                severity: actionableInbox.count >= 3 ? "actionable" : "important",
                score: actionableInbox.count >= 3 ? 0.74 : 0.62,
                relatedPaths: [],
                relatedMatters: memberIDs
            ))
        }

        if !schedulerIssues.isEmpty {
            let names = schedulerIssues.prefix(3).map(\.name)
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

        if pendingApprovals > 0 {
            let id = stableID(kind: "approval_backlog", seed: "pending-\(pendingApprovals)")
            opportunities.append(Opportunity(
                id: id,
                kind: "approval_backlog",
                title: "Clear pending approvals",
                summary: """
                    \(pendingApprovals) approval request(s) are waiting. The assistant should avoid duplicate asks and surface the oldest \
                    meaningful blocker.
                    """,
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

    /// Ask about stalled current work, excluding intentionally parked items, terminal work and agent-authored pursuits.
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
            // A deferUntil stamp means the item is intentionally parked, regardless of its date format.
            guard (item.deferUntil ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let updated = parseDeskInstant(item.updatedAt), updated < cutoff else { return nil }

            let project = item.project.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let label = project.isEmpty ? title : "\(project) · \(title)"
            let since = staleSinceLabel(updated, now: now)
            let days = max(staleDays, Int(now.timeIntervalSince(updated) / 86_400))

            // Include updatedAt so movement retires a stall's identity and a later stall gets a fresh card.
            let id = stableID(kind: "desk_stale", seed: "\(item.handle)|\(item.updatedAt)")
            return Opportunity(
                id: id,
                kind: "desk_stale",
                title: label,
                summary: "\(label) hasn't moved since \(since) — still the right next thing?",
                detail: """
                    This item is marked \(item.status.rawValue) and its last update was \(item.updatedAt) (\(days) day(s) ago). If it is still \
                    the next thing, it needs a step; if it is not, it should move off now/next.
                    """,
                source: source(kind: "desk_stale", id: id),
                severity: "important",
                score: 0.66,
                relatedPaths: [dataRoot.appendingPathComponent("desk").path]
            )
        }
    }

    /// Desk stamps may include fractional seconds.
    static func parseDeskInstant(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return NativeTimestampFormat.parseISO8601FractionalFirst(trimmed)
    }

    /// Use weekdays only while unambiguous; older stalls need an explicit date.
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

    private static func latestByID(_ opportunities: [Opportunity]) -> [Opportunity] {
        var order: [String] = []
        var latest: [String: Opportunity] = [:]
        for opportunity in opportunities {
            if latest[opportunity.id] == nil { order.append(opportunity.id) }
            latest[opportunity.id] = opportunity
        }
        return order.compactMap { latest[$0] }
    }

    private static func alreadySurfacedOpportunityIDs(_ rows: [InboxItemRecord]) -> Set<String> {
        Set(rows.compactMap { row in
            guard row.source.hasPrefix("proactive_autonomy:") else { return nil }
            return row.source.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init)
        })
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

    private static func nonEmptyString(_ raw: JSONValue?) -> String? {
        guard case .string(let value)? = raw else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
