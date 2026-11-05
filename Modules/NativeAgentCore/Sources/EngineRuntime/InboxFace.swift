import PersistenceCore
import AppToolRuntime
import ApprovalInbox
import ApprovalTransactions
import AuthoredCapabilities
import ChatTurnContracts
import Desk
import Experiences
import Foundation
import NativeAgentCore
import NativeAgentShared
import TrustCenter
// Blueprint: | `InboxFace.swift` | Inbox's one face reads ForPerson's matters and change stream; person actions use existing owners and agent actions retain the invoking turn's inbox admission |

extension NativeAgentEngine {
    @MainActor func inboxFaceRead() -> PartFaces.Read {
        let owner = ForPerson.at(dataRoot)
        inbox.faceChanges?.cancel()
        inbox.faceChanges = Task { @MainActor [weak pages] in
            for await _ in await owner.changes() {
                guard !Task.isCancelled, let pages else { return }
                await pages.refresh(page: "inbox")
            }
        }
        return { [weak self] in
            guard let self else { throw PartCallError(code: "inbox_closed", message: "The Inbox owner has closed.") }
            return try await inboxFace()
        }
    }

    @MainActor func inboxFace() async throws -> (PartFace, UInt64) {
        let now = Date()
        let epoch = UInt64(now.timeIntervalSince1970 * 1000)
        let matters = try await ForPerson.at(dataRoot).matters().filter(ForPerson.isRow)
        let active = matters.filter { [.unread, .read].contains(ForPerson.reading($0)) }
        let waiting = active.filter { $0.owes["decide"] != nil }
        let remaining = active.filter { $0.owes["decide"] == nil }
        let failed = remaining.filter { $0.face?.row?.tone == .failed }
        let news = remaining.filter { $0.face?.row?.tone != .failed }.sorted {
            let left = ForPerson.reading($0) == .unread, right = ForPerson.reading($1) == .unread
            return left != right ? left : ($0.at, $0.id) > ($1.at, $1.id)
        }
        let earlier = matters.filter {
            [.archived, .dismissed].contains(ForPerson.reading($0))
        }
        let since = now.addingTimeInterval(-24 * 60 * 60)
        let archived = earlier.filter { ForPerson.reading($0) == .archived }
        let recent = archived.filter { matter in
            guard let stamp = matter.outcome?.at ?? matter.updatedAt, let at = NativeTimestampFormat.parseISO8601(stamp) else { return false }
            return at >= since
        }
        let undated = archived.filter { matter in
            guard let stamp = matter.outcome?.at ?? matter.updatedAt else { return true }
            return NativeTimestampFormat.parseISO8601(stamp) == nil
        }.count
        var sections: [PartFace.Section] = [
            .init(id: "waiting", title: "Waiting for you", style: .list,
                  footer: waiting.isEmpty ? "No requests in the current reading." : nil,
                  rows: waiting.map { inboxFaceRow($0, tone: .attention) }),
            .init(id: "went-wrong", title: "Went wrong", style: .list,
                  rows: failed.map { inboxFaceRow($0, tone: .failed) }),
            .init(id: "news", title: "News", style: .list, footer: news.isEmpty ? "No news in the current reading." : nil,
                  rows: news.map { inboxFaceRow($0) }),
        ]
        sections.append(.init(id: "earlier", title: "Earlier", style: .values,
                              footer: undated == 0 ? nil : "\(undated) archived matters have no settlement time; the count excludes those matters.", rows: [
            .init(id: "inbox.earlier", title: "Archived in the last day", value: String(recent.count), open: "page:inbox/earlier"),
        ]))
        return (.init(title: "Inbox", line: "Requests, things that went wrong, and news.", sections: sections), epoch)
    }

    private func inboxFaceRow(_ matter: Experience, tone: PartFace.Tone? = nil) -> PartFace.Row {
        let reading = ForPerson.reading(matter)
        guard let face = matter.face, let row = face.row else {
            return .init(id: matter.id, title: "This matter has no face row", detail: "The experience owner must supply the missing row.",
                         at: matter.at, tone: .attention)
        }
        let approval = matter.evidence.contains { $0.source == Matter.approvals }
        var actions: [PartFace.Action] = (row.actions ?? []).filter {
            InboxActionVocabulary.nativeActionIDs.contains($0.id)
                || (matter.id.hasPrefix("interaction:") && $0.id.hasPrefix("interaction_choice_"))
        }
        if approval {
            actions = actions.map { .init(id: $0.id, label: $0.id == "reject" ? "Deny" : $0.label, role: $0.role) }
        }
        let declared = actions.map { InboxActionRecord(id: $0.id, label: $0.label, description: nil) }
        let owned = InboxActionVocabulary.actions(declared: declared, approvalLinked: approval)
        let existing = Set(actions.map(\.id))
        actions += owned.filter { !existing.contains($0.id) && ($0.id != "read" || reading == .unread) }.map {
            .init(id: $0.id, label: $0.label)
        }
        actions = actions.filter { $0.id != "read" || reading == .unread }.map {
            .init(id: $0.id, label: $0.label,
                  role: ["archive", "dismiss", "reject"].contains($0.id) ? .destructive : $0.role)
        }
        var detail = [row.detail, face.words].compactMap { $0 }.filter { !$0.isEmpty }
        if detail.count == 2, detail[0] == detail[1] { detail.removeLast() }
        let files = face.artifacts.filter { $0.source == Matter.files }.map(\.id)
        if !files.isEmpty { detail.append("Files: " + files.joined(separator: "\n")) }
        return .init(id: matter.id, title: row.title, detail: detail.joined(separator: "\n\n"),
                     value: [reading == .unread ? "Unread" : reading.rawValue.capitalized, row.value].compactMap { $0 }.joined(separator: " · "),
                     at: row.at, symbol: row.symbol, tone: tone ?? row.tone, open: row.open,
                     actions: actions.isEmpty ? nil : actions)
    }

