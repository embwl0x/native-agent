import ApprovalInbox
import ChatTurnContracts
import ChatToolParsing
import ChatToolRuntime
import Desk
import Foundation
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import TrustCenter
// Blueprint: | `QuietInboxCommands.swift` | `QuietInboxHost`: inbox fences and commands |

@MainActor public protocol QuietInboxHost: QuietToolHost {
    var inboxDataRoot: URL { get }
    var interactionSource: String { get }
    func interactionForInboxItem(_ id: String, dataRoot: URL) async -> InlineInteraction?
    func readInbox() async throws -> [InboxItemRecord]
    func inboxPresentation(_ item: InboxItemRecord) -> (hidden: Bool, linkedApproval: Bool, actions: [InboxActionRecord])
    func performInboxAction(_ id: String, action: String, metadata: [String: JSONValue], quiet: Bool, dataRootOverride: URL?) async throws
    func withdrawApproval(id: String, decidedBy: String) async throws
    func refreshInboxSurfaces() async
    func inboxActDescription(_ item: InboxItemRecord, action: String) -> String
}

// MARK: - inbox

/// The `inbox` tool over the Inbox page's own reads and `inboxAction`, so a
/// note she settles leaves Today, the Desk and the phone exactly as a tap does.
/// What an inbox verb acts on once nothing refuses it.
private struct QuietInboxTarget {
    let items: [InboxItemRecord]
    var ids: [String] = []
    var byID: [String: InboxItemRecord] = [:]
    /// withdraw: her pending approval, by id and title.
    var approval: (id: String, title: String)?
    /// act and repair: the note, and the button pressed on it.
    var press: (item: InboxItemRecord, action: String)?
    /// The button is User's below Full Mac: Full Mac let it through, and
    /// he sees it as a decided row.
    var decided = false
}

private struct QuietInboxRefusal: Error { let json: JSONValue }

extension QuietInboxHost {
    /// Every check that refuses an inbox verb before anything is written:
    /// the ids, a reason to put a note away, withdrawing only her own
    /// pending ask, and below Full Mac a note's button that is User's (a
    /// permission or capability card, an approval). Reads only, so the
    /// door's preview asks it too and refuses what the real call would.
    public func quietInboxFence(verb: String, input: [String: JSONValue]) async -> JSONValue? {
        if case .failure(let refusal) = await inboxGate(verb: verb, input: input) { return refusal.json }
        return nil
    }

