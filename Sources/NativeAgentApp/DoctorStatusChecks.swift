import Foundation
import Desk
import DoctorChecks
import NativeAgentShared
import PersistenceCore
import DeviceSync

@MainActor
enum DoctorStatusChecks {
    static func run(appModel: AppModel, repairDesk: Bool) async -> (checks: [CheckResult], repaired: Bool) {
        let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        let desk = await deskCheck(appModel: appModel, root: root, repair: repairDesk)
        let activity = await activityCheck(appModel: appModel, root: root)
        return ([desk.row, activity], desk.repaired)
    }

    private static func deskCheck(appModel: AppModel, root: URL, repair: Bool) async -> (row: CheckResult, repaired: Bool) {
        let store = SwiftNativeDeskStore(dataRoot: root)
        do {
            var items = try await store.liveState().items
            let initialContradictions = contradictoryParents(in: items)
            var repaired = false
            if repair && !initialContradictions.isEmpty {
                let ops = try await store.reconcileTerminalParentsWithNonTerminalDescendants()
                repaired = !ops.isEmpty
                items = try await store.liveState().items
            }
            let contradictions = contradictoryParents(in: items)
            let waiting = items.filter { $0.requiresOwnerInput }
            let blocked = items.filter { $0.status == .blocked && !$0.requiresOwnerInput }
            let requiredApprovals: Int
            do {
                requiredApprovals = LivingAttentionPolicy.requiredApprovalCount(
                    in: try await appModel.engine.approvals.list()
                )
            } catch {
                return (CheckResult(id: "status.desk_attention", title: "Desk work and decisions", status: "fail",
                                    detail: "Required approvals could not be read: \(NativeClient.safeDoctorDetail(error.localizedDescription)).",
                                    human_action: "Open Approvals and refresh its pending list; inspect the approval store before changing any saved request."), repaired)
            }
            let id = "status.desk_attention"
            let title = "Desk work and decisions"
            guard requiredApprovals > 0 || !waiting.isEmpty || !blocked.isEmpty || !contradictions.isEmpty else {
                return (CheckResult(id: id, title: title, status: "ok",
                                    detail: "No blocked Desk work, owner decision, or terminal-parent contradiction."), repaired)
            }
            var parts: [String] = []
            if !waiting.isEmpty { parts.append("\(waiting.count) item(s) wait on your decision: " + labels(waiting)) }
            if requiredApprovals > 0 { parts.append("\(requiredApprovals) required approval(s) wait for your decision.") }
            if !blocked.isEmpty { parts.append("\(blocked.count) blocked item(s): " + blockedDetails(blocked)) }
            if !contradictions.isEmpty { parts.append("\(contradictions.count) terminal parent(s) contain open descendants: " + labels(contradictions)) }
            var actions: [String] = []
            if !waiting.isEmpty { actions.append("Open Desk and decide items \(labels(waiting)) marked waiting on you.") }
            if requiredApprovals > 0 { actions.append("Open Approvals and decide the \(requiredApprovals) pending required request(s).") }
            if !blocked.isEmpty { actions.append("Open Desk and resolve \(labels(blocked)) using each recorded blocked reason or waiting party; if neither is recorded, clarify the block in Desk.") }
            if !contradictions.isEmpty { actions.append("Open Desk and inspect terminal parents \(labels(contradictions)) if Repair Safe Issues cannot reconcile them.") }
            let severity = contradictions.isEmpty && blocked.isEmpty ? "ok" : "warn"
            return (CheckResult(id: id, title: title, status: severity, detail: parts.joined(separator: " "),
                                repair: contradictions.isEmpty ? nil : "Run Repair Safe Issues to reconcile terminal Desk parents with open descendants.",
                                human_action: actions.joined(separator: " "), repair_available: !contradictions.isEmpty), repaired)
        } catch {
            return (CheckResult(id: "status.desk_attention", title: "Desk work and decisions", status: "fail",
                                detail: "Desk's canonical state could not be read: \(NativeClient.safeDoctorDetail(error.localizedDescription)).",
                                human_action: "Open Desk and inspect its unavailable-state detail; restore its canonical feed from a verified backup if the owner reports corruption."), false)
        }
    }

