import AuthoredCapabilities
import AppToolRuntime
import ApprovalInbox
import ChatTurnContracts
import Foundation
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import ChatToolRuntime
import Senses
import ToolExecution
import ToolRegistry
import TrustCenter
// Blueprint: | `EngineCapabilityLifecycle.swift` | `CapabilityLifecycleCommands` struct; `ability_manage` verbs over `Parts`, the owner's card for a keep and decision receipts; `CapabilityCommandOutcome` invalidates UI projections |

/// A command receipt; the mounted parts list is a projection of its saved state.
public struct CapabilityCommandOutcome: Sendable {
    public let ok: Bool
    public let detail: String
    public let fields: [String: JSONValue]
    public var refreshTools = false
    public let toolStatus: CapabilityToolStatus?

    init(_ ok: Bool, _ detail: String, _ fields: [String: JSONValue], toolStatus: CapabilityToolStatus? = nil) {
        self.ok = ok
        self.detail = detail
        self.fields = fields
        self.toolStatus = toolStatus
    }
}

public struct CapabilityToolStatus: Sendable {
    public let message: String
    public let succeeded: Bool
}

/// Lifecycle authority and decision receipts, independent of the Mac UI model.
public struct CapabilityLifecycleCommands: Sendable {
    private let dataRoot: URL
    private static let retry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."

