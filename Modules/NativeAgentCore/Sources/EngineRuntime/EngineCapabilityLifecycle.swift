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
    public let refreshSkills: Bool
    public let refreshTools: Bool
    public let toolStatus: CapabilityToolStatus?
}

public struct CapabilityToolStatus: Sendable {
    public let message: String
    public let succeeded: Bool
    public var cause: String? = nil
}

/// Lifecycle authority and decision receipts, independent of the Mac UI model.
public struct CapabilityLifecycleCommands: Sendable {
    private struct VerbOutcome {
        let ok: Bool
        let detail: String
        let fields: [String: JSONValue]
        let toolStatus: CapabilityToolStatus?
        init(_ ok: Bool, _ detail: String, _ fields: [String: JSONValue], toolStatus: CapabilityToolStatus? = nil) {
            self.ok = ok
            self.detail = detail
            self.fields = fields
            self.toolStatus = toolStatus
        }
    }
    private let dataRoot: URL
    private static let retry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."

    public init(dataRootOverride: URL?) {
        dataRoot = dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    public func managePart(verb: String, input: [String: JSONValue], steer: [String]) async -> CapabilityCommandOutcome {
        let result = await runPart(verb: verb, input: input, steer: steer)
        let changes = input["preview"] != .bool(true) && !["read", "list"].contains(verb)
        return CapabilityCommandOutcome(ok: result.ok, detail: result.detail, fields: result.fields,
            refreshSkills: false, refreshTools: changes, toolStatus: result.toolStatus)
    }

    /// One part verb (`Parts`). Agent's rulings, 2026-10-01: keeping her own
    /// work is hers under Full Mac, and the owner sees each one as a decided
    /// row; she turns back on only what she turned off; dropping is final.
    private func runPart(verb: String, input: [String: JSONValue], steer: [String]) async -> VerbOutcome {
        let fullMac = await AppToolExecutor.freshQuietPosture(dataRoot: dataRoot)?.name == AppToolExecutor.fullMacModeName
        // Her door is never the person's own act: a trusted agent that started
        // the turn is its provenance, as in authorship. His acts come through
        // his own surfaces (the Tools page, his cards).
        let owner = false
        let parts = Parts(root: dataRoot)
        let id = AppToolExecutor.inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = input["preview"] == .bool(true)
        if preview, !["enable", "restore", "rollback", "drop"].contains(verb) {
            return VerbOutcome(false, "Only enable, restore, rollback and drop preview here; nothing was done.", [:])
        }
        let outcome: Parts.Outcome
        switch verb {
        case "save":
            if (try? parts.row(id)) == nil, !SwiftToolDispatcher.isAuthorableToolName(Parts.id(id)) {
                return VerbOutcome(false, "\(id) is a built-in tool's name. Pick another id; nothing was saved.", ["id": .string(id)])
            }
            do {
                let receipt = try await parts.save(input, steer: steer, fullMac: fullMac)
                let detail = AppToolExecutor.inputString(receipt["detail"]) ?? ""
                guard receipt["status"] == .string("kept") else { return VerbOutcome(receipt["status"] != .string("failed"), detail, receipt) }
                return await decided(VerbOutcome(true, detail, receipt.merging(["state_before": .string("draft")]) { $1 }), input: input, id: id)
            } catch PartError.stagedButFailed(let digest, let committed, let why) {
                return VerbOutcome(false, committed
                    ? "\(id) is saved as a draft but the call did not complete: \(why). Fix it and ability.save again."
                    : "\(id)'s version write did not complete, so it may or may not be on file: \(why). ability.read it, then ability.save again.",
                    ["effects": .string(committed ? "occurred" : "unknown"), "candidate_digest": .string(digest)])
            } catch let failure as ToolFailureError {
                var fields: [String: JSONValue] = [
                    "status": .string(failure.status.rawValue), "effects": .string(failure.effects.rawValue),
                    "remedy": Parts.remedy(failure),
                ]
                fields["reason"] = failure.code.map(JSONValue.string)
                fields["failure_code"] = failure.code.map(JSONValue.string)
                fields["argument_path"] = failure.argumentPath.map(JSONValue.string)
                fields["accepted"] = failure.accepted.map(JSONValue.string)
                return VerbOutcome(false, "\(id.isEmpty ? "The ability" : id) was not saved: \(failure.localizedDescription)", fields)
            } catch {
                return VerbOutcome(false, "\(id.isEmpty ? "The ability" : id) was not saved: \(error.localizedDescription)", ["effects": .string("none")])
            }
        case "read", "list":
            do {
                let offset: Int = if case .int(let n)? = input["offset"] { Int(n) } else { 0 }
                let step: Int? = if case .int(let n)? = input["step"] { Int(n) } else { nil }
                let read = verb == "list" ? try parts.list() : try parts.read(id, offset: offset, step: step)
                let fields: [String: JSONValue] = if case .object(let fields) = read { fields } else { [:] }
                return VerbOutcome(fields["status"] == .string("ok"), AppToolExecutor.inputString(fields["detail"]) ?? "", fields)
            } catch { return VerbOutcome(false, "Your abilities didn't read (\(error.localizedDescription))." + Self.retry, [:]) }
        case "validate": outcome = await parts.validate(id, input: input["input"], capture: input["capture"] == .bool(true))
        case "enable", "restore":
            outcome = await parts.enable(id, version: AppToolExecutor.inputString(input["version"]),
                                         fullMac: fullMac, ownerAuthorized: owner, preview: preview)
        case "disable": outcome = parts.disable(id, reason: AppToolExecutor.inputString(input["reason"]), steer: steer, fullMac: fullMac, ownerAuthorized: owner)
        case "rollback":
            outcome = await parts.rollback(id, version: AppToolExecutor.inputString(input["version"]), fullMac: fullMac, ownerAuthorized: owner, preview: preview)
        case "drop": outcome = parts.drop(id, pending: input["pending"] == .bool(true), fullMac: fullMac, ownerAuthorized: owner, preview: preview)
        default: return VerbOutcome(false, "No ability verb is called \(verb).", [:])
        }
        var fields = outcome.fields
        let review = fields.removeValue(forKey: "review")
        if preview || !["enable", "restore"].contains(verb) {
            let status = ["enable", "disable", "restore"].contains(verb)
                ? CapabilityToolStatus(message: outcome.text, succeeded: outcome.ok) : nil
            return VerbOutcome(outcome.ok, outcome.text, fields, toolStatus: status)
        }
        if fields["needs_owner"] == .bool(true) {
            // The owner's card, answerable on the Mac and their phone (`askUserToInstallScript`).
            let name = AppToolExecutor.inputString(fields["name"]) ?? id
            let card: ApprovalRecord
            do {
                guard let digest = AppToolExecutor.inputString(fields["candidate_digest"]),
                      case .object(let shown)? = review, shown["version"] == .string(digest) else {
                    throw PartError.invalid("The exact version to review is unavailable; read the ability again.")
                }
                card = try await SwiftNativeApprovalInbox(root: dataRoot).askUserToInstallScript(
                    skill: name, skillID: AppToolExecutor.inputString(fields["id"]) ?? id,
                    digest: digest, why: outcome.text,
                    script: try JSONValue.object(shown).serialize(pretty: false))
            } catch {
                return VerbOutcome(false, outcome.text + " The card asking the owner did not file (\(String(describing: error))): tell them.", fields)
            }
            let next: JSONValue = .object(["tool": .string("app"), "input": .object(["page": .string("inbox")])])
            return VerbOutcome(false, outcome.text + " A card asks the owner, on the Mac and their phone.",
                    fields.merging(["approval_id": .string(card.id), "approvalId": .string(card.id),
                        "not_run_status": .string("approval_filed"), "next_call": next,
                        "remedy": .object(["kind": .string("wait"), "next_call": next,
                            "instruction": .string("The owner has a card for it; it is kept if they approve. Don't retry.")])]) { $1 })
        }
        guard outcome.ok, fields["changed"] != .bool(false) else {
            return VerbOutcome(outcome.ok, outcome.text, fields, toolStatus: .init(message: outcome.text, succeeded: outcome.ok))
        }
        return await decided(VerbOutcome(true, outcome.text, fields, toolStatus: .init(message: "Ability on", succeeded: true)), input: input, id: id)
    }

    /// A keep of hers the owner sees in their Inbox, as a decided row.
    private func decided(_ kept: VerbOutcome, input: [String: JSONValue], id: String) async -> VerbOutcome {
        if PeerDataTaint.trustedTurn { return kept }
        let decided = await HarnessDecidedRow.record(
            requester: kept.fields["state_before"] == .string("draft") ? "keep ability" : "re-enable ability",
            tool: AppToolExecutor.inputString(kept.fields["name"]) ?? id, sessionID: AppToolExecutor.inputString(input["__session_id"]),
            dataRoot: dataRoot, ran: true)
        guard let decided else {
            return VerbOutcome(true, kept.detail + " Your decision did not reach the owner's Inbox: the Inbox did not write.", kept.fields)
        }
        return VerbOutcome(true, kept.detail + " The owner sees it in their Inbox"
            + (decided.decisions > 1 ? ", decision \(decided.decisions) on that row." : "."),
            kept.fields.merging(["decided_row": .string(decided.id), "decisions_on_row": .int(Int64(decided.decisions))]) { $1 },
            toolStatus: kept.toolStatus)
    }
}
