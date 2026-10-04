import ApprovalInbox
import Connectors
import ProviderRouting
import AppToolRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
import ChatOrchestration
import Desk
import NotificationInbox

@MainActor final class AppQuietToolHost: AppQuietSettingsHost, QuietToolHost {
    var activeChatSessionId: String { appModel.activeChatSessionId }
    func pageRead(_ page: QuietToolPage) async -> (content: [JSONValue], rows: [JSONValue], truncated: Bool) {
        // The presentation port resolved this value from the same immutable page catalog.
        let read = await QuietSelfAdminRender.pageRead(for: QuietPages.page(named: page.id)!, appModel: appModel)
        return (read.content, read.rows, read.truncated)
    }
    func composerState(sessionId: String) async -> [String: JSONValue] {
        await QuietComposerVerbs.state(appModel: appModel, sessionId: sessionId)
    }
    func runComposer(
        verb: String, value: String, choice: String, sessionId: String, attachments: [URL], reachesUser: Bool,
        turnSessionId: String
    ) async -> QuietComposerOutcome {
        let outcome = await QuietComposerVerbs.run(
            verb: verb, value: value, choice: choice, sessionId: sessionId,
            attachments: attachments, reachesUser: reachesUser, turnSessionId: turnSessionId, appModel: appModel
        )
        return QuietComposerOutcome(changed: outcome.changed, element: outcome.element, detail: outcome.detail, refusal: outcome.refusal)
    }
    func runChatSession(verb: String, input: [String: JSONValue], reachesUser: Bool) async -> JSONValue {
        await QuietChatSessionVerbs.run(verb: verb, input: input, reachesUser: reachesUser, appModel: appModel)
    }
    func composerFence(verb: String, value: String, sessionId: String, reachesUser: Bool, turnSessionId: String)
        -> QuietComposerOutcome? {
        QuietComposerVerbs.fence(verb: verb, value: value, sessionId: sessionId, reachesUser: reachesUser,
                                 turnSessionId: turnSessionId, appModel: appModel).refusal
            .map { QuietComposerOutcome(changed: false, element: $0.element, detail: $0.detail, refusal: $0.refusal) }
    }
    func chatSessionFence(verb: String, input: [String: JSONValue], reachesUser: Bool) -> JSONValue? {
        if case .failure(let refusal) = QuietChatSessionVerbs.fence(verb: verb, input: input, reachesUser: reachesUser, appModel: appModel) {
            return refusal.json
        }
        return nil
    }
    func saveProviderKey(_ key: String, provider: String) async -> QuietProviderKeyOutcome {
        let outcome = await InlineConnectorSetup.saveProviderKey(key, provider: provider, appModel: appModel)
        return QuietProviderKeyOutcome(error: outcome.error, note: outcome.note)
    }
    /// Each verb is the button's own call: Doctor's support report,
    /// Capabilities' Export, Trust's Back up now, the embedding download row,
    /// Setup's Release now and the Memories page's upkeep row.
    func runUpkeep(verb: String, input: [String: JSONValue]) async -> (ok: Bool, detail: String, fields: [String: JSONValue]) {
        let retry = " Read \(AppToolExecutor.doorDoctor) to see what is wrong, then try again."
        switch verb {
        case "support_report":
            switch await appModel.loadSupportDiagnostics() {
            case .loaded(let report, _):
                return (true, "Support report: \(report.app) \(report.version), health \(report.doctorStatus ?? "unknown"), made \(report.generatedAt).",
                        ["report": (try? JSONValue.fromEncodable(report)) ?? .null])
            case .unavailable(let detail): return (false, detail, [:])
            case .failed(let detail): return (false, "Support report failed: \(detail)." + retry, [:])
            }
        case "export_bundle":
            let support = input["support"] == .bool(true)
            switch await appModel.createProductionExport(support: support) {
            case .verified(let export):
                return (true, "\(support ? "Support bundle" : "Export") created and verified at \(export.path).",
                        ["path": .string(export.path), "id": .string(export.id), "size_bytes": .int(Int64(export.sizeBytes ?? 0))])
            case .failed(_, let detail): return (false, "\(support ? "Support bundle" : "Export") failed: \(detail)." + retry, [:])
            }
        case "backup_now":
            let backup = await appModel.createBackup(reason: "upkeep backup_now")
            return backup.map { (true, appModel.statusText, ["id": .string($0.id), "created_at": .string($0.createdAt)]) }
                ?? (false, appModel.statusText + " Check free disk space, then try again.", [:])
        case "embeddings_pause":
            let download = EmbeddingModelDownloadController.shared
            guard download.status.running else {
                return (true, "Nothing to pause: the memory-search model is not downloading (\(download.status.phase)).", ["changed": .bool(false)])
            }
            download.cancel()
            return (true, "Paused the memory-search model download. embeddings_resume picks it up where it stopped.", ["changed": .bool(true)])
        case "embeddings_resume":
            let download = EmbeddingModelDownloadController.shared
            guard !download.status.running, !download.activating else {
                return (true, "Already running: \(download.status.phase).", ["changed": .bool(false)])
            }
            download.start(createOnly: false, reconcile: true)
            return (true, "Checking and resuming the memory-search model download. \(AppToolExecutor.doorDoctor) shows its progress.", ["changed": .bool(true)])
        case "embeddings_release":
            do {
                let result = try await appModel.releaseEmbeddingsMemory()
                if result.ok == false {
                    return (false, (result.error ?? "Embedding memory release could not be confirmed.") + retry, [:])
                }
                return (true, result.detail ?? "Released the memory-search model's memory; it loads again on the next search.", [:])
            } catch {
                return (false, "Release failed: \(error.localizedDescription)." + retry, [:])
            }
        case "spotlight_reindex":
            let outcome = await MemorySpotlightReindexOperation.run(dataRoot: appModel.dataRootOverride ?? NativeAgentPaths.dataRoot)
            if case .indexed = outcome { return (true, outcome.userMessage, [:]) }
            return (false, outcome.userMessage, [:])
        case "consolidate_now", "hygiene_now":
            let feedback = verb == "consolidate_now" ? await appModel.consolidateMemory() : await appModel.runMemoryHygiene()
            return (!feedback.isAdverse, feedback.message, [:])
        // User's two below Full Mac; the door refuses them there.
        case "backup_restore":
            let id = AppToolExecutor.inputString(input["id"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let backups = try? await appModel.engine.trust.listBackups() { appModel.engine.trust.backups = backups }
            guard let backup = appModel.engine.trust.backups.first(where: { $0.id == id }) else {
                return (false, "No backup has id \(id.isEmpty ? "(none passed)" : id). Pass id, one of these.",
                        ["backups": .array(appModel.engine.trust.backups.prefix(8).map {
                            .object(["id": .string($0.id), "reason": .string($0.reason), "created_at": .string($0.createdAt),
                                     "scope": .array($0.scope.map(JSONValue.string))])
                        })])
            }
            await appModel.restoreBackup(backup)
            guard !appModel.statusText.hasPrefix("Restore failed") else { return (false, appModel.statusText + retry, [:]) }
            // Awaited: a restore that stages restarts the app once this turn ends.
            _ = await HarnessDecidedRow.record(requester: "Full Mac", tool: "backup.restore \(backup.id)",
                                               sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                               dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            return (true, appModel.statusText, ["id": .string(backup.id)])
        case "activity_wipe":
            let activity = ActivityWatchController.shared
            let removed: Int
            switch await activity.wipeAll() {
            case .deleted(let rows): removed = rows
            case .failed(let message):
                return (false, message + " Deletion could not be confirmed." + retry, [:])
            }
            HarnessDecidedRow.post(requester: "Full Mac", tool: "history.clear",
                                   sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            return (true, "Deleted all recorded activity (\(removed) spans). Recording settings are kept, "
                + "so if capture is on it keeps going.", ["removed_rows": .int(Int64(removed))])
        default:
            return (false, "No upkeep button is called \(verb).", [:])
        }
    }
}

/// The agent's own hands on a card (card.answer): every settle is `byAgent`.
@MainActor struct AppToolInteractionResolver: ToolInteractionResolving {
    func interaction(id: String, sessionID: String, dataRoot: URL) async -> InlineInteraction? {
        await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
    }
    func sessionID(ofCard id: String, dataRoot: URL) async -> String? {
        try? await InteractionCardDelivery.pointer(id: "interaction:\(id)", dataRoot: dataRoot).sessionID
    }
    func originEnvelope(of id: String, sessionID: String, dataRoot: URL) async -> TurnEnvelope? {
        await InlineInteractionResolver.originEnvelope(of: id, sessionID: sessionID, dataRoot: dataRoot)
    }
    func descriptor(for interaction: InlineInteraction, dataRoot: URL) -> InlineInteractionDescriptor {
        InlineInteractionResolver.descriptor(for: interaction, dataRoot: dataRoot)
    }
    func begin(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.begin(id: id, sessionID: sessionID, expectedRevision: expectedRevision, byAgent: true, dataRoot: dataRoot)
    }
    func decline(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.decline(id: id, sessionID: sessionID, expectedRevision: expectedRevision, dataRoot: dataRoot)
    }
    func returnToPending(_ interaction: InlineInteraction, sessionID: String, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.returnToPending(interaction, sessionID: sessionID, dataRoot: dataRoot)
    }
    func complete(id: String, sessionID: String, selection: String?, scope: InlineInteraction.Scope?, expectedRevision: Int?, attribution: String?, setupError: String?, note: String?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.complete(id: id, sessionID: sessionID, selection: selection, scope: scope, expectedRevision: expectedRevision, attribution: attribution, setupError: setupError, note: note, byAgent: true, dataRoot: dataRoot)
    }
    func takeContinuationHandBack(id: String) -> String? {
        InlineInteractionResolver.takeContinuationHandBack(id: id)
    }
    func cardFields(_ interaction: InlineInteraction, descriptor: InlineInteractionDescriptor) -> [String: JSONValue] {
        let card = InlineCardProjection.model(interaction, descriptor: descriptor)
        return [
                "title": .string(card.title),
                "state": .string(card.state.rawValue),
                "why": .string(card.why),
                "primary": .string(card.primaryLabel),
                "secondary": .string(card.secondaryLabel),
                "scope_lines": .array(card.scopeLines.map { .string($0) }),
                "outcome": card.outcome.map { JSONValue.string($0) } ?? .null,
                "outcome_meta": card.outcomeMeta.map { JSONValue.string($0) } ?? .null,
                "can_retry": .bool(card.canRetry),
                "revision": .int(Int64(interaction.revision)),
            ]
    }
    func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        InlineInteractionResolver.receiptEnvelope(interaction)
    }
    func liveOutcomeSummary(_ interaction: InlineInteraction, dataRoot: URL) async -> String? {
        await InlineInteractionResolver.liveProjection(interaction, dataRoot: dataRoot).state.outcome?.summary
    }
    func saveConnectorToken(_ value: String, connector: String, dataRoot: URL) async -> String? {
            let result: OAuthFlowResult
            switch connector {
            case "notion": result = await NativeOAuthFlow.saveNotionToken(value, dataRoot: dataRoot)
            case "github": result = await NativeOAuthFlow.saveGitHubToken(value, dataRoot: dataRoot, credentialStore: AppGitHubOAuthCredentials())
            default: result = OAuthFlowResult(ok: false, error: "No token route for \(connector).")
            }
            if !result.ok {
                return InlineConnectorSetup.failureReason(
                    result.error ?? "",
                    service: InlineInteractionRegistry.connectorDisplayName(connector, dataRoot: dataRoot),
                    typed: [value]
                )
            }
        return nil
    }
}

// MARK: - inbox

/// The `inbox` tool over the Inbox page's own reads and `inboxAction`, so a
/// note she settles leaves Today, the Desk and the phone exactly as a tap does.
extension AppQuietToolHost {
    /// What an inbox verb acts on once nothing refuses it.
    private struct InboxTarget {
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

    private struct InboxRefusal: Error { let json: JSONValue }

    /// Every check that refuses an inbox verb before anything is written:
    /// the ids, a reason to put a note away, withdrawing only her own
    /// pending ask, and below Full Mac a note's button that is User's (a
    /// permission or capability card, an approval). Reads only, so the
    /// door's preview asks it too and refuses what the real call would.
    func inboxFence(verb: String, input: [String: JSONValue]) async -> JSONValue? {
        if case .failure(let refusal) = await inboxGate(verb: verb, input: input) { return refusal.json }
        return nil
    }

    private static func inboxText(_ input: [String: JSONValue], _ key: String) -> String {
        AppToolExecutor.inputString(input[key])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func inboxGate(verb: String, input: [String: JSONValue]) async -> Result<InboxTarget, InboxRefusal> {
        func refuse(_ json: JSONValue) -> Result<InboxTarget, InboxRefusal> { .failure(InboxRefusal(json: json)) }
        func text(_ key: String) -> String { Self.inboxText(input, key) }
        let items: [InboxItemRecord]
        do { items = try await appModel.engine.inbox.list() } catch {
            return refuse(AppToolExecutor.failure("inbox_unreadable",
                "The inbox didn't read (\(error.localizedDescription)). Try again; read \(AppToolExecutor.doorDoctor) if it keeps failing."))
        }
        var target = InboxTarget(items: items)
        if verb == "list" { return .success(target) }

        var ids = [text("id")].filter { !$0.isEmpty }
        if case .array(let many)? = input["ids"] {
            ids += many.compactMap { AppToolExecutor.inputString($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard !ids.isEmpty else {
            return refuse(AppToolExecutor.failure("missing_id", "Pass id (or ids). app {page:\"inbox\"} lists them."))
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let unknown = ids.first(where: { byID[$0] == nil }) {
            return refuse(AppToolExecutor.failure("unknown_id",
                "No note has id \(unknown). Read app {page:\"inbox\"} for the current ids.", extra: ["id": .string(unknown)]))
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
            // Agent, 2026-10-01: withdrawing her own pending ask is hers;
            // answering another agent's is User's.
            guard ids.count == 1, let approvalID = byID[ids[0]]?.related_approval_id, !approvalID.isEmpty else {
                return refuse(AppToolExecutor.failure("no_approval",
                    "That note carries no approval. withdraw takes one note whose read shows approval_id."))
            }
            let root = appModel.dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()
            guard let record = try? await SwiftNativeApprovalInbox(root: root).get(approvalID) else {
                return refuse(AppToolExecutor.failure("approval_unreadable",
                    "Approval \(approvalID) didn't read, so nothing was withdrawn. Try again; read \(AppToolExecutor.doorDoctor) if it keeps failing."))
            }
            guard record.status == "pending" else {
                return refuse(AppToolExecutor.failure("not_pending",
                    "That approval is \(record.status), not waiting, so there is nothing to withdraw. Archive the note with a reason if it is stale."))
            }
            if case .object(let payload) = record.payload, payload["peer_id"] != nil {
                return refuse(AppToolExecutor.failure("users_call",
                    "That approval is another agent's ask, not yours, so answering it is User's. Leave it for him."))
            }
            target.approval = (approvalID, record.title)
        default: // act, repair, not_now
            guard ids.count == 1, let item = byID[ids[0]] else {
                return refuse(AppToolExecutor.failure("one_id", "\(verb) takes one id."))
            }
            let actionIDs = item.effectiveActions.map { $0.id == "deny" ? "reject" : $0.id }
            // A note's buttons in the words its read shows (inbox.not_now, inbox.open_on_mac · User's).
            let shown = item.effectiveActions.compactMap { AppToolExecutor.noteButton(id: $0.id, label: $0.label) }
            // A card's Not now is inbox.not_now, its warning on its line; never a bare reject.
            let requested = verb == "repair" ? "repair" : verb == "not_now" ? "reject" : text("action").lowercased()
            if verb == "act", item.source == InteractionCardDelivery.source, ["reject", "deny"].contains(requested) {
                return refuse(AppToolExecutor.failure("use_not_now",
                    "A card's Not now is its own action: \(AppActions.action("inbox.not_now")?.line ?? "inbox.not_now"). "
                    + "Nothing was done.", extra: ["actions": .array(shown.map { .string($0) })]))
            }
            let action = requested.isEmpty
                ? actionIDs.first(where: { ["act", "open_approvals", "repair"].contains($0) }) ?? ""
                : (requested == "deny" ? "reject" : requested)
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
            // User, 10-02: under Full Mac his buttons are hers too.
            let fullMac = await AppToolExecutor.freshQuietPosture(
                dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())?.name == AppToolExecutor.fullMacModeName
            let opensForUser = item.source == InteractionCardDelivery.source && action == "act"
            if !fullMac, opensForUser {
                return refuse(AppToolExecutor.failure("opens_for_user",
                    "That card's Open on Mac only opens it for User at the Mac (inbox.open_on_mac is User's). inbox.not_now declines it; if it is stale, inbox.archive or inbox.dismiss it with a reason.",
                    extra: ["id": .string(item.id)]))
            }
            let fence = opensForUser ? nil : await Self.inboxFloor(item, action: action, dataRoot: appModel.engine.inbox.dataRoot)
            // A skill script's Install card is User's under Full Mac too: approving admits the script as his.
            if action == "approve", let approvalID = item.related_approval_id, (try? await SwiftNativeApprovalInbox(
                root: appModel.dataRootOverride ?? SwiftNativeApprovalInbox.defaultDataRoot()).get(approvalID))?.action
                == SwiftNativeApprovalInbox.skillScriptInstallAction {
                return refuse(AppToolExecutor.failure("users_call",
                    "That's User's even under Full Mac: approving installs the script as his. Leave it for him; "
                    + "inbox.withdraw takes back your ask.", extra: ["id": .string(item.id), "action": .string(action)]))
            }
            if !fullMac, let fence {
                return refuse(AppToolExecutor.failure("users_call",
                    "That's User's — leave it for him (\(fence)). If it is stale, archive or dismiss it with a reason.",
                    extra: ["id": .string(item.id), "action": .string(action)]))
            }
            target.press = (item, action)
            target.decided = opensForUser || fence != nil
        }
        return .success(target)
    }

    func inbox(verb: String, input: [String: JSONValue]) async -> JSONValue {
        let target: InboxTarget
        switch await inboxGate(verb: verb, input: input) {
        case .failure(let refusal): return refusal.json
        case .success(let ready): target = ready
        }
        if verb == "list" {
            return Self.inboxList(target.items, filter: Self.inboxText(input, "filter"), limit: input["limit"])
        }
        let (ids, byID) = (target.ids, target.byID)

        switch verb {
        case "read":
            return .object(["status": .string("ok"), "notes": .array(ids.map { Self.inboxRow(byID[$0]!, full: true) })])
        case "archive", "dismiss", "mark_read":
            let reason = String(Self.inboxText(input, "reason").prefix(280))
            let action = verb == "mark_read" ? "read" : verb
            var done: [JSONValue] = []
            var skipped: [JSONValue] = []
            for id in ids {
                // Reading is not un-archiving: mark_read leaves settled notes alone.
                if action == "read", !byID[id]!.isActivityPending {
                    skipped.append(.object(["id": .string(id), "status": .string(byID[id]!.status)]))
                    continue
                }
                do {
                    try await appModel.client.inboxAction(id, action: action, metadata: [
                        "settled_by": .string("agent"), "settled_reason": .string(reason),
                    ])
                    done.append(.object(["id": .string(id), "was": .string(byID[id]!.status)]))
                } catch {
                    await refreshInboxSurfaces()
                    return AppToolExecutor.failure("write_failed",
                        "\(error.localizedDescription) Nothing after \(id) was touched; retry with the ids not in done.",
                        extra: ["done": .array(done), "id": .string(id)])
                }
            }
            await refreshInboxSurfaces()
            // Read back what the inbox shows now: a producer can re-file a
            // card the moment it is settled, and ok must mean it stuck.
            let expected = action == "read" ? "read" : action == "archive" ? "archived" : "dismissed"
            let after = (try? await appModel.engine.inbox.list()) ?? []
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
                _ = try await appModel.client.resolveApproval(
                    id: approvalID, decision: "cancel", provenance: .local(decidedBy: "agent_withdraw"))
            } catch {
                return AppToolExecutor.failure("withdraw_failed",
                    "\(error.localizedDescription) The approval is unchanged; read the note again, then retry.")
            }
            await refreshInboxSurfaces()
            return .object(["status": .string("ok"), "verb": .string(verb), "id": .string(ids[0]),
                            "approval_id": .string(approvalID),
                            "detail": .string("Withdrew \(title). Nothing it asked for will run.")])
        default: // act, repair
            let (item, action) = target.press!
            do {
                try await appModel.client.inboxAction(item.id, action: action, quiet: true)
            } catch {
                return AppToolExecutor.failure("act_failed", error.localizedDescription,
                    extra: ["id": .string(item.id), "action": .string(action)])
            }
            await refreshInboxSurfaces()
            if target.decided {
                HarnessDecidedRow.post(requester: "Full Mac", tool: "inbox.\(action)",
                                       sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                       dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            }
            return .object(["status": .string("ok"), "id": .string(item.id), "action": .string(action),
                            "did": .string(Self.inboxActDescription(item, action: action))])
        }
    }

    private func refreshInboxSurfaces() async {
        _ = await appModel.refreshForSidebarItem(.activity)
        await NativeAgentEngine.liveDeviceSync.engine.writeSnapshots()
    }

    /// Needs you as Today and the Desk count it (`OwnerAttentionPolicy`).
    private static func inboxNeedsYou(_ item: InboxItemRecord) -> Bool {
        OwnerAttentionPolicy.inboxAsks(pending: item.isActivityPending, systemLane: item.isSystemLane,
            severity: item.severity, linkedApproval: item.hasLinkedApproval, actionIDs: item.actions.map(\.id))
    }

    private static func inboxList(_ items: [InboxItemRecord], filter: String, limit: JSONValue?) -> JSONValue {
        let filter = filter.isEmpty ? "active" : filter.lowercased()
        let kept: [InboxItemRecord]
        switch filter {
        case "active": kept = items.filter { !$0.isHiddenFromDefaultInbox }
        case "unread": kept = items.filter(\.isUnread)
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

    private static func inboxRow(_ item: InboxItemRecord, full: Bool) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(item.id), "title": .string(item.title), "source": .string(item.source),
            "severity": .string(item.severity), "status": .string(item.status),
            "created_at": .string(item.created_at), "lane": .string(item.isSystemLane ? "system" : "for_you"),
            "needs_you": .bool(inboxNeedsYou(item)),
            "actions": .array(item.effectiveActions.map { .string("\($0.id): \($0.label)") }),
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
    private static func inboxFloor(_ item: InboxItemRecord, action: String, dataRoot: URL) async -> String? {
        guard item.source == InteractionCardDelivery.source else {
            return ["approve", "reject"].contains(action) ? "it decides an approval" : nil
        }
        // "Not now" withdraws her own ask; it grants nothing.
        if action == "reject" { return nil }
        guard let pointer = try? await InteractionCardDelivery.pointer(id: item.id, dataRoot: dataRoot),
              let card = await InlineInteractionResolver.interaction(
                id: pointer.interactionID, sessionID: pointer.sessionID, dataRoot: dataRoot) else {
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

    private static func inboxActDescription(_ item: InboxItemRecord, action: String) -> String {
        if action == "repair" { return "Repaired and archived the note." }
        if item.source == InteractionCardDelivery.source {
            switch action {
            case "reject", "deny": return "Declined the card (Not now)."
            case "act": return "Opened the card's conversation on the Mac."
            default: return "Selected the card's choice: \(item.effectiveActions.first { $0.id == action }?.label ?? action)."
            }
        }
        switch NativeClient.resolveInboxPrimaryAction(for: item) {
        case .openApprovals: return "Marked the note read; its approvals wait on the Approvals page. User's screen was not moved."
        case .openDeskExecution: return "Marked the note read; its work is on the Desk. User's screen was not moved."
        case .chatDraft: return "Marked the note read. Its action only drafts a chat message for User, so nothing was put in his composer."
        case .chatSpoken: return "Posted the note into chat as your message and marked it read. User's screen was not moved."
        case .diskCleanup: return "Moved the disk offenders to the Trash; the note now shows the result."
        case .unresolved(let reason): return reason
        }
    }
}

// MARK: - provider

/// The `provider` tool over the Providers page's own calls: the account list,
/// the account sheet's Test the connection, the page's Refresh, and the
/// sheet's Save with only "Model it falls back to" changed — no key, and the
/// sign-in method the sheet itself would keep.
extension AppQuietToolHost {
    func provider(verb: String, input: [String: JSONValue]) async -> JSONValue {
        let retry = " Try again; read \(AppToolExecutor.doorDoctor) if it keeps failing."
        if verb == "refresh_models" {
            switch await ProviderSettingsRefreshAction.perform(appModel: appModel, refreshCatalog: true) {
            case .loaded(let snapshot):
                _ = await appModel.loadProvidersForChat()
                return .object([
                    "status": .string("ok"),
                    "detail": .string("Fetched every account's model list again, as the page's Refresh does."),
                    "accounts": .array(snapshot.providers.map(providerRow)),
                ])
            case .failed(let detail):
                return AppToolExecutor.failure("refresh_failed", "The model lists did not refresh: \(detail)." + retry)
            }
        }
        let accounts: [ProviderInfo]
        do { accounts = try await appModel.engine.providers.list() } catch {
            return AppToolExecutor.failure("providers_unreadable", "The accounts didn't read (\(error.localizedDescription))." + retry)
        }
        if verb == "list" {
            return .object(["status": .string("ok"), "accounts": .array(accounts.map(providerRow))])
        }
        let id = AppToolExecutor.inputString(input["provider"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let account = accounts.first(where: { $0.provider_id == id }) else {
            return AppToolExecutor.failure(
                "unknown_provider",
                (id.isEmpty ? "Pass provider" : "No account has id \(id)") + ". app {page:\"providers\"} lists them.",
                extra: ["providers": .array(accounts.map { .string($0.provider_id) })])
        }
        let name = account.display_name
        switch verb {
        case "test":
            let result: NativeAgentShared.ProviderTestResult
            do { result = try await appModel.testProvider(id) } catch {
                return AppToolExecutor.failure("test_failed", "The test of \(name) could not run: \(error.localizedDescription)." + retry)
            }
            let works = result.tested && result.status == "ok"
            let problem = NativeAppSecretRedactor.redactText(result.error ?? result.detail ?? result.status)
            let detail = works
                ? "\(name) works: it answered\(result.model_used.map { " on \($0)" } ?? "")."
                : result.tested
                    ? "\(name) did not work: \(problem). A rejected key or expired sign-in is User's to fix: ask him to reconnect \(name) in Providers."
                    : "\(name) has no connection test, so nothing was checked. \(result.detail ?? "")"
            var body: [String: JSONValue] = [
                "status": .string("ok"), "provider": .string(id), "tested": .bool(result.tested),
                // Untested is unknown, not broken.
                "works": result.tested ? .bool(works) : .null, "detail": .string(detail),
            ]
            if let model = result.model_used { body["model_used"] = .string(model) }
            return .object(body)
        case "set_default_model":
            guard account.auth_status.state == "ready" else {
                return AppToolExecutor.failure(
                    "not_connected",
                    "\(name) is not connected, so it has no fallback model to set. Connecting it is User's: ask him to sign in on Providers.")
            }
            let offered = account.models.map(\.id)
            guard !offered.isEmpty else {
                return AppToolExecutor.failure(
                    "no_model_list",
                    "\(name)'s model list isn't loaded, so there is nothing to choose from. Run provider.refresh, then try again.")
            }
            let model = AppToolExecutor.inputString(input["model"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard offered.contains(model) else {
                return AppToolExecutor.failure(
                    "bad_model",
                    (model.isEmpty ? "Pass model" : "\(model) is not a model \(name) offers")
                        + ". It takes one of: \(offered.joined(separator: ", ")).")
            }
            // The sheet's own picker state: the saved sign-in method, kept.
            let mode = ProviderAuthModePickerPresentation.resolve(
                advertisedModes: account.auth_modes,
                savedMode: account.auth_mode,
                providerIsReady: true
            )
            guard mode.canSave else {
                return AppToolExecutor.failure(
                    "sign_in_method_unclear",
                    "\(name)'s saved sign-in method isn't one its sheet can keep, so nothing was changed. That's User's: ask him to open \(name) in Providers.")
            }
            let old = account.default_model ?? ""
            do {
                _ = try await appModel.configureProvider(id, apiKey: nil, authMode: mode.selectedMode, defaultModel: model)
            } catch {
                return AppToolExecutor.failure("save_failed", "\(name)'s fallback model was not saved: \(error.localizedDescription)." + retry)
            }
            _ = await appModel.loadProvidersForChat()
            return .object([
                "status": .string("ok"), "provider": .string(id), "changed": .bool(old != model),
                "old_value": .string(old), "new_value": .string(model),
                "detail": .string("\(name) now falls back to \(model) wherever no other model is chosen for it."),
            ])
        case "disconnect":
            // The sheet's Remove the key. User's below Full Mac; the door
            // refuses it there.
            let outcome = await appModel.disconnectProvider(id)
            guard outcome.ok else {
                return AppToolExecutor.failure("disconnect_failed",
                    "\(outcome.detail) app {page:\"providers\"} shows where \(name) stands.", extra: ["provider": .string(id)])
            }
            HarnessDecidedRow.post(requester: "Full Mac", tool: "provider.disconnect \(id)",
                                   sessionID: AppToolExecutor.inputString(input["__session_id"]),
                                   dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
            return .object(["status": .string("ok"), "provider": .string(id), "changed": .bool(true),
                            "detail": .string("\(name) is disconnected. \(outcome.detail) Signing back in is User's.")])
        default:
            return AppToolExecutor.failure("unknown_verb", "No provider verb is called \(verb).")
        }
    }

    /// An account whose last test failed for the key it has now (a rejected
    /// key) is not connected, as its line on the page says.
    private func providerRow(_ account: ProviderInfo) -> JSONValue {
        let failed = LLMProviderStatusFeed.failedTest(providerID: account.provider_id,
                                                      dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
        var row: [String: JSONValue] = [
            "id": .string(account.provider_id),
            "name": .string(account.display_name),
            "connected": .bool(account.auth_status.state == "ready" && failed != "key rejected"),
            "fallback_model": .string(account.default_model ?? ""),
            "models": .array(account.models.map { .string($0.id) }),
        ]
        if let note = account.models_note { row["models_note"] = .string(note) }
        if let failed { row["last_test_failed"] = .string(failed) }
        return .object(row)
    }
}