    public init(dataRootOverride: URL?) {
        dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    public func managePart(verb: String, input: [String: JSONValue], steer: [String]) async -> CapabilityCommandOutcome {
        var result = await runPart(verb: verb, input: input, steer: steer)
        result.refreshTools = input["preview"] != .bool(true) && !["read", "list"].contains(verb)
        return result
    }

    /// Full Mac admits her keeps with decided rows; she re-enables only what she disabled; dropping is final.
    private func runPart(verb: String, input: [String: JSONValue], steer: [String]) async -> CapabilityCommandOutcome {
        let fullMac = await AppToolExecutor.freshQuietPosture(dataRoot: dataRoot)?.name == AppToolExecutor.fullMacModeName
        // Her door is never the person's own act: a trusted agent that started
        // the turn is its provenance, as in authorship. His acts come through
        // his own surfaces (the Tools page, his cards).
        let owner = false
        let parts = Parts(root: dataRoot)
        let id = input["id"]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = input["preview"] == .bool(true)
        if preview, !["enable", "restore", "rollback", "drop"].contains(verb) {
            return CapabilityCommandOutcome(false, "Only enable, restore, rollback and drop preview here; nothing was done.", [:])
        }
        let outcome: Parts.Outcome
        switch verb {
        case "save":
            if (try? parts.row(id)) == nil, !SwiftToolDispatcher.isAuthorableToolName(Parts.id(id)) {
                return CapabilityCommandOutcome(false, "\(id) is a built-in tool's name. Pick another id; nothing was saved.", ["id": .string(id)])
            }
            do {
                let receipt = try await parts.save(input, steer: steer, fullMac: fullMac)
                let detail = receipt["detail"]?.scalarText ?? ""
                guard receipt["status"] == .string("kept") else { return CapabilityCommandOutcome(receipt["status"] != .string("failed"), detail, receipt) }
                return await decided(CapabilityCommandOutcome(true, detail, receipt.merging(["state_before": .string("draft")]) { $1 }), input: input, id: id)
            } catch PartError.stagedButFailed(let digest, let committed, let why) {
                return CapabilityCommandOutcome(false, committed
                    ? "\(id) is saved as a draft but the call did not complete: \(why). Fix it and ability.save again."
                    : "\(id)'s version write did not complete, so it may or may not be on file: \(why). ability.read it, then ability.save again.",
                    ["effects": .string(committed ? "occurred" : "unknown"), "candidate_digest": .string(digest)])
            } catch let failure as ToolFailureError {
                return CapabilityCommandOutcome(false, "\(id.isEmpty ? "The ability" : id) was not saved: \(failure.localizedDescription)",
                    failure.failureEvidence(defaultCode: "ability_save_failed"))
            } catch {
                return CapabilityCommandOutcome(false, "\(id.isEmpty ? "The ability" : id) was not saved: \(error.localizedDescription)", ["effects": .string("none")])
            }
        case "read", "list":
            do {
                let offset: Int = if case .int(let n)? = input["offset"] { Int(n) } else { 0 }
                let step: Int? = if case .int(let n)? = input["step"] { Int(n) } else { nil }
                let read = verb == "list" ? try parts.list(offset: offset) : try parts.read(id, offset: offset, step: step)
                let fields: [String: JSONValue] = if case .object(let fields) = read { fields } else { [:] }
                return CapabilityCommandOutcome(fields["status"] == .string("ok"), fields["detail"]?.scalarText ?? "", fields)
            } catch { return CapabilityCommandOutcome(false, "Your abilities didn't read (\(error.localizedDescription))." + Self.retry, [:]) }
        case "validate": outcome = await parts.validate(id, input: input["input"], capture: input["capture"] == .bool(true))
        case "enable", "restore":
            outcome = await parts.enable(id, version: input["version"]?.scalarText,
                                         fullMac: fullMac, ownerAuthorized: owner, preview: preview)
        case "disable": outcome = parts.disable(id, reason: input["reason"]?.scalarText, steer: steer, fullMac: fullMac, ownerAuthorized: owner)
        case "rollback":
            outcome = await parts.rollback(id, version: input["version"]?.scalarText, fullMac: fullMac, ownerAuthorized: owner, preview: preview)
        case "drop": outcome = parts.drop(id, pending: input["pending"] == .bool(true), fullMac: fullMac, ownerAuthorized: owner, preview: preview)
        default: return CapabilityCommandOutcome(false, "No ability verb is called \(verb).", [:])
        }
        var fields = outcome.fields
        let review = fields.removeValue(forKey: "review")
        if preview || !["enable", "restore"].contains(verb) {
            let status = ["enable", "disable", "restore"].contains(verb)
                ? CapabilityToolStatus(message: outcome.text, succeeded: outcome.ok) : nil
            return CapabilityCommandOutcome(outcome.ok, outcome.text, fields, toolStatus: status)
        }
        if fields["needs_owner"] == .bool(true) {
            // The owner's card, answerable on the Mac and their phone (`askUserToInstallScript`).
            let name = fields["name"]?.scalarText ?? id
            let card: ApprovalRecord
            do {
                guard let digest = fields["candidate_digest"]?.scalarText,
                      case .object(let shown)? = review, shown["version"] == .string(digest) else {
                    throw PartError.invalid("The exact version to review is unavailable; read the ability again.")
                }
                card = try await SwiftNativeApprovalInbox(root: dataRoot).askUserToInstallScript(
                    skill: name, skillID: fields["id"]?.scalarText ?? id,
                    digest: digest, why: outcome.text,
                    script: try JSONValue.object(shown).serialize(pretty: false))
            } catch {
                return CapabilityCommandOutcome(false, outcome.text + " The card asking the owner did not file (\(String(describing: error))): tell them.", fields)
            }
            let next: JSONValue = .object(["tool": .string("app"), "input": .object(["page": .string("inbox")])])
            return CapabilityCommandOutcome(false, outcome.text + " A card asks the owner, on the Mac and their phone.",
                    fields.merging(["approval_id": .string(card.id), "approvalId": .string(card.id),
                        "not_run_status": .string("approval_filed"), "next_call": next,
                        "remedy": .object(["kind": .string("wait"), "next_call": next,
                            "instruction": .string("The owner has a card for it; it is kept if they approve. Don't retry.")])]) { $1 })
        }
        guard outcome.ok, fields["changed"] != .bool(false) else {
            return CapabilityCommandOutcome(outcome.ok, outcome.text, fields, toolStatus: .init(message: outcome.text, succeeded: outcome.ok))
        }
        return await decided(CapabilityCommandOutcome(true, outcome.text, fields, toolStatus: .init(message: "Ability on", succeeded: true)), input: input, id: id)
    }

    /// A keep of hers the owner sees in their Inbox, as a decided row.
    private func decided(_ kept: CapabilityCommandOutcome, input: [String: JSONValue], id: String) async -> CapabilityCommandOutcome {
        if PeerDataTaint.trustedTurn { return kept }
        let decided = await HarnessDecidedRow.record(
            requester: kept.fields["state_before"] == .string("draft") ? "keep ability" : "re-enable ability",
            tool: kept.fields["name"]?.scalarText ?? id, sessionID: input["__session_id"]?.scalarText,
            dataRoot: dataRoot, ran: true)
        guard let decided else {
            return CapabilityCommandOutcome(true, kept.detail + " Your decision did not reach the owner's Inbox: the Inbox did not write.", kept.fields)
        }
        return CapabilityCommandOutcome(true, kept.detail + " The owner sees it in their Inbox"
            + (decided.decisions > 1 ? ", decision \(decided.decisions) on that row." : "."),
            kept.fields.merging(["decided_row": .string(decided.id), "decisions_on_row": .int(Int64(decided.decisions))]) { $1 },
            toolStatus: kept.toolStatus)
    }
}
