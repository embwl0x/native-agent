import AuthoredCapabilities
import ChatToolParsing
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Surface identity is security-relevant and `ConversationSurfaceProfile` owns
// the remote/iOS sets. A second copy of them here would be a second answer to
// "is this surface the person" — the thing that type exists to prevent.
import TrustCenter
// Blueprint: | `ApprovalContinuations.swift` | Locked continuation and card claims |
extension SwiftNativeApprovalInbox {
    public func annotateChatContinuation(
        _ id: String, done: Bool, legacyStartedAt: String? = nil,
        clearQueuedDelivery: Bool = false, settlement: String? = nil,
        assistantDelivery: JSONValue? = nil
    ) async throws -> Bool {
        let now = Date()
        return try await updateChatContinuation(id) { record, state in
            if let assistantDelivery {
                guard state["done"] != .bool(true) else { return false }
                state["assistantDelivery"] = assistantDelivery
                return true
            }
            if done {
                guard state["done"] != .bool(true) else { return false }
                state["done"] = .bool(true)
                if let settlement { state["settlement"] = .string(settlement) }
                state["delivery"] = nil
                return true
            }
            guard Self.continuationIsPending(record, now: now),
                  state["done"] == nil, state["started"] == nil else { return false }
            state["started"] = .string(legacyStartedAt ?? Self.isoTimestamp(now))
            if clearQueuedDelivery { state["delivery"] = nil }
            return true
        } && (done || legacyStartedAt == nil)
    }
    /// A queued delivery remains owed across downtime; age only bounds records
    /// without that durable evidence. Started and completed claims never replay.
    public nonisolated static func continuationIsPending(_ record: ApprovalRecord, now: Date = Date()) -> Bool {
        guard record.status == "resolved", record.decision != nil,
              hasChatReportingObligation(record) else { return false }
        if let saved = record.chatContinuation {
            guard case .object(let state) = saved,
                  state["started"] == nil, state["done"] == nil else { return false }
            if case .object? = state["delivery"] { return true }
        }
        guard let date = record.resolvedAt.flatMap(NativeTimestampFormat.parseISO8601) else { return false }
        return (0...600).contains(now.timeIntervalSince(date))
    }
    /// Only a conversation that actually asked, or retained delivery work,
    /// owes a reporting turn. A mirrored card alone does not create one.
    nonisolated static func hasChatReportingObligation(_ record: ApprovalRecord) -> Bool {
        if case .object(let state)? = record.chatContinuation,
           state["started"] != nil || state["delivery"] != nil || state["assistantDelivery"] != nil { return true }
        guard case .object(let payload) = record.payload else { return false }
        let origin: [String: JSONValue] = if case .object(let value)? = payload["origin"] { value } else { [:] }
        let telegram: [String: JSONValue] = if case .object(let value)? = payload["telegram"] { value } else { [:] }
        func readSession(_ value: JSONValue?) -> String? {
            guard case .string(let id)? = value else { return nil }
            return NativeAgentChatSessionID.normalizedPathComponent(id)
        }
        guard let session = readSession(origin["sessionId"]) ?? readSession(telegram["sessionId"]) else { return false }
        if payload["surface"] == .string("connector_action"), session.hasPrefix("ephemeral:connector_action:") { return false }
        return payload["kind"] == .string("chat_tool_approval")
            || payload["kind"] == .string("telegram_tool_approval")
            || payload["kind"] == .string("agent_acp_live_approval")
            || !telegram.isEmpty
    }
    /// Retain the destination before delivery, then mark it delivered only
    /// after its idempotent transcript write. An unfinished claim resumes at
    /// the same destination; an old claim without delivery evidence does too.
    public func claimChatCard(
        _ id: String, card: JSONValue,
        deliver: @escaping @Sendable (ApprovalRecord) async throws -> Void
    ) async throws -> ApprovalRecord? {
        try await SwiftNativePersistenceCore.withFileLock(approvalsPath) { [approvalsPath] in
            var items = try Self.loadApprovalRowsChecked(at: approvalsPath)
            guard let index = items.firstIndex(where: {
                guard case .object(let object) = $0 else { return false }
                return object["id"] == .string(id)
            }), case .object(var object) = items[index],
                object["status"] == .string("pending") else { return nil }
            // A Telegram mark (`markChatCard`) may come first; the
            // destination joins it.
            var current: [String: JSONValue] = [:]
            if case .object(let saved)? = object["chatCard"] { current = saved }
            if current["sessionId"] == nil, case .object(let fresh) = card {
                object["chatCard"] = .object(current.merging(fresh) { kept, _ in kept })
                items[index] = .object(object)
                try await SwiftNativePersistenceCore.writeJSON(.array(items), to: approvalsPath)
            }
            guard case .object(var savedCard)? = object["chatCard"],
                  savedCard["delivered"] != .bool(true),
                  let claimed = ApprovalRecord(json: .object(object)) else { return nil }
            try await deliver(claimed)
            savedCard["delivered"] = .bool(true)
            object["chatCard"] = .object(savedCard)
            items[index] = .object(object)
            try await SwiftNativePersistenceCore.writeJSON(.array(items), to: approvalsPath)
            return ApprovalRecord(json: .object(object))
        }
    }
    /// Merge delivery receipts even if the approval was resolved while its
    /// Telegram send was in flight. A decision does not erase what was sent.
    public func markChatCard(_ id: String, _ fields: [String: JSONValue]) async throws {
        try await SwiftNativePersistenceCore.withFileLock(approvalsPath) { [approvalsPath] in
            var items = try Self.loadApprovalRowsChecked(at: approvalsPath)
            guard let index = items.firstIndex(where: {
                guard case .object(let object) = $0 else { return false }
                return object["id"] == .string(id)
            }), case .object(var object) = items[index] else { return }
            var card: [String: JSONValue] = [:]
            if case .object(let saved)? = object["chatCard"] { card = saved }
            object["chatCard"] = .object(card.merging(fields) { _, new in new })
            items[index] = .object(object)
            try await SwiftNativePersistenceCore.writeJSON(.array(items), to: approvalsPath)
        }
    }
    private func updateChatContinuation(
        _ id: String,
        update: @escaping @Sendable (ApprovalRecord, inout [String: JSONValue]) -> Bool
    ) async throws -> Bool {
        let lifeID = try DataRootLife.current(in: root)
        return try await SwiftNativePersistenceCore.withFileLock(approvalsPath) { [approvalsPath] in
            var items = try Self.loadApprovalRowsChecked(at: approvalsPath)
            guard let index = items.firstIndex(where: {
                guard case .object(let object) = $0 else { return false }
                return object["id"] == .string(id)
            }), case .object(var object) = items[index],
                let record = ApprovalRecord(json: items[index]) else {
                throw ApprovalInboxError.notFound(id)
            }
            guard record.status == "resolved", record.decision != nil else { return false }
            var state: [String: JSONValue] = [:]
            if let saved = object["chatContinuation"] {
                guard case .object(let value) = saved else { return false }
                state = value
            }
            let read = Self.readContinuation(state, lifeID: lifeID)
            if read != state {
                object["chatContinuation"] = .object(read)
                items[index] = .object(object)
                try await SwiftNativePersistenceCore.writeJSON(.array(items), to: approvalsPath)
                return false
            }
            guard update(record, &state) else { return false }
            object["chatContinuation"] = .object(state)
            items[index] = .object(object)
            try await SwiftNativePersistenceCore.writeJSON(.array(items), to: approvalsPath)
            return true
        }
    }
    nonisolated func readContinuations(_ records: [ApprovalRecord]) throws -> [ApprovalRecord] {
        let lifeID = try DataRootLife.current(in: root)
        return records.map { Self.readRecord($0, lifeID: lifeID) }
    }
    nonisolated static func readRecord(_ original: ApprovalRecord, lifeID: String) -> ApprovalRecord {
        var record = original
        if record.status == "resolved" {
            let state: [String: JSONValue] = if case .object(let saved)? = record.chatContinuation { saved } else { [:] }
            record.chatContinuation = .object(Self.readContinuation(state, lifeID: lifeID))
            if record.decision == "approved", record.executedAction == nil, DataRootLife.life(of: state["lifeID"]) != lifeID {
                record.executedAction = .object(["status": .string("stopped"), "reason": .string(DataRootLife.stoppedReason)])
            }
        }
        return record
    }
    private nonisolated static func readContinuation(_ original: [String: JSONValue], lifeID: String) -> [String: JSONValue] {
        guard original["done"] != .bool(true), DataRootLife.life(of: original["lifeID"]) != lifeID else { return original }
        var state = original
        state["done"] = .bool(true)
        state["status"] = .string("stopped")
        state["reason"] = .string(DataRootLife.stoppedReason)
        return state
    }
}
