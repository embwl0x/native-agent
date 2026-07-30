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

    static func evaluate(
        dataRoot: URL,
        payload: [String: JSONValue],
        persistence: SwiftNativePersistenceCore = SwiftNativePersistenceCore()
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

        let opportunityRows = (try? await persistence.readJSONL(opportunitiesPath)) ?? []
        let inboxRows = (try? await persistence.readJSONL(inboxPath)) ?? []
        let schedulerRaw = await persistence.readJSON(schedulerPath, defaultValue: .array([]))
        let approvalsRaw = await persistence.readJSON(approvalsPath, defaultValue: .array([]))

        let surfacedIDs = alreadySurfacedOpportunityIDs(inboxRows)
        var opportunities = latestLedgerOpportunities(opportunityRows, opportunitiesPath: opportunitiesPath)
        let live = liveOpportunities(
            inboxRows: inboxRows,
            schedulerRaw: schedulerRaw,
            approvalsRaw: approvalsRaw,
            dataRoot: dataRoot
        )
        opportunities.append(contentsOf: live)
        opportunities = latestByID(opportunities)

        let eligible = opportunities
            .filter(isEligible)
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
