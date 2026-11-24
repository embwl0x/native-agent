import SenseCore
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// ConversationSurfaceProfile owns surface identity so security checks share one answer.
import DeskCore
// Blueprint: | `ApprovalStorage.swift` | Checked canonical approval storage |
extension SwiftNativeApprovalInbox {
    /// The most rows `requests.json` keeps. Terminal rows above it are the store's settled history and are evictable; pending work is not.
    public static let storedApprovalCap = 300
    static let terminalApprovalStatuses: Set<String> = [
        "resolved",
    ]
    /// Over cap, evicts oldest settled terminal rows or throws `.queueFull`; pending work stays answerable.
    nonisolated static func cappedEvictingTerminalRows(
        _ items: [JSONValue],
        cap: Int,
        now: Date,
        lifeID: String
    ) throws -> [JSONValue] {
        var overflow = items.count - cap
        guard overflow > 0 else { return items }
        var dropped = Set<Int>()
        // The array is newest-first, so the oldest candidates are at the end.
        for index in stride(from: items.count - 1, through: 0, by: -1) {
            guard overflow > 0 else { break }
            guard case .object(let object) = items[index],
                  case .string(let status)? = object["status"],
                  terminalApprovalStatuses.contains(status) else { continue }
            // Approval precedes execution. Denied and canceled decisions have no executor outcome to await, but may still owe a reporting turn.
            guard let saved = ApprovalRecord(json: items[index]) else { continue }
            let record = Self.readRecord(saved, lifeID: lifeID)
            if status == "resolved", record.decision == "approved", record.executedAction == nil {
                continue
            }
            // A resolved decision is not settled while its reporting turn is unclaimed, queued or in flight. Durable state does not age out.
            if Self.hasChatReportingObligation(record), let saved = record.chatContinuation {
                guard case .object(let state) = saved,
                      state["done"] == .bool(true) else { continue }
            }
            if continuationIsPending(record, now: now) {
                continue
            }
            dropped.insert(index)
            overflow -= 1
        }
        guard overflow == 0 else {
            throw ApprovalInboxError.queueFull(pending: items.count - dropped.count, cap: cap)
        }
        return items.enumerated()
            .filter { !dropped.contains($0.offset) }
            .map(\.element)
    }
    /// Only a missing file means an empty queue; any damaged existing evidence makes authority unavailable and cannot be overwritten.
    public nonisolated static func loadApprovalRowsChecked(at path: URL) throws -> [JSONValue] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ApprovalInboxError.unavailable(
                underlying: "approval store unreadable: \(error.localizedDescription)"
            )
        }
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(data)
        } catch {
            throw ApprovalInboxError.malformedResponse(
                "approval store contains malformed JSON: \(error.localizedDescription)"
            )
        }
        guard case .array(let items) = raw else {
            throw ApprovalInboxError.malformedResponse(
                "approval store is not a JSON array"
            )
        }
        try validateApprovalRows(items)
        return items
    }
    /// Rejects invalid or duplicate rows before an authoritative queue read or merged write.
    public nonisolated static func validateApprovalRows(_ items: [JSONValue]) throws {
        var ids = Set<String>()
        for (index, item) in items.enumerated() {
            guard let record = ApprovalRecord(json: item) else {
                throw ApprovalInboxError.malformedResponse(
                    "approval store row \(index) is not a valid approval record"
                )
            }
            guard ids.insert(record.id).inserted else {
                throw ApprovalInboxError.malformedResponse(
                    "approval store contains duplicate id \(record.id)"
                )
            }
            if record.status == "pending" {
                guard record.localOnly == !record.remoteResolvable else {
                    throw ApprovalInboxError.malformedResponse("pending approval row \(index) has conflicting authority fields")
                }
                if Self.hardLocalOnlyActions.contains(record.action),
                   (record.remoteResolvable || !record.localOnly) {
                    throw ApprovalInboxError.malformedResponse("pending approval row \(index) widens a local-only action")
                }
            }
        }
    }
    nonisolated static func validateResolutionAuthority(
        _ provenance: ApprovalResolutionProvenance,
        row: [String: JSONValue],
        id: String, parts: @escaping AppActionBinding.PartLookup
    ) throws {
        guard let record = ApprovalRecord(json: .object(row)) else {
            throw ApprovalInboxError.malformedResponse("approval row is malformed")
        }
        guard !provenance.decidedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "decision provenance has no actor"
            )
        }
        if case .personMessage = provenance,
           try PermissionLaw.humanDecides(action: record.action, payload: record.payload, turn: nil, parts: parts) {
            throw ApprovalInboxError.resolutionNotAuthorized(id: id, reason: "Permanent deletion requires the person's tap.")
        }
        let transport = provenance.transport
        if case .telegram = transport, record.requiresExecutableReview {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "Review and approve the exact code on the Mac or paired phone; Telegram cannot show the whole review."
            )
        }
        if case .signedIOS(let clientID, _) = transport {
            guard !clientID.isEmpty else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "signed iOS provenance has no client identity"
                )
            }
            // The router verifies device pairing and signature; only the agent decides studio canon.
            guard !record.isAgentsOwnDecision else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "The agent decides its own studio canon."
                )
            }
            return
        }
        // A private Telegram chat id identifies its sole user, binding the owner DM to the person's authority.
        if case .telegram(let chatID, let userID) = transport, !chatID.isEmpty, chatID == userID,
           case .object(let card)? = row["chatCard"], card["telegramChatId"] == .string(chatID) {
            guard !record.isAgentsOwnDecision else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "The agent decides its own studio canon."
                )
            }
            return
        }
        if provenance.isRemote {
            guard record.remoteResolvable, !record.localOnly else {
                throw ApprovalInboxError.resolutionNotAuthorized(
                    id: id, reason: "approval is local-only"
                )
            }
        }
        guard case .telegram(let chatID, let userID) = transport else { return }
        guard !chatID.isEmpty, !userID.isEmpty else {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "Telegram transport identity is incomplete"
            )
        }
        guard case .object(let payload) = record.payload,
              case .object(let telegram)? = payload["telegram"],
              telegram["chatId"] == .string(chatID),
              case .object(let origin)? = payload["origin"],
              origin["userId"] == .string(userID) else {
            throw ApprovalInboxError.resolutionNotAuthorized(
                id: id, reason: "Telegram transport identity does not match approval origin"
            )
        }
    }
    nonisolated static func strip(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated static func codepointPrefix(_ value: String, _ n: Int) -> String {
        let scalars = value.unicodeScalars
        if scalars.count <= n { return value }
        return String(String.UnicodeScalarView(scalars.prefix(n)))
    }
    nonisolated static func pyStr(_ value: JSONValue?, fallback: String) -> String {
        guard let value else { return fallback }
        switch value {
        case .null: return fallback
        case .string(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .array, .object: return ""
        }
    }
}
