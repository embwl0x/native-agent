import Foundation
import NativeAgentShared
import NativeAgentCore
import BackgroundLoops
import DoctorChecks
import PersistenceCore
import Desk
import ApprovalInbox
import WorkshopExecution
import AgentWorkspace
import NotificationInbox
import Privacy
import Cognition
// Blueprint: | `HeartbeatDurableResidue.swift` | HeartbeatBackgroundWork durable-residue summary and idempotent review-card reconciliation |
extension HeartbeatBackgroundWork {
    public struct DurableResidueSummary: Sendable, Equatable {
        let staleWorkflowRunCount: Int
        let staleWorkflowRunIDs: [String]
        let preservedCodexReplyCount: Int?
        var codexReplyCountText: String { preservedCodexReplyCount.map(String.init) ?? "unavailable" }
        let terminalBridgeMessageCount: Int
        let terminalBridgeMessages: [String]
        let staleBridgeMessageCount: Int
        let staleBridgeMessages: [String]
        let veryOldDeskItemCount: Int
        let veryOldDeskItems: [String]
        let membershipDigest: String

        var isEmpty: Bool {
            staleWorkflowRunCount == 0
                && preservedCodexReplyCount == 0
                && terminalBridgeMessageCount == 0
                && staleBridgeMessageCount == 0
                && veryOldDeskItemCount == 0
        }
        var signature: String {
            [
                String(staleWorkflowRunCount),
                codexReplyCountText,
                String(terminalBridgeMessageCount),
                String(staleBridgeMessageCount),
                String(veryOldDeskItemCount),
                membershipDigest,
            ].joined(separator: "|")
        }
        var signalLine: String {
            "Durable review residue: \(staleWorkflowRunCount) old non-terminal workflow run(s), "
                + "saved replies to Codex owed or sent unconfirmed: \(codexReplyCountText), "
                + "\(terminalBridgeMessageCount) terminal bridge delivery failure(s), "
                + "\(staleBridgeMessageCount) bridge message(s) unconsumed over 24h, "
                + "\(veryOldDeskItemCount) open Desk item(s) older than 30d."
        }
    }
    public func heartbeatDurableResidueSummary(
        dataRoot: URL,
        bridgeConfigRoot: URL? = nil,
        now: Date = Date(),
        deadline: (Date) -> Void = { _ in }
    ) async -> DurableResidueSummary {
        let workflowCutoff = now.addingTimeInterval(-heartbeatWorkflowStaleAge)
        let workflowDir = dataRoot
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("run_state", isDirectory: true)
        let activeWorkflowStatuses: Set<String> = [
            "queued", "ready", "running", "waiting_approval", "awaiting_approval",
            "blocked", "recovery_required",
        ]
        var workflowIDs: [String] = []
        if let files = try? FileManager.default.contentsOfDirectory(
            at: workflowDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension.lowercased() == "json" {
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let status = (object["status"] as? String)?.lowercased(),
                      activeWorkflowStatuses.contains(status),
                      let rawStamp = object["updatedAt"] as? String
                        ?? object["updated_at"] as? String
                        ?? object["createdAt"] as? String
                        ?? object["created_at"] as? String,
                      let stamp = NativeTimestampFormat.parseISO8601(rawStamp) else { continue }
                deadline(stamp.addingTimeInterval(heartbeatWorkflowStaleAge + 0.001))
                guard stamp < workflowCutoff else { continue }
                workflowIDs.append((object["id"] as? String) ?? file.deletingPathExtension().lastPathComponent)
            }
        }
        // Scoped to THIS install: only the owner of the machine-wide rendezvous
        // reads `~/.config`, so a fresh root does not report another install's
        // undelivered replies as its own residue.
        let configRoot = bridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let replyRead = DelegationStatusProjector(configRoot: configRoot, dataRoot: dataRoot).allJobsWithAvailability(now: now)
        let preservedReplies = replyRead.jobs.filter { $0.agent == "codex" && $0.replyOwed }

        // The Codex inbox is the durable authority for work NativeAgent tried
        // to hand to Codex. A terminal delivery or an old row with no consume
        // receipt must reach the same bounded review surface as undelivered
        // replies; otherwise the sender and the agent UI disagree about whether
        // delegated work actually crossed the bridge. Historical reply receipts
        // remain compatibility proof for rows written before consumedAt/readAt.
        let codexBridge = configRoot
            .appendingPathComponent("codex-nativeagent-bridge", isDirectory: true)
        let deliveredMessageIDs: Set<String> = {
            let path = codexBridge.appendingPathComponent("reply-deliveries.jsonl")
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
            var ids = Set<String>()
            for line in text.split(whereSeparator: \Character.isNewline) {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messageIDs = object["messageIds"] as? [String] else { continue }
                ids.formUnion(messageIDs)
            }
            return ids
        }()
        let bridgeCutoff = now.addingTimeInterval(-heartbeatClaimStaleAge)
        let acknowledgedBefore = heartbeatBridgeAcknowledgmentHorizon(dataRoot: dataRoot)
        var terminalBridgeMessages: [String] = []
        var staleBridgeMessages: [String] = []
        let codexInbox = codexBridge.appendingPathComponent("codex-inbox.jsonl")
        if let text = try? String(contentsOf: codexInbox, encoding: .utf8) {
            for line in text.split(whereSeparator: \Character.isNewline) {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let id = (object["messageId"] as? String) ?? (object["id"] as? String) ?? "unknown"
                let topic = (object["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (topic?.isEmpty == false ? topic! : id)
                let read = (object["read"] as? Bool) == true
                let consumed = read
                    || !((object["consumedAt"] as? String) ?? "").isEmpty
                    || !((object["readAt"] as? String) ?? "").isEmpty
                let delivery = ((object["deliveryStatus"] as? String) ?? "").lowercased()
                if !read, delivery == "dead_letter" {
                    let reason = (object["deliveryFailureReason"] as? String) ?? "terminal failure"
                    terminalBridgeMessages.append("\(label) (\(reason))")
                    continue
                }
                guard !consumed,
                      !deliveredMessageIDs.contains(id),
                      let created = NativeTimestampFormat.parseISO8601(
                        (object["createdAt"] as? String) ?? (object["created_at"] as? String) ?? ""
                      ),
                      acknowledgedBefore.map({ created >= $0 }) ?? true else { continue }
                deadline(created.addingTimeInterval(heartbeatClaimStaleAge + 0.001))
                guard created < bridgeCutoff else { continue }
                staleBridgeMessages.append(label)
            }
        }
        let deskCutoff = now.addingTimeInterval(-heartbeatDeskStaleAge)
        let deskItems = (try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items) ?? []
        let veryOldDeskItems = deskItems.compactMap { item -> String? in
            guard !item.status.isTerminal,
                  let stamp = NativeTimestampFormat.parseISO8601(item.updatedAt) else { return nil }
            deadline(stamp.addingTimeInterval(heartbeatDeskStaleAge + 0.001))
            guard stamp < deskCutoff else { return nil }
            return "\(item.alias): \(item.title)"
        }
        let sortedWorkflowIDs = workflowIDs.sorted()
        let sortedDeskItems = veryOldDeskItems.sorted()
        let membership = [
            sortedWorkflowIDs.joined(separator: "\n"),
            preservedReplies.map(\.id).sorted().joined(separator: "\n"),
            terminalBridgeMessages.sorted().joined(separator: "\n"),
            staleBridgeMessages.sorted().joined(separator: "\n"),
            sortedDeskItems.joined(separator: "\n"),
        ].joined(separator: "\n---\n")
        return DurableResidueSummary(
            staleWorkflowRunCount: sortedWorkflowIDs.count,
            staleWorkflowRunIDs: Array(sortedWorkflowIDs.prefix(8)),
            preservedCodexReplyCount: replyRead.allStoresReadable ? preservedReplies.count : nil,
            terminalBridgeMessageCount: terminalBridgeMessages.count,
            terminalBridgeMessages: Array(terminalBridgeMessages.sorted().prefix(8)),
            staleBridgeMessageCount: staleBridgeMessages.count,
            staleBridgeMessages: Array(staleBridgeMessages.sorted().prefix(8)),
            veryOldDeskItemCount: sortedDeskItems.count,
            veryOldDeskItems: Array(sortedDeskItems.prefix(8)),
            membershipDigest: heartbeatStableDigest(membership)
        )
    }
    /// Maintains one sticky informational review card. An unchanged summary
    /// preserves read/archive state; a changed summary resurfaces the same id.
    /// Clearing every category archives the card. No underlying workflow,
    /// bridge reply, or Desk row is changed here.
    public func reconcileDurableResidueCard(
        dataRoot: URL,
        summary: DurableResidueSummary,
        now: Date = Date()
    ) async {
        let cardID = "system-health:durable-residue-review"
        let inbox = LiveNotificationInbox.live(dataRoot: dataRoot)
        do {
            let rows = try await inbox.rows()
            let existing = rows.first { row in
                guard case .object(let object) = row,
                      case .string(let id)? = object["id"] else { return false }
                return id == cardID
            }
            if summary.isEmpty {
                if existing != nil {
                    _ = try await inbox.updateStatus(
                        id: cardID,
                        status: "archived",
                        readAt: NativeTimestampFormat.fractionalZulu(now)
                    )
                }
                return
            }
            if case .object(let object)? = existing,
               case .string(let oldSignature)? = object["residue_signature"],
               oldSignature == summary.signature {
                return
            }
            var detail: [String] = [
                "Review snapshot at \(NativeTimestampFormat.fractionalZulu(now)). Current reply outcomes are on Delegations and Desk. NativeAgent did not replay, resume, archive, or delete any underlying state.",
                "Old non-terminal workflow runs: \(summary.staleWorkflowRunCount).",
                "Saved replies to Codex owed or sent unconfirmed: \(summary.codexReplyCountText).",
                "Terminal Codex bridge deliveries: \(summary.terminalBridgeMessageCount). These briefs remain retained and are never treated as consumed.",
                "Codex bridge messages unconsumed over 24h: \(summary.staleBridgeMessageCount). Historical reply receipts count as compatibility proof.",
                "Open Desk items older than 30 days: \(summary.veryOldDeskItemCount).",
            ]
            if !summary.staleWorkflowRunIDs.isEmpty {
                detail.append("Workflow ids: " + summary.staleWorkflowRunIDs.prefix(8).joined(separator: ", "))
            }
            if !summary.veryOldDeskItems.isEmpty {
                detail.append("Old Desk items: " + summary.veryOldDeskItems.prefix(8).joined(separator: "; "))
            }
            if !summary.terminalBridgeMessages.isEmpty {
                detail.append("Terminal bridge messages: " + summary.terminalBridgeMessages.prefix(8).joined(separator: "; "))
            }
            if !summary.staleBridgeMessages.isEmpty {
                detail.append("Unconsumed bridge messages: " + summary.staleBridgeMessages.prefix(8).joined(separator: "; "))
            }
            let timestamp = NativeTimestampFormat.fractionalZulu(now)
            let card: JSONValue = .object([
                "id": .string(cardID),
                "created_at": .string(timestamp),
                "source": .string("system_health"),
                "severity": .string("info"),
                "title": .string("Durable items ready for occasional review"),
                "summary": .string(summary.signalLine),
                "detail": .string(detail.joined(separator: "\n")),
                "residue_signature": .string(summary.signature),
                "related_mission_id": .null,
                "related_approval_id": .null,
                "related_paths": .array([]),
                "related_groups": .array([]),
                "actions": .array([]),
                "status": .string("unread"),
                "read_at": .null,
            ])
            _ = try await inbox.upsert(card, id: cardID)
        } catch {
            FileHandle.standardError.write(Data(
                "HeartbeatLoop: durable residue review projection failed: \(error)\n".utf8
            ))
        }
    }
    private func heartbeatStableDigest(_ value: String) -> String {
        String(fnv1a64(value), radix: 16)
    }
    /// Versioned triage receipts keep an already-reviewed historical failure
    /// era from reappearing as current bridge residue. This is the same
    /// `bridge.undelivered` authority used by the read-only system instrument:
    /// it suppresses only rows older than the exact horizon, never newer work
    /// and never terminal dead letters (which remain separately visible).
    private func heartbeatBridgeAcknowledgmentHorizon(dataRoot: URL) -> Date? {
        let path = dataRoot.deletingLastPathComponent()
            .appendingPathComponent("docs/eval_acknowledgments.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acknowledgments = root["acknowledgments"] as? [[String: Any]],
              let entry = acknowledgments.first(where: {
                ($0["detector"] as? String) == "bridge.undelivered"
              }),
              let horizon = entry["horizon"] as? String else { return nil }
        return NativeTimestampFormat.parseISO8601(horizon)
    }
}
