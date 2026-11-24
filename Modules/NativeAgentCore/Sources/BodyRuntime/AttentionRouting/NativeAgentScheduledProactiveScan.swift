import NativeAgentShared
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
import DeskCore
import MacNerves
// Blueprint: | `NativeAgentScheduledProactiveScan.swift` | Checked source opportunities; ProactiveScanArguments owns admission and execution |

public enum NativeAgentScheduledProactiveScan {
    public struct Opportunity: Sendable, Equatable {
        public let id: String
        public let title: String
        public let summary: String
        public let detail: String
        public let score: Double
    }

    // MARK: - W6/G5 — a project-shaped opportunity

    /// Five days gives active work about a working week before asking, avoiding progress-time nagging. Only now/next claim to be current work; watch/todo are
    /// intentionally backlog.
    static let deskOpportunityStatuses: Set<DeskStatus> = [.now, .next]

    public static func evaluate(
        dataRoot: URL,
        payload: [String: JSONValue],
        seen: [String],
        now: Date = Date()
    ) async throws -> [Opportunity] {
        let arguments = try ProactiveScanArguments(payload)
        let limit = arguments.limit
        let surfaceLimit = arguments.surfaceLimit
        guard surfaceLimit > 0 else {
            return []
        }

        let pendingApprovals = try await SwiftNativeApprovalInbox(root: dataRoot).list(filter: .pending).count

        let deskStaleDays = arguments.staleDays
        let deskItems = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items

        let surfacedIDs = Set(seen)
        var live = liveOpportunities(pendingApprovals: pendingApprovals)
        live.append(contentsOf: deskOpportunities(
            items: deskItems,
            staleDays: deskStaleDays,
            now: now
        ))
        let eligible = latestByID(live)
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.title < rhs.title
            }
        let surfaced = eligible
            .filter { !surfacedIDs.contains($0.id) }
            .prefix(limit)
            .prefix(surfaceLimit)

        return Array(surfaced)
    }

    private static func liveOpportunities(
        pendingApprovals: Int
    ) -> [Opportunity] {
        var opportunities: [Opportunity] = []

        if pendingApprovals > 0 {
            let id = stableID(kind: "approval_backlog", seed: "pending-\(pendingApprovals)")
            opportunities.append(Opportunity(
                id: id,
                title: "Clear pending approvals",
                summary: """
                    \(pendingApprovals) approval request(s) are waiting. The assistant should avoid duplicate asks and surface the oldest \
                    meaningful blocker.
                    """,
                detail: "Current scan found \(pendingApprovals) pending approval request(s).",
                score: 0.72
            ))
        }

        return opportunities
    }

    // MARK: - G5: the first non-self-referential producer

    /// Ask about stalled current work, excluding intentionally parked items, terminal work and agent-authored pursuits.
    static func deskOpportunities(
        items: [DeskItem],
        staleDays: Int,
        now: Date
    ) -> [Opportunity] {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        return items.compactMap { item -> Opportunity? in
            guard deskOpportunityStatuses.contains(item.status), !item.status.isTerminal else { return nil }
            guard !item.isPursuit else { return nil }
            guard !DeskSequencing.isDeferred(item, now: now) else { return nil }
            guard let updated = NativeTimestampFormat.parseTrimmedISO8601FractionalFirst(item.updatedAt), updated < cutoff else { return nil }

            let project = item.project.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let label = project.isEmpty ? title : "\(project) · \(title)"
            let since = staleSinceLabel(updated, now: now)
            let days = max(staleDays, Int(now.timeIntervalSince(updated) / 86_400))

            let id = stableID(kind: "desk_stale", seed: "\(item.handle)|\(item.updatedAt)")
            return Opportunity(
                id: id,
                title: label,
                summary: "\(label) hasn't moved since \(since) — still the right next thing?",
                detail: """
                    This item is marked \(item.status.rawValue) and its last update was \(item.updatedAt) (\(days) day(s) ago). If it is still \
                    the next thing, it needs a step; if it is not, it should move off now/next.
                    """,
                score: 0.66
            )
        }
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

    private static func sourceComponent(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
        return String((cleaned.isEmpty ? "unknown" : cleaned).prefix(120))
    }

    private static func stableID(kind: String, seed: String) -> String {
        let digest = SHA256.hash(data: Data("\(kind):\(seed)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
        return "opp-\(sourceComponent(kind))-\(digest)"
    }
}
