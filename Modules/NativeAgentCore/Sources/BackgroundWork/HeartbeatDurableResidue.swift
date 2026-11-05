import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import AgentWorkspace
import Experiences
import Privacy
import Cognition
// Blueprint: | `HeartbeatDurableResidue.swift` | Durable residue tells an inbox-only episode; incomplete inventory never clears it |
extension HeartbeatBackgroundWork {
    public struct DurableResidueSummary: Sendable, Equatable {
        let staleWorkflowRunCount: Int?
        let staleWorkflowRunIDs: [String]
        let veryOldDeskItemCount: Int?
        let veryOldDeskItems: [String]
        let membershipDigest: String
        let unavailable: [String]
        var workflowCountText: String { staleWorkflowRunCount.map(String.init) ?? "unavailable" }
        var deskCountText: String { veryOldDeskItemCount.map(String.init) ?? "unavailable" }

        var isEmpty: Bool {
            unavailable.isEmpty && staleWorkflowRunCount == 0 && veryOldDeskItemCount == 0
        }
        var signature: String {
            [
                workflowCountText,
                deskCountText,
                membershipDigest,
                unavailable.joined(separator: "; "),
            ].joined(separator: "|")
        }
        var signalLine: String {
            "Durable review residue: \(workflowCountText) old non-terminal workflow run(s), "
                + "\(deskCountText) open Desk item(s) older than 30d."
        }
    }
    public func heartbeatDurableResidueSummary(
        dataRoot: URL,
        now: Date = Date(),
        deadline: (Date) -> Void = { _ in }
    ) async -> DurableResidueSummary {
        var unavailable: [String] = []
        let workflowCutoff = now.addingTimeInterval(-heartbeatWorkflowStaleAge)
        let workflowDir = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("run_state", isDirectory: true)
        let activeWorkflowStatuses: Set<String> = [
            "queued", "ready", "running", "waiting_approval", "awaiting_approval",
            "blocked", "recovery_required",
        ]
        var workflowIDs: [String] = []
        var workflowsReadable = true
        do {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(
            at: workflowDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
            ) } catch CocoaError.fileReadNoSuchFile { files = [] }
            for file in files where file.pathExtension.lowercased() == "json" {
                let data = try Data(contentsOf: file)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = (object["status"] as? String)?.lowercased() else {
                    throw PersistenceCoreError.ioFailure("Workflow status unavailable at \(file.path)")
                }
                guard activeWorkflowStatuses.contains(status) else { continue }
                guard let rawStamp = object["updatedAt"] as? String
                        ?? object["updated_at"] as? String
                        ?? object["createdAt"] as? String
                        ?? object["created_at"] as? String,
                      let stamp = NativeTimestampFormat.parseISO8601(rawStamp) else {
                    throw PersistenceCoreError.ioFailure("Workflow timestamp unavailable at \(file.path)")
                }
                deadline(stamp.addingTimeInterval(heartbeatWorkflowStaleAge + 0.001))
                guard stamp < workflowCutoff else { continue }
                workflowIDs.append((object["id"] as? String) ?? file.deletingPathExtension().lastPathComponent)
            }
        } catch {
            workflowsReadable = false
            unavailable.append("Workflow residue: \(error.localizedDescription)")
        }
        let deskCutoff = now.addingTimeInterval(-heartbeatDeskStaleAge)
        var deskReadable = true
        var veryOldDeskItems: [String] = []
        do {
        let deskItems = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items
        veryOldDeskItems = try deskItems.compactMap { item -> String? in
            guard !item.status.isTerminal else { return nil }
            guard let stamp = NativeTimestampFormat.parseISO8601(item.updatedAt) else {
                throw PersistenceCoreError.ioFailure("Desk item timestamp unavailable for \(item.handle)")
            }
            deadline(stamp.addingTimeInterval(heartbeatDeskStaleAge + 0.001))
            guard stamp < deskCutoff else { return nil }
            return "\(item.alias): \(item.title)"
        }
        } catch { deskReadable = false; unavailable.append("Desk residue: \(error.localizedDescription)") }
        let sortedWorkflowIDs = workflowIDs.sorted()
        let sortedDeskItems = veryOldDeskItems.sorted()
        let membership = [
            sortedWorkflowIDs.joined(separator: "\n"),
            sortedDeskItems.joined(separator: "\n"),
        ].joined(separator: "\n---\n")
        return DurableResidueSummary(
            staleWorkflowRunCount: workflowsReadable ? sortedWorkflowIDs.count : nil,
            staleWorkflowRunIDs: Array(sortedWorkflowIDs.prefix(8)),
            veryOldDeskItemCount: deskReadable ? sortedDeskItems.count : nil,
            veryOldDeskItems: Array(sortedDeskItems.prefix(8)),
            membershipDigest: heartbeatStableDigest(membership), unavailable: unavailable
        )
    }
    /// A changed inventory starts a new episode; only a complete empty inventory resolves it.
    public func reconcileDurableResidueCard(
        dataRoot: URL,
        summary: DurableResidueSummary,
        now: Date = Date()
    ) async {
        do {
            if summary.isEmpty {
                try await BodyNotice.resolve(key: "system-health:durable-residue-review", from: "system_health", dataRoot: dataRoot)
                return
            }
            var detail: [String] = [
                """
                    Review snapshot at \(NativeTimestampFormat.fractionalZulu(now)). Current reply outcomes are on Delegations and Desk. NativeAgent did not \
                    replay, resume, archive, or delete any underlying state.
                    """,
                "Old non-terminal workflow runs: \(summary.workflowCountText).",
                "Open Desk items older than 30 days: \(summary.deskCountText).",
            ]
            if !summary.unavailable.isEmpty {
                detail.append("""
                    Residue inventory is incomplete; no clear verdict is available. Repair these sources, then refresh:\u{20}
                    """ + summary.unavailable.joined(separator: "; "))
            }
            if !summary.staleWorkflowRunIDs.isEmpty {
                detail.append("Workflow ids: " + summary.staleWorkflowRunIDs.prefix(8).joined(separator: ", "))
            }
            if !summary.veryOldDeskItems.isEmpty {
                detail.append("Old Desk items: " + summary.veryOldDeskItems.prefix(8).joined(separator: "; "))
            }
            let words = detail.joined(separator: "\n")
            try await BodyNotice.tell(key: "system-health:durable-residue-review", from: "system_health",
                finding: summary.signature, dataRoot: dataRoot) { id in
                try await ForPerson.at(dataRoot).tell(Matter(id: id, form: .words, from: "system_health",
                    title: "Durable items ready for occasional review", summary: summary.signalLine,
                    words: words), doors: [])
            }
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: durable residue review projection failed: \(error)\n".utf8
            ))
        }
    }
    private func heartbeatStableDigest(_ value: String) -> String {
        String(fnv1a64(value), radix: 16)
    }
}
