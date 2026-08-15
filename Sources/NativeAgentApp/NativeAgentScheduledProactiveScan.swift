import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import TriggerScheduler

enum NativeAgentScheduledProactiveScan {
    struct Opportunity: Sendable, Equatable {
        let id: String
        let kind: String
        let title: String
        let summary: String
        let detail: String
        let source: String
        let severity: String
        let score: Double
        let relatedPaths: [String]
    }

    struct Result: Sendable, Equatable {
        let scannedCount: Int
        let eligibleCount: Int
        let skippedAlreadySurfacedCount: Int
        let surfaced: [Opportunity]
    }

    static func inboxActions(for opportunity: Opportunity) -> [JSONValue] {
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

    // MARK: - W6/G9 — reading the outcome ledger

    /// Times a kind must be dismissed inside the window before the scan stops
    /// surfacing it.
    static let outcomeSuppressionThreshold = 3
    static let outcomeWindowDays = 30
    /// Applied to a kind with dismissals below the drop threshold. Enough to
    /// lose a tie against a kind User has never rejected, not enough to bury a
    /// genuinely urgent card.
    static let outcomeScorePenalty = 0.15

    static func evaluate(
        dataRoot: URL,
        payload: [String: JSONValue],
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore(),
        now: Date = Date(),
        deskItemsProvider: (@Sendable (URL) async -> [DeskItem])? = nil
    ) async -> Result {
        let limit = max(1, min(int(payload["limit"], default: 10), 50))
        let surfaceLimit = max(0, min(int(payload["surfaceLimit"] ?? payload["surface_limit"], default: 4), 12))
        guard surfaceLimit > 0 else {
            return Result(scannedCount: 0, eligibleCount: 0, skippedAlreadySurfacedCount: 0, surfaced: [])
        }

        let opportunitiesPath = dataRoot
            .appendingPathComponent("nextgen", isDirectory: true)
            .appendingPathComponent("proactive", isDirectory: true)
            .appendingPathComponent("opportunities.jsonl")
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

        let outcomesPath = dataRoot
            .appendingPathComponent("nextgen", isDirectory: true)
            .appendingPathComponent("proactive", isDirectory: true)
            .appendingPathComponent("outcomes.jsonl")

        let opportunityRows = (try? await persistence.readJSONL(opportunitiesPath)) ?? []
        let inboxRows = (try? await persistence.readJSONL(inboxPath)) ?? []
        let schedulerRaw = await persistence.readJSON(schedulerPath, defaultValue: .array([]))
        let approvalsRaw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))
        // G9: the ledger has been write-only since the learning loop that read
        // it went down with the daemon. This is the one reader.
        let outcomeRows = (try? await persistence.readJSONL(outcomesPath)) ?? []
        let feedback = outcomeFeedback(rows: outcomeRows, now: now)

        let deskStaleDays = max(1, int(payload["staleDays"] ?? payload["stale_days"], default: defaultDeskStaleDays))
        let deskItems: [DeskItem]
        if let deskItemsProvider {
            deskItems = await deskItemsProvider(dataRoot)
        } else {
            deskItems = (try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items) ?? []
        }

        let surfacedIDs = alreadySurfacedOpportunityIDs(inboxRows)
        var opportunities = latestLedgerOpportunities(opportunityRows, opportunitiesPath: opportunitiesPath)
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
        opportunities.append(contentsOf: live)
        opportunities = latestByID(opportunities)

        let eligible = opportunities
            .filter { isEligible($0) && !feedback.dropped.contains($0.kind.lowercased()) }
            .map { feedback.applyingPenalty(to: $0) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.title < rhs.title
            }
            .prefix(limit)
        let skipped = eligible.filter { surfacedIDs.contains($0.id) }.count
        let surfaced = eligible
            .filter { !surfacedIDs.contains($0.id) }
            .prefix(surfaceLimit)