    @MainActor func inboxAct(row: String, action: String, value: String?, by actor: PartFaces.Actor) async throws -> String? {
        do { return try await applyInboxAct(row: row, action: action, value: value, by: actor) }
        catch {
            await settle { _ = await self.pages.refresh(page: "inbox") }
            if error is CancellationError { throw error }
            if let owned = error as? PartCallError { throw owned }
            throw PartCallError(code: "inbox_action_failed", message: error.localizedDescription)
        }
    }

    @MainActor private func applyInboxAct(row: String, action: String, value: String?, by actor: PartFaces.Actor) async throws -> String? {
        guard let matter = try await ForPerson.at(dataRoot).matter(row), ForPerson.isRow(matter),
              [.unread, .read].contains(ForPerson.reading(matter)),
              inboxFaceRow(matter).actions?.contains(where: { $0.id == action }) == true else {
            throw PartCallError(code: "inbox_changed", message: "That Inbox row no longer offers this action. Read Inbox again.")
        }
        let executor = ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), false)
        guard hasBody, let host = executor.quietHost() as? any QuietInboxHost,
              host.inboxDataRoot == dataRoot, host.dataRootOverride == dataRoot else {
            throw PartCallError(code: "inbox_unavailable", message: "The Inbox action owner is unavailable for this data root.")
        }
        switch actor {
        case .agent(let turn): return try await agentInboxAct(row: row, action: action, reason: value, turn: turn)
        case .person(let door, let device):
            guard door == "mac" || door == "phone" else {
                throw PartCallError(code: "unknown_door", message: "This Inbox action has no recognized person door.")
            }
            if ["approve", "reject"].contains(action), let approval = matter.evidence.first(where: { $0.source == Matter.approvals }) {
                // The phone answers with the paired device its router verified, as its signed approval card does; with none, nothing is invented.
                let phone = door == "phone" ? device.flatMap { $0.isEmpty ? nil : $0 } : nil
                guard door == "mac" || phone != nil else {
                    throw PartCallError(code: "approval_identity_required",
                        message: "This phone's identity was not verified, so the approval was not answered. Pair the phone again, then answer it.")
                }
                let current = try await SwiftNativeApprovalInbox(root: dataRoot).get(approval.id)
                guard OwnerAttentionPolicy.approvalWaits(status: current.status, agentOwned: current.isAgentsOwnDecision),
                      ApprovalChatCards.canResolve(current) else {
                    throw PartCallError(code: "approval_unavailable", message: "This approval does not offer a person decision with readable details.")
                }
                let record: ApprovalRecord
                if let phone {
                    let signed = ApprovalResolutionProvenance.signedIOS(clientID: phone, decidedBy: "ios_signed_operator")
                    record = try await ports.backgroundWork.approvals.resolveApproval(id: approval.id, decision: action,
                        provenance: signed, turn: signed.resolvingTurn)
                } else {
                    record = try await approvals.resolveApproval(id: approval.id, decision: action,
                        coordinator: ports.backgroundWork.approvals,
                        turn: ApprovalResolutionProvenance.local(decidedBy: "mac_ui").resolvingTurn)
                }
                guard let decision = record.decision else {
                    throw PartCallError(code: "approval_unconfirmed", message: "The approval owner returned no recorded decision. Read Inbox again.")
                }
                return "Approval recorded as " + decision + "."
            }
            let envelope: TurnEnvelope = door == "mac" ? .personOnMac("mac_ui:inbox." + action) : .init(surface: "ios")
            let turn = Turn().with(\.envelope, envelope)
            try await host.performInboxAction(row, action: action, metadata: [:], quiet: false, dataRootOverride: dataRoot, turn: turn)
            return "Inbox action completed: " + action + "."
        }
    }

    @MainActor private func agentInboxAct(row: String, action: String, reason: String?, turn: Turn) async throws -> String? {
        guard let surface = turn.runtime?.surface, !surface.isEmpty else {
            throw PartCallError(code: "turn_unavailable", message: "This Inbox action has no originating turn surface.")
        }
        var args: [String: JSONValue] = ["id": .string(row)]
        let verb: String
        switch action {
        case "archive", "dismiss", "read":
            guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PartCallError(code: "missing_reason", message: "The agent must supply a reason through the existing inbox action.")
            }
            args["reason"] = .string(reason)
            verb = action == "read" ? "inbox.mark_read" : "inbox." + action
        case "approve": verb = "inbox.approve"
        case "reject": verb = row.hasPrefix("interaction:") ? "inbox.not_now" : "inbox.deny"
        default: verb = "inbox.act"; args["action"] = .string(action)
        }
        let result = try await ports.appTools(SwiftNativeSecurityCenter(dataRoot: dataRoot), false).execute(
            tool: "app", input: ["action": .string(verb), "args": .object(args)], surface: surface, turn: turn)
        guard result.objectValue?["status"] == .string("ok") else {
            throw PartCallError(code: "inbox_refused", message: try result.serialize(pretty: false))
        }
        return try result.serialize(pretty: false)
    }
}
