import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Studio
import TurnTrace
import MemoryV2
import AgentWorkspace
import ApprovalInbox
import Desk
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatSessionWork
import AgentConversations
import ChatToolParsing
import TrustCenter
import ToolRegistry
import DreamREMCycle
import WorkshopExecution
import Dispatcher
import Browser
import NotificationInbox
import AuthoredCapabilities
import Experiences
import MacIntegration
import ProviderRouting
import MacControl
import Transcripts
// Blueprint: | `ConnectorApprovalExecution.swift` | Connector approval replay and verified execution |
extension ApprovalExecution {
    @discardableResult
    public func reconcileUnappliedConnectorActionApprovals(
        dataRoot: URL,
        records: [ApprovalRecord]
    ) async -> Int {
        let client = self
        var executed = 0
        for record in records
        where record.action.hasPrefix("connector.action.") && record.executedAction == nil {
            _ = await client.applyResolvedConnectorAction(from: record, dataRoot: dataRoot)
            executed += 1
        }
        return executed
    }
    public struct ConnectorActionApprovalReplay: Sendable {
        public let actionID: String
        public let connectorID: String
        public let surface: String
        public let input: [String: JSONValue]
    }
    public static func connectorActionApprovalReplay(from record: ApprovalRecord) -> ConnectorActionApprovalReplay? {
        guard record.action.hasPrefix("connector.action."),
              case .object(let payload) = record.payload,
              payload["kind"] == .string("connector_action_v1"),
              case .string(let actionID)? = payload["actionId"],
              record.action == "connector.action.\(actionID)",
              case .string(let connectorID)? = payload["connectorId"],
              case .string(let surface)? = payload["surface"],
              surface == "connector_action",
              case .object(let input)? = payload["input"] else {
            return nil
        }
        return ConnectorActionApprovalReplay(
            actionID: actionID,
            connectorID: connectorID,
            surface: surface,
            input: input
        )
    }
    /// Execute the exact bounded connector input carried by the approval. The
    /// return value controls visible-card archival: an uncertain or refused
    /// effect stays visible instead of presenting an approved card as done.
    func applyResolvedConnectorAction(
        from record: ApprovalRecord,
        dataRoot: URL
    ) async -> Bool {
        let owners = ChatToolApprovalExecutionOwners.shared
        guard owners.acquire(root: dataRoot, approvalID: record.id) else { return false }
        var receiptOwnsRelease = false
        defer { if !receiptOwnsRelease { owners.release(root: dataRoot, approvalID: record.id) } }
        if let retained = owners.settlement(root: dataRoot, approvalID: record.id) {
            receiptOwnsRelease = true
            guard case .success = await settleApprovalExecution(record.id, dataRoot: dataRoot, settlement: retained) else { return false }
            return ChatToolOutcome.exactResultClass(retained.action) == .succeeded
        }
        guard record.status == "resolved", let decision = record.decision else { return false }
        guard decision == "approved" else {
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(record.action),
                    "status": .string(decision),
                ]),
                detail: "Connector action \(decision); no connector call ran."
            )
            return true
        }
        guard let replay = Self.connectorActionApprovalReplay(from: record),
              let descriptor = connectorActionDescriptors().first(where: {
                  $0.id == replay.actionID && $0.connectorId == replay.connectorID
              }) else {
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(record.action),
                    "status": .string("failed"),
                    "error": .string("approval has no valid bounded replay payload or registered executor"),
                ]),
                detail: "FAILED: connector approval has no valid bounded replay payload or registered executor; no connector call ran."
            )
            return false
        }
        let inbox = SwiftNativeApprovalInbox(root: dataRoot)
        switch await inbox.consumeApprovedEffect(
            id: record.id,
            digest: ApprovalInboxApprovedReplayVerifier.effectDigest(record.payload),
            action: replay.actionID,
            surface: replay.surface
        ) {
        case .spent:
            break
        case .alreadySpent:
            if (try? await inbox.get(record.id).executedAction) == nil {
                try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                    record.id,
                    executedAction: .object([
                        "op": .string("connector_action_replay"),
                        "action": .string(replay.actionID),
                        "status": .string("outcome_unknown"),
                        "error": .string("execution already started; automatic replay refused"),
                    ]),
                    detail: "Connector action may have started before interruption; it was not replayed automatically."
                )
            }
            return false
        case .unavailable:
            try? await SwiftNativeApprovalInbox(root: dataRoot).annotateExecution(
                record.id,
                executedAction: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(replay.actionID),
                    "status": .string("blocked"),
                    "error": .string("durable execution fence unavailable"),
                ]),
                detail: "Connector action was blocked before execution because its durable replay fence was unavailable."
            )
            return false
        }
        let settlement: ChatToolApprovalExecutionOwners.Settlement
        let succeeded: Bool
        do {
            let receipt = try await effects.runConnectorAction(
                descriptor: descriptor,
                dryRun: false,
                input: replay.input,
                approvedReplayApprovalID: record.id,
                dataRoot: dataRoot
            )
            settlement = .init(action: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(replay.actionID),
                    "status": .string(receipt.status),
                    "receiptId": .string(receipt.id),
                ]),
                detail: "Connector action \(replay.actionID) finished after approval with status \(receipt.status)."
            )
            succeeded = ChatToolOutcome.exactResultClass(.object(["status": .string(receipt.status)])) == .succeeded
        } catch {
            settlement = .init(action: .object([
                    "op": .string("connector_action_replay"),
                    "action": .string(replay.actionID),
                    "status": .string("outcome_unknown"),
                    "error": .string(String(describing: error)),
                ]),
                detail: "Connector action did not produce a verified receipt after approval; outcome is unknown and it was not retried."
            )
            succeeded = false
        }
        receiptOwnsRelease = true
        guard case .success = await settleApprovalExecution(record.id, dataRoot: dataRoot, settlement: settlement) else { return false }
        return succeeded
    }
}