    private static func inboxText(_ input: [String: JSONValue], _ key: String) -> String {
        input[key]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func inboxGate(verb: String, input: [String: JSONValue]) async -> Result<QuietInboxTarget, QuietInboxRefusal> {
        func refuse(_ json: JSONValue) -> Result<QuietInboxTarget, QuietInboxRefusal> { .failure(QuietInboxRefusal(json: ChatToolOutcome.refusedBeforeRunning(json))) }
        func text(_ key: String) -> String { Self.inboxText(input, key) }
        let items: [InboxItemRecord]
        do { items = try await self.readInbox() } catch {
            return refuse(AppToolExecutor.failure("inbox_unreadable",
                "The inbox didn't read (\(error.localizedDescription)). Try again; read \(AppToolExecutor.doorDoctor) if it keeps failing."))
        }
        var target = QuietInboxTarget(items: items)
        if verb == "list" { return .success(target) }

        var ids = [text("id")].filter { !$0.isEmpty }
        if case .array(let many)? = input["ids"] {
            ids += many.compactMap { $0.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard !ids.isEmpty else {
            return refuse(AppToolExecutor.failure("missing_id", "Pass id (or ids). app {page:\"inbox\"} lists them."))
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let unknown = ids.first(where: { byID[$0] == nil }) {
            return refuse(.object(["status": .string("not_found"), "reason": .string("unknown_id"), "id": .string(unknown),
                "detail": .string("No note has id \(unknown). Read app {page:\"inbox\"} for the current ids.")]))
        }
        target.ids = ids
        target.byID = byID

        switch verb {
        case "read":
            break
        case "archive", "dismiss", "mark_read":
            guard !text("reason").isEmpty else {
                return refuse(AppToolExecutor.failure("missing_reason",
                    "Say why in reason (a few words, e.g. \"stale test note\"); it is saved on the note."))
            }
        case "withdraw":
            // The agent may withdraw its own pending ask; answering another agent's is the owner's call.
            guard ids.count == 1, let approvalID = byID[ids[0]]?.related_approval_id, !approvalID.isEmpty else {
                return refuse(AppToolExecutor.failure("no_approval",
                    "That note carries no approval. withdraw takes one note whose read shows approval_id."))
            }
            let root = self.dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
            guard let record = try? await SwiftNativeApprovalInbox(root: root).get(approvalID) else {
                return refuse(AppToolExecutor.failure("approval_unreadable",
                    "Approval \(approvalID) didn't read, so nothing was withdrawn. Try again; read \(AppToolExecutor.doorDoctor) if it keeps failing."))
            }
            guard record.status == "pending" else {
                return refuse(AppToolExecutor.failure("not_pending",
                    "That approval is \(record.status), not waiting, so there is nothing to withdraw. Archive the note with a reason if it is stale."))
            }
            if case .object(let payload) = record.payload, payload["peer_id"] != nil {
                return refuse(AppToolExecutor.failure("owners_call",
                    "That approval is another agent's ask, not yours, so answering it is the owner's. Leave it for them."))
            }
            target.approval = (approvalID, record.title)
        default: // act, repair, not_now
            guard ids.count == 1, let item = byID[ids[0]] else {
                return refuse(AppToolExecutor.failure("one_id", "\(verb) takes one id."))
            }
            let actionIDs = inboxPresentation(item).actions.map { InboxActionVocabulary.normalizedAction($0.id) }
            // A note's buttons in the words its read shows (inbox.not_now, inbox.open_on_mac · User's).
            let shown = inboxPresentation(item).actions.compactMap { AppToolExecutor.noteButton(id: $0.id, label: $0.label) }
            // A card's Not now is inbox.not_now, its warning on its line; never a bare reject.
            let requested = verb == "repair" ? "repair" : verb == "not_now" ? "reject" : text("action").lowercased()
            if verb == "act", item.source == self.interactionSource, ["reject", "deny"].contains(requested) {
                return refuse(AppToolExecutor.failure("use_not_now",
                    "A card's Not now is its own action: \(AppActions.action("inbox.not_now")?.line ?? "inbox.not_now"). "
                    + "Nothing was done.", extra: ["actions": .array(shown.map { .string($0) })]))
            }
            let action = requested.isEmpty
                ? actionIDs.first(where: { ["act", "open_approvals", "repair"].contains($0) }) ?? ""
                : InboxActionVocabulary.normalizedAction(requested)
            if ["archive", "dismiss", "read", "view"].contains(action) {
                return refuse(AppToolExecutor.failure("use_verb",
                    "\(action) is its own here: " + (action == "read" || action == "view"
                        ? "app {page:\"inbox\", item:<id>} reads a note." : "use inbox.\(action).")))
            }
            guard !action.isEmpty, actionIDs.contains(action) else {
                return refuse(AppToolExecutor.failure("no_such_action",
                    action.isEmpty ? "This note has no action of its own; archive or dismiss it instead."
                        : "This note has no \(action) action. Its actions: \(shown.joined(separator: ", ")).",
                    extra: ["actions": .array(shown.map { .string($0) })]))
            }
            // Full Mac makes the person's buttons available to her.
            let fullMac = await AppToolExecutor.freshQuietPosture(
                dataRoot: self.dataRootOverride ?? PersistenceCore.defaultDataRoot())?.name == AppToolExecutor.fullMacModeName
            let opensForUser = item.source == self.interactionSource && action == "act"
            if !fullMac, opensForUser {
                return refuse(AppToolExecutor.failure("opens_for_owner",
                    "That card's Open on Mac only opens it for the person at the Mac (inbox.open_on_mac is theirs). inbox.not_now declines it; if it is stale, inbox.archive or inbox.dismiss it with a reason.",
                    extra: ["id": .string(item.id)]))
            }
            let fence = opensForUser ? nil : await inboxFloor(item, action: action, dataRoot: self.inboxDataRoot)
            let peerSteered = CapabilityLifecycle.writeRefusal != nil
                || (PeerTurnEffectPolicy.isPeerBridge(surface: TurnEnvelope.current(surface: "").surface) && !PeerDataTaint.trustedTurn)
            if action == "approve", peerSteered, item.related_approval_id == nil {
                return refuse(AppToolExecutor.failure("owners_call",
                    "This inbox item has no owner-review approval record. A peer-steered turn cannot supply the person's consent.",
                    extra: ["remedy": Repair.why(owner: "inbox item \(item.id)", tap: "Today > \(item.title) > Approve")]))
            }
            // Two cards are a person's under Full Mac too: an executable keep
            // (approving admits the script as his) and a destructive call's (User,
            // 10-17: what cannot be undone on his side waits for a human's tap, one
            // card every time). Her own approve never stands in for his.
            if action == "approve", let approvalID = item.related_approval_id {
                let record: ApprovalRecord
                do { record = try await SwiftNativeApprovalInbox(root: self.inboxDataRoot).get(approvalID) }
                catch {
                    return refuse(AppToolExecutor.failure("approval_unavailable",
                        "workflows/approvals/requests.json card \(approvalID) could not be read: \(error.localizedDescription). No consent was supplied."))
                }
                let install = record.requiresExecutableReview
                if peerSteered,
                   !SwiftNativeApprovalInbox.ownerReviewActions.contains(record.action) {
                    return refuse(AppToolExecutor.failure("owners_call",
                        "Approval \(record.id) is \(record.action), not a review of your own work. A peer-steered turn cannot supply the person's consent.",
                        extra: ["remedy": Repair.why(owner: "workflows/approvals/requests.json card \(record.id)",
                            tap: "Today > \(record.title) > Approve")]))
                }
                if install || PermissionLaw.humanDecides(action: record.action, payload: record.payload) {
                    return refuse(AppToolExecutor.failure("owners_call",
                        "That's the owner's even under Full Mac: " + (install
                            ? "approving installs the script as theirs."
                            : "what this card would run cannot be undone on their side, so it waits for their tap.")
                        + " Leave it for them; inbox.withdraw takes back your ask.",
                        extra: ["id": .string(item.id), "action": .string(action)]))
                }
            }
            if !fullMac, let fence {
                return refuse(AppToolExecutor.failure("owners_call",
                    "That's the owner's — leave it for them (\(fence)). If it is stale, archive or dismiss it with a reason.",
                    extra: ["id": .string(item.id), "action": .string(action)]))
            }
            target.press = (item, action)
            target.decided = opensForUser || fence != nil
        }
        return .success(target)
    }

    public func quietInbox(verb: String, input: [String: JSONValue]) async -> JSONValue {
        let target: QuietInboxTarget
        switch await inboxGate(verb: verb, input: input) {
        case .failure(let refusal): return refusal.json
        case .success(let ready): target = ready
        }
        if verb == "list" {
            return inboxList(target.items, filter: Self.inboxText(input, "filter"), limit: input["limit"])
        }
        let (ids, byID) = (target.ids, target.byID)
        let selected = ids.compactMap { id in byID[id].map { (id: id, item: $0) } }

        switch verb {
        case "read":
            return .object(["status": .string("ok"), "notes": .array(selected.map { inboxRow($0.item, full: true) })])
        case "archive", "dismiss", "mark_read":
            let reason = String(Self.inboxText(input, "reason").prefix(280))
            let action = verb == "mark_read" ? "read" : verb
            var done: [JSONValue] = []
            var skipped: [JSONValue] = []
            for (id, item) in selected {
                // Reading is not un-archiving: mark_read leaves settled notes alone.
                if action == "read", !item.isActivityPending {
                    skipped.append(.object(["id": .string(id), "status": .string(item.status)]))
                    continue
                }
                do {
                    try await self.performInboxAction(id, action: action, metadata: [
                        "settled_by": .string("agent"), "settled_reason": .string(reason),
                    ], quiet: false, dataRootOverride: self.dataRootOverride)
                    done.append(.object(["id": .string(id), "was": .string(item.status)]))
                } catch {
                    await self.refreshInboxSurfaces()
                    return AppToolExecutor.failure("write_failed",
                        "\(error.localizedDescription) Nothing after \(id) was touched; retry with the ids not in done.",
                        extra: ["done": .array(done), "id": .string(id), "effects": .string(done.isEmpty ? "unknown" : "partial")])
                }
            }
            await self.refreshInboxSurfaces()
            // Read back what the inbox shows now: a producer can re-file a
            // card the moment it is settled, and ok must mean it stuck.
            let expected = action == "read" ? "read" : action == "archive" ? "archived" : "dismissed"
            let after = (try? await self.readInbox()) ?? []
            var unstuck: [String] = []
            done = done.map { row in
                guard case .object(var fields) = row, case .string(let id)? = fields["id"] else { return row }
                // Newest first, so the first row is the card on screen.
                let now = after.first { $0.id == id }?.status ?? "unreadable"
                fields["now"] = .string(now)
                if now != expected { unstuck.append(id) }
                return .object(fields)
            }
            var receipt: [String: JSONValue] = [
                "status": .string(unstuck.isEmpty ? "ok" : "did_not_stick"), "verb": .string(verb),
                "reason_given": .string(reason), "done": .array(done), "skipped_already_settled": .array(skipped),
            ]
            if !unstuck.isEmpty {
                receipt["ok"] = .bool(false)
                receipt["effects"] = .string("occurred")
                receipt["detail"] = .string("Written, but \(unstuck.joined(separator: ", ")) read back as not \(expected): "
                    + "the app re-filed the card as new right after (its producer raised it again), or the write "
                    + "missed the row on screen. See now on each; reading it again shows what is current.")
            }
            return .object(receipt)
        case "withdraw":
            let (approvalID, title) = target.approval!
            do {
                try await self.withdrawApproval(id: approvalID, decidedBy: "agent_withdraw")
            } catch {
                return AppToolExecutor.ownedFailure(error, code: "withdraw_failed", owner: "approval \(approvalID)",
                    instruction: "Read this approval note before another change; withdrawal was not verified.",
                    next: ["page": .string("inbox"), "item": .string(ids[0])], effects: .unknown)
            }
            await self.refreshInboxSurfaces()
            return .object(["status": .string("ok"), "verb": .string(verb), "id": .string(ids[0]),
                            "approval_id": .string(approvalID),
                            "detail": .string("Withdrew \(title). Nothing it asked for will run.")])
        default: // act, repair
            let (item, action) = target.press!
            do {
                try await self.performInboxAction(item.id, action: action, metadata: [:], quiet: true, dataRootOverride: self.dataRootOverride)
            } catch {
                return AppToolExecutor.ownedFailure(error, code: "inbox_act_failed", owner: "inbox \(item.id) action \(action)",
                    instruction: "Read this note's current state and resolve the reported cause before acting again.",
                    next: ["page": .string("inbox"), "item": .string(item.id)], effects: .unknown)
            }
            await self.refreshInboxSurfaces()
            if target.decided {
                HarnessDecidedRow.post(requester: "Full Mac", tool: "inbox.\(action)",
                                       sessionID: input["__session_id"]?.scalarText,
                                       dataRoot: self.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
            return .object(["status": .string("ok"), "id": .string(item.id), "action": .string(action),
                            "did": .string(self.inboxActDescription(item, action: action))])
        }
    }

    /// Needs you as Today and the Desk count it (`OwnerAttentionPolicy`).
    private func inboxNeedsYou(_ item: InboxItemRecord) -> Bool {
        item.requiresOwnerInput
    }

    private func inboxList(_ items: [InboxItemRecord], filter: String, limit: JSONValue?) -> JSONValue {
        let filter = filter.isEmpty ? "active" : filter.lowercased()
        let kept: [InboxItemRecord]
        switch filter {
        case "active": kept = items.filter { !inboxPresentation($0).hidden }
        case "unread": kept = items.filter { $0.normalizedStatus == "unread" }
        case "needs_you": kept = items.filter(inboxNeedsYou)
        case "all": kept = items
        default:
            return AppToolExecutor.failure("unknown_filter", "filter is active, unread, needs_you or all.")
        }
        let cap: Int
        switch limit {
        case .int(let n)?: cap = Int(n)
        case .double(let d)?: cap = d.isFinite ? Int(max(1, min(d, 200))) : 30
        default: cap = 30
        }
        let shown = kept.prefix(max(1, min(cap, 200)))
        return .object([
            "status": .string("ok"), "filter": .string(filter),
            "count": .int(Int64(kept.count)), "shown": .int(Int64(shown.count)),
            "needs_you_count": .int(Int64(items.filter(inboxNeedsYou).count)),
            "notes": .array(shown.map { inboxRow($0, full: false) }),
        ])
    }

    private func inboxRow(_ item: InboxItemRecord, full: Bool) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(item.id), "title": .string(item.title), "source": .string(item.source),
            "severity": .string(item.severity), "status": .string(item.status),
            "created_at": .string(item.created_at), "lane": .string(item.isSystemLane ? "system" : "for_you"),
            "needs_you": .bool(inboxNeedsYou(item)),
            "actions": .array(inboxPresentation(item).actions.map { .string("\($0.id): \($0.label)") }),
        ]
        if full {
            row["summary"] = .string(item.summary)
            row["detail"] = .string(String((item.detail ?? "").prefix(4_000)))
            if let readAt = item.read_at { row["read_at"] = .string(readAt) }
            if let approval = item.related_approval_id, !approval.isEmpty { row["approval_id"] = .string(approval) }
        } else {
            row["summary"] = .string(String(item.summary.prefix(160)))
        }
        return .object(row)
    }

    /// Why running `action` on this note is User's below Full Mac, or nil when it is hers.
    private func inboxFloor(_ item: InboxItemRecord, action: String, dataRoot: URL) async -> String? {
        guard item.source == self.interactionSource else {
            return ["approve", "reject"].contains(action) ? "it decides an approval" : nil
        }
        // "Not now" withdraws her own ask; it grants nothing.
        if action == "reject" { return nil }
        guard let card = await self.interactionForInboxItem(item.id, dataRoot: dataRoot) else {
            return "its card no longer reads, so what it would grant is unknown"
        }
        switch card.kind {
        case .permission: return "it grants a macOS permission"
        case .connector, .apiKey: return "it signs in"
        case .capability: return "it raises Trust"
        case .unknown: return "its card is a kind this build doesn't know"
        case .choose, .modelChoice:
            return action.hasPrefix("interaction_choice_") ? "it is his answer to give" : nil
        }
    }

}