        return Result(
            scannedCount: opportunityRows.count + live.count,
            eligibleCount: eligible.count,
            skippedAlreadySurfacedCount: skipped,
            surfaced: Array(surfaced)
        )
    }

    private static func latestLedgerOpportunities(_ rows: [JSONValue], opportunitiesPath: URL) -> [Opportunity] {
        latestByID(rows.compactMap { row in
            guard case .object(let obj) = row,
                  let id = nonEmptyString(obj["id"]),
                  let title = nonEmptyString(obj["title"]) else {
                return nil
            }
            let kind = nonEmptyString(obj["kind"]) ?? "proactive_idea"
            let summary = nonEmptyString(obj["summary"]) ?? "The assistant found a proactive opportunity."
            let score = double(obj["score"])
            let status = (nonEmptyString(obj["status"]) ?? "scored").lowercased()
            let decision = (nonEmptyString(obj["decision"]) ?? status).lowercased()
            let surfaceSuppressed: Bool = {
                guard case .object(let feedback)? = obj["feedback"] else { return false }
                return bool(feedback["surfaceSuppressed"] ?? feedback["surface_suppressed"])
            }()
            let shouldSurface = !surfaceSuppressed
                && decision != "shadow"
                && status != "shadow"
                && (["notify", "act"].contains(decision) || ["notify", "act"].contains(status) || score >= 0.55)
            guard shouldSurface else { return nil }
            let suggestedAction = nonEmptyString(obj["suggestedAction"]) ?? nonEmptyString(obj["suggested_action"])
            let whyNow = nonEmptyString(obj["whyNow"]) ?? nonEmptyString(obj["why_now"])
            let readouts = readoutStrings(obj["lazyContext"])
            var detailLines: [String] = [
                "Score: \(scoreString(score)). Decision: \(decision)."
            ]
            if let suggestedAction { detailLines.append("Suggested action: \(suggestedAction).") }
            if let whyNow { detailLines.append("Why now: \(whyNow)") }
            if !readouts.isEmpty { detailLines.append("Readouts: \(readouts.prefix(5).joined(separator: ", "))") }
            return Opportunity(
                id: id,
                kind: kind,
                title: title,
                summary: summary,
                detail: detailLines.joined(separator: "\n\n"),
                source: source(kind: kind, id: id),
                severity: severity(score: score, decision: decision),
                score: score,
                relatedPaths: [opportunitiesPath.path]
            )
        })
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
            opportunities.append(Opportunity(
                id: id,
                kind: "inbox_digest",
                title: "Review inbox blockers",
                summary: "\(actionableInbox.count) actionable inbox item(s) are waiting for the user or assistant to handle.",
                detail: "Current scan found \(actionableInbox.count) unresolved attention-worthy inbox item(s), excluding routine receipts and prior proactive scan cards.",
                source: source(kind: "inbox_digest", id: id),
                severity: actionableInbox.count >= 3 ? "actionable" : "important",
                score: actionableInbox.count >= 3 ? 0.74 : 0.62,
                relatedPaths: [dataRoot.appendingPathComponent("notifications/inbox.jsonl").path]
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
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: trimmed) { return parsed }
        return ISO8601DateFormatter().date(from: trimmed)
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

    // MARK: - G9: the outcome-ledger reader

    /// What the ledger tail says about each kind. Pure over the rows — no
    /// store, no loop, one predicate applied at the eligibility filter.
    struct OutcomeFeedback: Sendable, Equatable {
        /// Kinds dismissed at or past the threshold inside the window. Dropped
        /// outright: User has said no three times, the scan stops asking.
        var dropped: Set<String> = []
        /// Kinds with SOME dismissals but below the threshold — scored down so
        /// they lose ties, not silenced.
        var penalized: Set<String> = []

        func applyingPenalty(to opportunity: Opportunity) -> Opportunity {
            guard penalized.contains(opportunity.kind.lowercased()) else { return opportunity }
            return Opportunity(
                id: opportunity.id,
                kind: opportunity.kind,
                title: opportunity.title,
                summary: opportunity.summary,
                detail: opportunity.detail,
                source: opportunity.source,
                severity: opportunity.severity,
                score: max(0, opportunity.score - NativeAgentScheduledProactiveScan.outcomeScorePenalty),
                relatedPaths: opportunity.relatedPaths
            )
        }
    }

    static func outcomeFeedback(rows: [JSONValue], now: Date) -> OutcomeFeedback {
        let cutoff = now.addingTimeInterval(-Double(outcomeWindowDays) * 86_400)
        var dismissalsByKind: [String: Int] = [:]
        for row in rows {
            guard case .object(let obj) = row,
                  let kind = nonEmptyString(obj["kind"])?.lowercased() else { continue }
            // `useful == false` is precisely the dismiss write
            // (ProactiveOutcomeLedger: archive => true, dismiss => false).
            // A null `useful` is an observation, not a judgement — it must not
            // count against the kind.
            guard case .bool(false)? = obj["useful"] else { continue }
            // A row with an unparseable stamp is counted: the alternative is
            // letting a malformed timestamp launder a dismissal out of the
            // window. Only rows PROVABLY older than 30 days are excluded.
            if let created = nonEmptyString(obj["createdAt"]),
               let stamp = parseDeskInstant(created),
               stamp < cutoff {
                continue
            }
            dismissalsByKind[kind, default: 0] += 1
        }
        var feedback = OutcomeFeedback()
        for (kind, count) in dismissalsByKind {
            if count >= outcomeSuppressionThreshold {
                feedback.dropped.insert(kind)
            } else {
                feedback.penalized.insert(kind)
            }
        }
        return feedback
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

    private static func severity(score: Double, decision: String) -> String {
        if decision == "act" || score >= 0.8 { return "actionable" }
        if score >= 0.55 { return "important" }
        return "info"
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

    private static func readoutStrings(_ raw: JSONValue?) -> [String] {
        guard case .object(let obj)? = raw,
              case .array(let values)? = obj["readouts"] else {
            return []
        }
        return values.compactMap { nonEmptyString($0) }
    }

    private static func int(_ raw: JSONValue?, default defaultValue: Int) -> Int {
        switch raw {
        case .int(let value): return Int(value)
        case .double(let value): return Int(value)
        case .string(let value): return Int(value) ?? defaultValue
        default: return defaultValue
        }
    }

    private static func double(_ raw: JSONValue?) -> Double {
        switch raw {
        case .double(let value): return value
        case .int(let value): return Double(value)
        case .string(let value): return Double(value) ?? 0
        default: return 0
        }
    }

    private static func bool(_ raw: JSONValue?) -> Bool {
        switch raw {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value):
            return ["1", "true", "yes", "y"].contains(value.lowercased())
        default:
            return false
        }
    }

    private static func nonEmptyString(_ raw: JSONValue?) -> String? {
        guard case .string(let value)? = raw else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func scoreString(_ score: Double) -> String {
        String(format: "%.3f", score)
    }
}