    private static func contradictoryParents(in items: [DeskItem]) -> [DeskItem] {
        let parents = Dictionary(items.map { ($0.handle, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var ancestorsOfOpenItems = Set<String>()
        for item in items where !item.status.isTerminal {
            var parent = item.parent
            var seen = Set<String>()
            while let handle = parent, seen.insert(handle).inserted {
                ancestorsOfOpenItems.insert(handle)
                parent = parents[handle] ?? nil
                if seen.count >= items.count { break }
            }
        }
        return items.filter { $0.status.isTerminal && ancestorsOfOpenItems.contains($0.handle) }
    }

    private static func labels(_ items: [DeskItem]) -> String {
        items.prefix(5).map { "#\($0.alias)" }.joined(separator: ", ")
            + (items.count > 5 ? " and \(items.count - 5) more" : "")
    }

    private static func blockedDetails(_ items: [DeskItem]) -> String {
        items.prefix(5).map { item in
            var details: [String] = []
            if let reason = item.blockedReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                details.append(NativeClient.safeDoctorDetail(reason))
            }
            if let waiting = item.waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines), !waiting.isEmpty {
                details.append("waiting on \(NativeClient.safeDoctorDetail(waiting))")
            }
            return "#\(item.alias): " + (details.isEmpty ? "no reason recorded" : details.joined(separator: "; "))
        }.joined(separator: "; ") + (items.count > 5 ? "; and \(items.count - 5) more" : "")
    }

    private static func activityCheck(appModel: AppModel, root: URL) async -> CheckResult {
        let id = "status.activity"
        let title = "Recent activity"
        do {
            let readout = try await appModel.client.getActivityReadout(root: root)
            let cutoff = Date().addingTimeInterval(-15 * 60)
            let formatter = ISO8601DateFormatter()
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Only a later success for the same identified subject resolves
            // an adverse receipt. Subjectless receipts remain independent.
            var succeededSubjects = Set<String>()
            var adverse: [ActivityEvent] = []
            for record in readout.records.suffix(40).reversed() {
                let severity = record.event.status.lowercased()
                if ["ok", "success", "succeeded"].contains(severity) {
                    if let subject = record.subject { succeededSubjects.insert(subject) }
                } else if (["fail", "failed", "error"].contains(severity) || record.needsReconciliation),
                          record.subject.map({ !succeededSubjects.contains($0) }) ?? true {
                    adverse.append(record.event)
                }
            }
            let current = adverse.filter { event in
                guard let date = fractionalFormatter.date(from: event.createdAt)
                    ?? formatter.date(from: event.createdAt) else { return false }
                return date >= cutoff && date <= Date().addingTimeInterval(60)
            }
            let malformed = readout.malformedRowCount
            let partial = malformed > 0
                ? "Activity log \(readout.records.isEmpty ? "unreadable" : "partially readable"): \(malformed) malformed row(s) in its bounded tail. "
                : ""
            let inspectLog = "Inspect activity/events.jsonl without replacing its bytes."
            guard !current.isEmpty else {
                if malformed > 0 {
                    return CheckResult(id: id, title: title, status: readout.records.isEmpty ? "fail" : "warn",
                                       detail: partial + (readout.records.isEmpty ? "" : "No current actionable failure or reconciliation receipt was found in its bounded tail."),
                                       human_action: "Open Status and refresh Recent activity once; if rows remain malformed, inspect activity/events.jsonl without replacing its bytes.")
                }
                return CheckResult(id: id, title: title, status: "ok",
                                   detail: "The activity log is readable; no current actionable failure or reconciliation receipt was found in its bounded tail.")
            }
            let owners = Set(current.map { owner(for: $0.kind) }).sorted()
            let latestTitles = current.sorted { $0.createdAt > $1.createdAt }.prefix(3)
                .map { NativeClient.safeDoctorDetail($0.title) }.joined(separator: "; ")
            return CheckResult(id: id, title: title, status: "warn",
                               detail: partial + "\(current.count) current adverse activity receipt(s), owner(s): \(owners.joined(separator: ", ")). Latest: \(latestTitles).",
                               human_action: "Open Activity and inspect the latest \(owners.joined(separator: ", ")) receipt; use its current owner state before taking action. Do not rerun the recorded action." + (malformed > 0 ? " " + inspectLog : ""))
        } catch {
            return CheckResult(id: id, title: title, status: "fail",
                               detail: "The activity log could not be read: \(NativeClient.safeDoctorDetail(error.localizedDescription)).",
                               human_action: "Open Status and refresh Recent activity once; if the log is still unavailable, inspect activity/events.jsonl without replacing its bytes.")
        }
    }

    private static func owner(for kind: String) -> String {
        let kind = kind.lowercased()
        if kind.contains("provider") || kind.contains("oauth") { return "Providers" }
        if kind.contains("desk") || kind.contains("workshop") { return "Desk" }
        if kind.contains("approval") { return "Approvals" }
        if kind.contains("dream") { return "Dreams" }
        if kind.contains("memory") { return "Memory" }
        if kind.contains("loop") || kind.contains("scheduler") { return "Background work" }
        if kind.contains("tool") { return "Tools" }
        return "Activity"
    }
}
