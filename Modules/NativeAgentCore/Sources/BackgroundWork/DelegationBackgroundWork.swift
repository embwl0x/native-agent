import Foundation
import AgentConversations
import BackgroundLoops
import ChatOrchestration
import Cognition
import NativeAgentCore
import NotificationInbox
import PersistenceCore
import Desk
import DeviceSync
import TelegramBot
import SlackBot

// MARK: - DelegationOutcomeLoop registration (W2b, upgrade campaign 2026-08)
//
// BackgroundWork joins the canonical projector to its durable terminal cursor
// and finding delivery. The app supplies platform effects.
//
// Codex unlinks a reply-job file once delivery succeeds, but the sibling
// reply-deliveries ledger durably preserves the terminal turn and bridge
// receipt. The projector joins that terminal half back to the exact originating
// message id, and this runner watches the ledger as part of the same lifecycle.

public struct DelegationBackgroundWork: Sendable {
    private let port: any DelegationBackgroundWorkPort

    public init(port: any DelegationBackgroundWorkPort) { self.port = port }

    fileprivate func reconcileClosedReplyFindings(dataRoot: URL, configRoot: URL) async throws {
        let closed = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items.filter {
            $0.project == HarnessQueue.project && $0.status.isTerminal && $0.closedAt != nil
                && ($0.findingKey?.hasPrefix("delivery-residue|") == true
                    || $0.findingKey?.hasPrefix("delivery-failed-before-answer|") == true)
        }
        guard !closed.isEmpty else { return }
        for item in closed {
            let ids = Set(item.refs.compactMap { ref -> String? in
                guard case .trace(let id, "reply_delivery") = ref.kind else { return nil }
                return id
            })
            if !ids.isEmpty {
                try await port.letGoReplies(deliveryIDs: ids, outcome: item.summary ?? "",
                    dataRoot: dataRoot, configRoot: configRoot)
            }
        }
    }

    private static func replyRefs(_ jobs: [DelegationJobProjection]) throws -> [DeskRef] {
        let ids = try jobs.map { job in
            guard let id = job.completionDeliveryID, !id.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return id
        }
        return Set(ids).sorted().map { DeskRef(refId: $0, kind: .trace(id: $0, kind: "reply_delivery")) }
    }

    private func fileFailedHumanReplies(dataRoot: URL) async throws {
        try await fileFailedReplies(TelegramUpdateInbox.failedReplyClaims(dataRoot: dataRoot),
            route: "telegram", destination: "on Telegram", legacyPrefixes: ["delivery-before-answer|telegram/"], dataRoot: dataRoot)
        try await fileFailedReplies(SlackInboundDeliveryJournal.failedReplyClaims(dataRoot: dataRoot), route: "slack", destination: "on Slack",
            legacyPrefixes: ["delivery-before-answer|slack/inbound_delivery_journal.json|"], dataRoot: dataRoot)
    }

    fileprivate func fileFailedIOSReplies(dataRoot: URL, deferral: DelegationDeferralState, changedPath: URL? = nil) async throws {
        let directory = dataRoot.appendingPathComponent("icloud/chat_transactions", isDirectory: true).standardizedFileURL
        if let changedPath, changedPath.deletingLastPathComponent().standardizedFileURL != directory { return }
        let claims = try iCloudBridge.failedReplyClaims(dataRoot: dataRoot, changedPath: changedPath)
        let failed = try await deferral.updateIOSFailures(claims, changedPath: changedPath)
        try await fileFailedReplies(failed, route: "ios", destination: "on iOS",
            legacyPrefixes: ["delivery-before-answer|icloud/chat_transactions/"], dataRoot: dataRoot)
    }

    private func fileFailedReplies(_ records: [(path: URL, at: String)], deliveryRefs: [DeskRef] = [], route: String, destination: String,
                                   legacyPrefixes: [String], dataRoot: URL) async throws {
        let key = "delivery-failed-before-answer|" + route
        guard !records.isEmpty else {
            let note = "No replies \(destination) remain failed before an answer."
            try await HarnessQueue.resolve(key: key, note: note, dataRoot: dataRoot)
            try await HarnessQueue.resolve(keyPrefixes: Dictionary(uniqueKeysWithValues: legacyPrefixes.map { ($0, note) }), dataRoot: dataRoot)
            return
        }
        var ordered: [(path: URL, date: Date)] = try records.map { record in
            guard let date = DeskClock.parseISO(record.at) else { throw CocoaError(.fileReadCorruptFile) }
            return (path: record.path, date: date)
        }
        ordered.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.path.path < rhs.path.path }
            return lhs.date > rhs.date
        }
        var seen = Set<URL>()
        let refs = deliveryRefs + ordered.filter { seen.insert($0.path).inserted }.prefix(12).map {
            DeskRef(refId: $0.path.path, kind: .file(path: $0.path.path, line: nil, label: nil))
        }
        let title = "Replies \(destination) failed before an answer"
        _ = try await HarnessQueue.file(HarnessFinding(key: key, title: title,
            summary: "\(records.count) replies \(destination) failed before an answer (\(DeskClock.dayStamp(ordered.last!.date)) – \(DeskClock.dayStamp(ordered.first!.date))) — inspect or let go",
            owner: .agent, refs: refs, source: .loop), dataRoot: dataRoot, refreshRefs: true)
        try await HarnessQueue.fold(keyPrefixes: legacyPrefixes, into: title, dataRoot: dataRoot)
    }

    func retitleSavedDecisions(dataRoot: URL) async throws {
        let marker = dataRoot.appendingPathComponent("agents/decided-principals-migrated.json")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let path = LiveNotificationInbox.livePath(dataRoot: dataRoot)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let lines = try InboxRewriteGuard.readLines(path)
            guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: path) else { throw CocoaError(.fileReadCorruptFile) }
            let rewritten = try lines.map { line -> Data in
                guard case .object(var fields)? = line.row, fields["source"] == .string("harness_decided"),
                      case .string(let id)? = fields["id"], case .string(let title)? = fields["title"],
                      let peer = peers.first(where: { id.hasPrefix("harness_decided.peer:" + $0.id + ".") }) else { return line.raw }
                fields["title"] = .string(title.replacingOccurrences(of: "peer:" + peer.id, with: peer.name))
                fields["principal"] = .object(["peerID": .string(peer.id), "displayName": .string(peer.name)])
                return try JSONValue.object(fields).serializedData(pretty: false)
            }
            try InboxRewriteGuard.writeLines(rewritten, to: path)
        }
        try await persistence.writeJSON(.bool(true), to: marker)
    }


    /// Reacts to bridge-store changes. Routine successful outcomes share one
    /// bounded informational rollup per source; failed/unconfirmed outcomes
    /// share one actionable summary per source. Cursor lives at
    /// `<dataRoot>/logs/delegation_outcome_cursor.json`.
    ///
    /// `configRoot` mirrors `SwiftToolDispatcher.agentBridgeConfigRoot`. When it
    /// is nil the store follows the injected `dataRoot` and this install's
    /// ownership of the machine-wide rendezvous
    /// (`NativeAgentPaths.bridgeConfigRoot(dataRoot:)`), so a fresh root — or a
    /// secondary copy of the app — never counts another install's replies.
    /// Same derivation as `BackgroundLoopsAssembly+Heartbeat`'s preserved-reply
    /// sweep, which reads this very store.
    public func makeDelegationOutcomeLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configRoot: URL? = nil
    ) -> some EventDeadlineLoopRunner {
        let root = configRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let deferral = DelegationDeferralState()
        let underlying = DelegationOutcomeLoop(
            // Normal reconciliation is event-driven. Six hours is only the
            // missed-vnode/restart integrity sweep.
            interval: 6 * 60 * 60,
            cursorPath: DelegationOutcomeLoop.defaultCursorPath(dataRoot: dataRoot),
            readJobsWithAvailability: {
                do { try await fileFailedHumanReplies(dataRoot: dataRoot) }
                catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                // The default (20) is a chat-tool display budget. A loop that
                // only ever looked at the newest 20
                // rows could step over a terminal job during a busy window and
                // never card it — the cursor would then advance past it.
                //
                // 2026-09-06: the availability half rides along from the SAME
                // read, so an unreadable job file holds the cursor instead of
                // disappearing into an empty-looking store.
                // `root`, not `configRoot`: passing the nil straight through let
                // the projector re-resolve it to `~/.config` and count a
                // different root's jobs on the Today surface.
                let read = DelegationStatusProjector(configRoot: root, dataRoot: dataRoot)
                    .allJobsWithAvailability(now: Date())
                let jobs = read.jobs.map(Self.delegationJobSnapshot)
                if read.allStoresReadable {
                    do {
                        _ = try await LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
                            .archiveActive(ids: ["delegation-outcome:codex:undelivered-backlog"], readAt: DeskClock.nowISO())
                        try await reconcileAdverseRollups(dataRoot: dataRoot, jobs: jobs)
                    }
                    catch { nativeLog("Delegation rollup reconciliation failed: %@", error.localizedDescription) }
                    let contacts = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
                    for peer in Set(read.jobs.map(\.agent)).union(["codex", "omp", "claude"]).sorted() {
                        let owed = read.jobs.filter { $0.agent == peer && $0.replyOwed }
                        let key = "delivery-residue|" + peer
                        if owed.isEmpty {
                            try? await HarnessQueue.resolve(key: key, note: "No saved answers remain owed.", dataRoot: dataRoot)
                        } else {
                            // The contact's own name, the one agent.contacts shows, never a reshaped id.
                            let id = peer.hasPrefix("peer:") ? String(peer.dropFirst(5)) : peer
                            let name = contacts.first { $0.id == id }?.name ?? DelegationOutcomeCard.displayName(source: peer, agent: peer)
                            _ = try? await HarnessQueue.file(HarnessFinding(key: key,
                                title: "Replies owed to " + name,
                                summary: "\(owed.count) saved replies to \(name) remain owed: the call that asked for each can no longer take it. "
                                    + "Wait on one with desk.wait {handle, on: <its id on this item>}, or let it go with repair.let_go {id, reason}.",
                                owner: .agent, refs: try Self.replyRefs(owed), source: .loop), dataRoot: dataRoot, refreshRefs: true)
                        }
                        do {
                            let failedJobs = read.jobs.filter { $0.agent == peer && $0.deliveryOutcome == "failed_before_answer" }
                            let failed = try failedJobs.map { job in
                                guard let path = job.recoveryNote, let at = job.completedAt else { throw CocoaError(.fileReadCorruptFile) }
                                return (path: URL(fileURLWithPath: path), at: at)
                            }
                            try await fileFailedReplies(failed, deliveryRefs: Self.replyRefs(failedJobs), route: peer,
                                destination: "to " + DelegationOutcomeCard.displayName(source: peer, agent: peer),
                                legacyPrefixes: ["delivery-before-answer|\(peer)|"], dataRoot: dataRoot)
                        } catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                    }
                }
                // Feed the already-owned event read to Workspace bookmarks.
                // Their file event exposes arrivals without Agent opening each
                // conversation first. No additional polling or provider work.
                if read.allStoresReadable {
                    do { try AgentConversationStore(dataRoot: dataRoot).reconcileDelegationReplies(read.jobs) }
                    catch {
                        FileHandle.standardError.write(Data(
                            "DelegationOutcomeLoop: conversation reply projection failed: \(error.localizedDescription)\n".utf8))
                    }
                }
                // Her notice lands only on a matching open row she started
                // (AgentConversationStore.noteDelegationEvent); anything else
                // keeps the person's push. Unreadable rows count as none.
                let rows = (try? AgentConversationStore(dataRoot: dataRoot).records()) ?? []
                return DelegationJobsRead(
                    jobs: jobs.map { snapshot in
                        var job = snapshot
                        job.reachesHer = rows.contains { conversation in
                            guard conversation.agent == job.agent, conversation.personInitiated != true,
                                  ["waiting", "attention", "ready"].contains(conversation.phase),
                                  case .string(let id)? = conversation.readInput?["message_id"] else { return false }
                            return job.acceptedMessageIDs.contains(id)
                        }
                        return job
                    },
                    allStoresReadable: read.allStoresReadable
                )
            },
            fileCard: { card, read in
                await fileDelegationOutcomeNotice(dataRoot: dataRoot, card: card, read: read)
            },
            observeTransition: { job in
                if dataRoot.standardizedFileURL
                    == PersistenceCore.defaultDataRoot().standardizedFileURL {
                    let owners = job.agent == "codex" && !job.acceptedMessageIDs.isEmpty
                        ? job.acceptedMessageIDs : [job.motorOwnerID ?? job.id]
                    for owner in owners {
                        var action = job
                        action.motorOwnerID = owner
                        await port.observeMotorActionState(action.motorActionReadModel())
                    }
                }
                // Her turn in the chat she delegated from, not only User's card.
                do {
                    try AgentConversationStore(dataRoot: dataRoot).noteDelegationEvent(
                        agent: job.agent, messageIDs: job.acceptedMessageIDs
                    ) { row in
                        // A stall matters only while the answer is still owed; a
                        // terminal outcome may already have settled the thread
                        // as ready (an unconfirmed or lost delivery still is news).
                        guard row.phase == "waiting" || job.isTerminal else { return nil }
                        return DelegationOutcomeCard.residentNotice(from: job, conversation: row.label)
                            .map { AgentConversationNotice(event: $0.event, text: $0.text) }
                    }
                } catch {
                    FileHandle.standardError.write(Data(("DelegationOutcomeLoop: conversation notice failed "
                        + "for \(job.source):\(job.id): \(error.localizedDescription)\n").utf8))
                    return false
                }
                // A failed wake her notice will not carry (it went back down the
                // channel that failed, or to the caller): an arrival in her own runtime.
                if job.terminalOutcome == .failed,
                   !job.reachesHer || DelegationOutcomeCard.residentNotice(from: job, conversation: "") == nil {
                    let name = DelegationOutcomeCard.displayName(source: job.source, agent: job.agent)
                    let head = (job.agentReplyTextHead ?? job.completionTextHead)?
                        .split(whereSeparator: \.isNewline).first.map { String($0.prefix(140)) }
                    let signIn = head.map { AgentLocalHealth.authenticationFailure(.string($0)) } == true
                    let word = job.runStatus ?? job.status ?? "failed"
                    var line = "\(name)'s wake failed" + (word == "failed" ? "" : " (\(word))")
                    if signIn { line += ": its sign-in failed or expired" } else if let head { line += ": \"\(head)\"" }
                    ResidentWake.shared.request(dataRoot: dataRoot, reason: "what resolved", items: [.init(
                        id: "wake-failed:\(job.source):\(job.id)", line: line, thread: "wake:" + job.agent,
                        agent: signIn || head == nil ? nil : job.agent, home: true)])
                }
                return await recordBoundDelegationSettlement(dataRoot: dataRoot, job: job)
            },
            reportDeferral: { deferred in await deferral.record(deferred) },
            readHandledOutcomes: {
                let inbox = LiveNotificationInbox.livePath(dataRoot: dataRoot)
                var handled = Set<String>()
                for path in [inbox, LiveNotificationInbox.archivePath(forInbox: inbox)] {
                    let lines = try InboxRewriteGuard.readLines(path)
                    guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: path),
                          lines.allSatisfy({ line in
                              if line.raw.isEmpty { return true }
                              if case .object? = line.row { return true }
                              return false
                          }) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    for line in lines {
                        guard case .object(let row)? = line.row,
                              row["source"] == .string("delegation_outcome") else { continue }
                        if case .string(let signature)? = row["error_signature"] { handled.insert(signature) }
                        if case .array(let occurrences)? = row["absorbed_occurrence_ids"] {
                            for case .string(let id) in occurrences where id.hasPrefix("delegation-outcome:") {
                                handled.insert("\(id.dropFirst("delegation-outcome:".count)):succeeded")
                            }
                        }
                        if case .array(let jobs)? = row["adverse_jobs"] {
                            for case .string(let job) in jobs {
                                let parts = job.split(separator: "|", maxSplits: 1)
                                if parts.count == 2 { handled.insert("\(parts[1]):\(parts[0])") }
                            }
                        }
                    }
                }
                return handled
            }
        )
        return DelegationOutcomeEventRunner(
            underlying: underlying,
            work: self,
            port: port,
            dataRoot: dataRoot,
            configRoot: root,
            deferral: deferral,
            watchedPaths: [
                root.appendingPathComponent("codex-nativeagent-bridge/reply-jobs", isDirectory: true),
                root.appendingPathComponent("codex-nativeagent-bridge/reply-jobs/undelivered", isDirectory: true),
                root.appendingPathComponent("codex-nativeagent-bridge/reply-deliveries.jsonl"),
                root.appendingPathComponent("omp-bridge/wake-jobs", isDirectory: true),
                AgentConversationStore(dataRoot: dataRoot).fileURL,
                dataRoot.appendingPathComponent("bots/run-queue.json"),
                dataRoot.appendingPathComponent("bots/shelf-index.json"),
                // A new arrival books her wake (ResidentWake.nextDeadline).
                ResidentWake.url(dataRoot),
                // A queued step or a met condition books the tick that offers it.
                dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
                dataRoot.appendingPathComponent("icloud/chat_delivery_receipts.jsonl"),
                root.appendingPathComponent("claude-bridge/codex-completion-lifecycle", isDirectory: true),
                dataRoot.appendingPathComponent("agent-conversations/codex-completion-lifecycle", isDirectory: true),
                dataRoot.appendingPathComponent("chat/anchor-mirror/codex-completion-lifecycle", isDirectory: true),
                dataRoot.appendingPathComponent("chat/human-reply-delivery/codex-completion-lifecycle", isDirectory: true),
                dataRoot.appendingPathComponent("slack/inbound_delivery_journal.json"),
            ]
        )
    }

    /// Field-for-field passthrough. No re-derivation lives here on purpose: if
    /// this function ever started deciding anything, the loop's tests would stop
    /// covering what production actually does.
    public static func delegationJobSnapshot(from row: DelegationJobProjection) -> DelegationJobSnapshot {
        DelegationJobSnapshot(
            id: row.id,
            motorOwnerID: row.motorOwnerID,
            source: row.source,
            agent: row.agent,
            topicSlug: row.topicSlug,
            state: row.state,
            status: row.status,
            runStatus: row.runStatus,
            completedAt: row.completedAt,
            deliveryOutcome: row.deliveryOutcome,
            deliveryReceiptVersion: row.deliveryReceiptVersion,
            deliveryLost: row.deliveryLost,
            completionTextHead: row.completionTextHead,
            recoveryNote: row.recoveryNote,
            deskHandle: row.deskHandle,
            stalled: row.stalled,
            stallBasis: row.stallBasis.rawValue,
            lastLiveness: row.lastLiveness,
            agentReplyTextHead: row.agentReplyTextHead,
            acceptedMessageIDs: row.acceptedMessageIDs.sorted()
        )
    }

    /// Settle terminal delegated work back onto the exact Desk item selected
    /// when it was sent. This is execution/delivery evidence only: it never
    /// closes the item or promotes an unverified agent answer into task proof.
    public func recordBoundDelegationSettlement(
        dataRoot: URL,
        job: DelegationJobSnapshot
    ) async -> Bool {
        guard job.isTerminal, let handle = job.deskHandle else { return true }
        let marker = "delegation-settlement:\(job.source):\(job.id)"
        let run = job.runStatus ?? job.status ?? job.terminalOutcome?.rawValue ?? "unknown"
        let delivery = job.deliveryOutcome ?? "unreported"
        let completed = job.completedAt ?? "timestamp unavailable"
        let note = "\(marker) — \(job.agent) run \(run); delivery \(delivery); completed \(completed). "
            + "Execution/delivery evidence only; \(port.agentSubject) must still assess the result against the request."
        do {
            _ = try await SwiftNativeDeskStore(dataRoot: dataRoot).appendNoteIfAbsent(
                handle,
                marker: marker,
                text: note
            )
            return true
        } catch DeskError.unknownHandle {
            // The item was archived between delegation and settlement. There
            // is no live Desk target to update, and retrying forever would pin
            // the outcome cursor behind an impossible write.
            return true
        } catch {
            // 2026-09-06: the loop already retries on `false`, but the reason
            // used to die here. A settlement that keeps failing is now both
            // retried AND nameable from the log next to the failed tick.
            FileHandle.standardError.write(Data(("DelegationOutcomeLoop: Desk settlement failed "
                + "for \(job.source):\(job.id) on \(handle): \(error)\n").utf8))
            return false
        }
    }

    // MARK: - Inbox upsert

    /// Upsert one delegation-outcome card, then knock for the attention-worthy
    /// ones. Returns whether the row landed — a `false` keeps the job out of the
    /// loop's cursor so the next tick retries.
    ///
    /// Sticky by the same contract as `fileLoopFailureNotice`: the card carries
    /// its job key in `error_signature`, and a row already marked read/archived
    /// for that SAME key keeps the user's status instead of resurrecting as
    /// unread. In practice the loop never re-files a carded job at all — this is
    /// the second belt, for the case where a cursor is lost or reset.
    // Internal (not private) so the sticky-status contract test can drive the
    // real write path.
    public func fileDelegationOutcomeNotice(
        dataRoot: URL,
        card: DelegationOutcomeCard,
        read: DelegationJobsRead
    ) async -> Bool {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let row = card.toJSON()

        // Routine successful delegations are useful recent activity, but one
        // unread row per job turned the notification surface into a completion
        // ledger (406 live unread cards in the 2026-08-29 audit). Keep exactly
        // one active informational rollup per bridge source. Failed, unknown,
        // delivery-lost and resolved/stall cards retain their exact
        // per-job identity and sticky upgrade semantics below.
        if card.outcome == .succeeded, card.severity == "info", !card.resolved,
           case .object(var rollupRow) = row {
            let rollupID = "delegation-outcome:\(card.source):successful-rollup"
            let rollupKey = "delegation_outcome.successful.\(card.source)"
            rollupRow["id"] = .string(rollupID)
            rollupRow["error_signature"] = .string(rollupKey)
            do {
                _ = try await LiveNotificationInbox(path: inboxPath)
                    .appendOrRollUpInformational(
                        .object(rollupRow),
                        id: rollupID,
                        rollupKey: rollupKey,
                        // `rollupID` is ONE stable id shared by every write to
                        // this card, so it cannot tell a new job from a retry of
                        // the last one. The per-job card id is the occurrence
                        // identity: a job counted once is never counted twice,
                        // and a genuinely new job still bumps the rollup.
                        occurrenceID: card.cardId
                    )
                return true
            } catch {
                FileHandle.standardError.write(Data(
                    "DelegationOutcomeLoop: success rollup failed for \(card.cardId): \(error)\n".utf8))
                return false
            }
        }

        // 2026-09-22: every failed/unconfirmed job posted its own actionable
        // card and push (135 "needs you" cards, mostly Codex). A terminal job
        // outcome now folds into one summary per agent; stall
        // cards (whose ids are not `delegation-outcome:<jobKey>`) keep theirs.
        if card.outcome == .failed || card.outcome == .unknown, !card.resolved,
           card.severityOverride == nil, card.cardId == "delegation-outcome:\(card.jobKey)" {
            guard read.allStoresReadable else { return false }
            return await fileAdverseDelegationRollup(inboxPath: inboxPath, dataRoot: dataRoot, card: card, jobs: read.jobs)
        }

        let persistence = SwiftNativePersistenceCore()
        do {
            let inserted = try await persistence.withFileLock(inboxPath) { () async throws -> Bool? in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("DelegationOutcomeLoop", path: inboxPath)
                    return nil
                }
                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count + 1)
                var found = false
                var pushWorthy = true
                for line in lines {
                    guard case .object(let obj)? = line.row,
                          case .string(let id)? = obj["id"],
                          id == card.cardId else {
                        // Other rows AND undecodable lines: verbatim.
                        mutated.append(line.raw)
                        continue
                    }
                    var replacement = row
                    // The signature names job AND outcome. A row carrying the
                    // bare job key is a legacy card (pre outcome-signature); it
                    // counts as the same outcome ONLY when its severity agrees
                    // with the new card's (info ⇔ succeeded, actionable ⇔ the
                    // rest) — the cheapest proxy the legacy row offers. A
                    // legacy "finished" row met by an "unconfirmed" upsert is an
                    // upgrade and must resurface (gpt-5.5 round 2, MED); a
                    // legacy row retried under the same outcome must not.
                    let signatureMatches: Bool = {
                        guard case .string(let old)? = obj["error_signature"] else { return false }
                        if old == card.signature { return true }
                        guard old == card.jobKey else { return false }
                        if case .string(let oldSeverity)? = obj["severity"] {
                            return oldSeverity == card.severity
                        }
                        return false
                    }()
                    if signatureMatches,
                       case .string(let oldStatus)? = obj["status"],
                       oldStatus != "unread",
                       case .object(var newObj) = row {
                        newObj["status"] = obj["status"] ?? .string("unread")
                        newObj["read_at"] = obj["read_at"] ?? .null
                        replacement = .object(newObj)
                    }
                    // The durable card id is also the push identity. If the
                    // inbox row already exists WITH THE SAME SIGNATURE, a lost
                    // cursor write may retry the upsert but must never send a
                    // second push. A CHANGED signature is new information —
                    // the job's outcome worsened (finished → unconfirmed)
                    // and lands as a fresh unread row that
                    // may push (the severity gate downstream still applies).
                    pushWorthy = !signatureMatches
                    mutated.append(Data(try replacement.serialize(pretty: false).utf8))
                    found = true
                }
                if !found { mutated.append(Data(try row.serialize(pretty: false).utf8)) }
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
                return pushWorthy
            }
            // A refused rewrite is NOT a delivered card: report false so the
            // loop retries rather than marking the job handled.
            guard let shouldPush = inserted else { return false }
            if shouldPush {
                await port.notifyIfAttentionWorthy(
                    dataRoot: dataRoot,
                    itemId: card.cardId,
                    title: card.title,
                    summary: String(card.summary.prefix(500)),
                    source: "delegation_outcome",
                    severity: card.severity
                )
            }
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "DelegationOutcomeLoop: card upsert failed for \(card.cardId): \(error)\n".utf8))
            return false
        }
    }

    /// One actionable summary card per bridge source for failed and unconfirmed
    /// jobs ("Codex: 26 failed, 11 unconfirmed"), carrying the latest job's
    /// detail. The card remembers `outcome|jobKey` entries, so a retried upsert
    /// counts once and a job whose outcome worsens moves between the counts.
    /// It pushes only when it becomes unread; further outcomes while it is
    /// still unread just move the counts.
    private func fileAdverseDelegationRollup(
        inboxPath: URL,
        dataRoot: URL,
        card: DelegationOutcomeCard,
        jobs: [DelegationJobSnapshot]
    ) async -> Bool {
        let rollupID = "delegation-outcome:\(card.source):adverse-rollup"
        let name = DelegationOutcomeCard.displayName(source: card.source, agent: card.agent)
        let persistence = SwiftNativePersistenceCore()
        do {
            // nil = refused rewrite; .some(nil) = landed, no push.
            let landed = try await persistence.withFileLock(inboxPath) {
                () async throws -> (title: String, summary: String)?? in
                let lines = try InboxRewriteGuard.readLines(inboxPath)
                guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: inboxPath) else {
                    InboxRewriteGuard.refuse("DelegationOutcomeLoop", path: inboxPath)
                    return nil
                }
                func isActive(_ obj: [String: JSONValue]) -> Bool {
                    guard case .string(let status)? = obj["status"] else { return true }
                    return status != "archived" && status != "dismissed"
                }
                var existing: [String: JSONValue]?
                for line in lines {
                    if case .object(let obj)? = line.row, case .string(rollupID)? = obj["id"] {
                        if isActive(obj) { existing = obj }
                    }
                }
                let (entries, counts) = Self.adverseDelegationRollup(source: card.source, jobs: jobs)
                guard !entries.isEmpty else { return .some(nil) }
                let title = "\(name): \(counts)"
                // The push router dedupes on id + summary, and the id never
                // changes: counts and the outcome time identify the new fact.
                let summary = "\(counts). Latest (\(card.createdAt)): \(card.summary)"

                guard case .object(var obj) = card.toJSON() else { return nil }
                obj["id"] = .string(rollupID)
                obj["title"] = .string(title)
                obj["summary"] = .string(String(summary.prefix(500)))
                obj["detail"] = .string(String(("Latest: \(card.title)\n\(card.detail)").prefix(2_000)))
                obj["error_signature"] = .string("delegation_outcome.adverse.\(card.source)")
                obj["adverse_jobs"] = .array(entries.map(JSONValue.string))
                obj["first_created_at"] = existing?["first_created_at"] ?? existing?["created_at"] ?? obj["created_at"]
                let wasUnread = existing.map { ($0["status"] ?? .string("unread")) == .string("unread") } ?? false
                let row = JSONValue.object(obj)

                var mutated: [Data] = []
                mutated.reserveCapacity(lines.count + 1)
                for line in lines {
                    guard case .object(var other)? = line.row, case .string(let id)? = other["id"] else {
                        mutated.append(line.raw)
                        continue
                    }
                    // The old summary moves to the newest position; the job's own
                    // per-job row (a stall warning or a legacy card) is superseded.
                    if id == rollupID, isActive(other) { continue }
                    if id == card.cardId, isActive(other) {
                        other["status"] = .string("archived")
                        other["read_at"] = .string(card.createdAt)
                        mutated.append(Data(try JSONValue.object(other).serialize(pretty: false).utf8))
                        continue
                    }
                    mutated.append(line.raw)
                }
                mutated.append(Data(try row.serialize(pretty: false).utf8))
                try InboxRewriteGuard.writeLines(mutated, to: inboxPath)
                return wasUnread ? .some(nil) : .some((title, summary))
            }
            guard let landed else { return false }
            if let push = landed {
                await port.notifyIfAttentionWorthy(
                    dataRoot: dataRoot,
                    itemId: rollupID,
                    title: push.title,
                    summary: String(push.summary.prefix(500)),
                    source: "delegation_outcome",
                    severity: card.severity
                )
            }
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "DelegationOutcomeLoop: adverse rollup failed for \(card.cardId): \(error)\n".utf8))
            return false
        }
    }

    private static func adverseDelegationRollup(source: String, jobs: [DelegationJobSnapshot]) -> (entries: [String], counts: String) {
        let entries = jobs.compactMap { job -> String? in
            guard job.source == source,
                  !["owed", "sent_unconfirmed", "failed_before_answer", "legacy_before_receipts"].contains(job.deliveryOutcome ?? ""),
                  let outcome = job.terminalOutcome, outcome == .failed || outcome == .unknown else { return nil }
            return "\(outcome.rawValue)|\(job.source):\(job.id)"
        }.sorted()
        let unconfirmed = entries.filter { $0.hasPrefix("\(DelegationOutcome.unknown.rawValue)|") }.count
        let failed = entries.count - unconfirmed
        let legacy = jobs.filter { $0.source == source && $0.deliveryOutcome == "legacy_before_receipts" }.count
        let counts = [failed > 0 ? "\(failed) failed" : nil, unconfirmed > 0 ? "\(unconfirmed) unconfirmed" : nil,
                      legacy > 0 ? "\(legacy) legacy jobs before receipts; nothing to settle" : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return (entries, counts)
    }

    private func reconcileAdverseRollups(dataRoot: URL, jobs: [DelegationJobSnapshot]) async throws {
        let path = LiveNotificationInbox.livePath(dataRoot: dataRoot)
        let persistence = SwiftNativePersistenceCore()
        try await persistence.withFileLock(path) {
            let lines = try InboxRewriteGuard.readLines(path)
            guard InboxRewriteGuard.rewriteIsSafe(lines: lines, path: path) else { throw CocoaError(.fileReadCorruptFile) }
            var changed = false
            let rewritten = try lines.map { line -> Data in
                guard case .object(var fields)? = line.row, case .string(let id)? = fields["id"],
                      id.hasPrefix("delegation-outcome:"), id.hasSuffix(":adverse-rollup"),
                      fields["status"] != .string("archived"), fields["status"] != .string("dismissed") else { return line.raw }
                let source = String(id.dropFirst("delegation-outcome:".count).dropLast(":adverse-rollup".count))
                let (entries, counts) = Self.adverseDelegationRollup(source: source, jobs: jobs)
                let summary = counts.isEmpty ? "Reply outcomes reconciled." : counts
                let title = DelegationOutcomeCard.displayName(source: source, agent: source) + ": " + summary
                guard fields["adverse_jobs"] != .array(entries.map(JSONValue.string)) || fields["title"] != .string(title) else { return line.raw }
                changed = true
                fields["adverse_jobs"] = .array(entries.map(JSONValue.string))
                fields["title"] = .string(title)
                fields["summary"] = .string(summary)
                if entries.isEmpty {
                    fields["status"] = .string("archived")
                    fields["detail"] = .string(summary)
                }
                return try JSONValue.object(fields).serializedData(pretty: false)
            }
            if changed { try InboxRewriteGuard.writeLines(rewritten, to: path) }
        }
    }

    /// Archives per-job failed/unconfirmed/lost cards older than seven days, written
    /// before those outcomes moved into the per-agent summary. Stall
    /// and summary cards do not match.
    public func reconcileStaleAdverseDelegationNotices(
        dataRoot: URL,
        now: Date = Date()
    ) async throws -> Int {
        let inbox = LiveNotificationInbox(path: LiveNotificationInbox.livePath(dataRoot: dataRoot))
        let prefix = "delegation-outcome:"
        let ids = try await inbox.rows().compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string("delegation_outcome")? = object["source"],
                  case .string("actionable")? = object["severity"],
                  case .string(let id)? = object["id"], id.hasPrefix(prefix),
                  case .string(let signature)? = object["error_signature"]
            else { return nil }
            let jobKey = String(id.dropFirst(prefix.count))
            let adverse = [jobKey, "\(jobKey):\(DelegationOutcome.failed.rawValue)",
                           "\(jobKey):\(DelegationOutcome.unknown.rawValue)",
                           "\(jobKey):\(DelegationOutcome.deliveryLost.rawValue)"]
            return adverse.contains(signature) ? id : nil
        }
        return try await inbox.archiveActive(
            ids: ids,
            readAt: DelegationOutcomeCursor.formatISO(now),
            createdNoLaterThan: now.addingTimeInterval(-7 * 86_400)
        )
    }

    /// Retires the unread per-job success cards written before successful
    /// delegations moved to one bounded rollup per bridge source. Exact adverse
    /// outcomes, current rollups, and already-handled history do
    /// not match this migration.
    public func reconcileLegacySuccessfulDelegationNotices(
        dataRoot: URL,
        now: Date = Date()
    ) async throws -> Int {
        let inboxPath = LiveNotificationInbox.livePath(dataRoot: dataRoot)
        let inbox = LiveNotificationInbox(path: inboxPath)
        let prefix = "delegation-outcome:"
        let legacyIDs = try await inbox.rows().compactMap { row -> String? in
            guard case .object(let object) = row,
                  case .string("delegation_outcome")? = object["source"],
                  case .string("info")? = object["severity"],
                  case .string("unread")? = object["status"],
                  object["informational_rollup_key"] == nil,
                  case .string(let id)? = object["id"], id.hasPrefix(prefix),
                  case .string(let title)? = object["title"], title.hasSuffix(" finished"),
                  case .string(let signature)? = object["error_signature"]
            else { return nil }
            let jobKey = String(id.dropFirst(prefix.count))
            guard signature == jobKey || signature == "\(jobKey):succeeded" else { return nil }
            return id
        }
        return try await inbox.archiveUnreadInformational(
            ids: legacyIDs,
            readAt: DelegationOutcomeCursor.formatISO(now)
        )
    }
}

/// Whether the last tick left outcomes unsettled. Written by the loop's
/// deferral report, read by the runner's deadline projection.
actor DelegationDeferralState {
    private var deferred = false
    private var replyReconciliationPending = true
    private var iosFailures: [URL: String] = [:]
    private var iosFailuresLoaded = false
    func updateIOSFailures(_ claims: [(path: URL, at: String)], changedPath: URL?) throws -> [(path: URL, at: String)] {
        guard changedPath == nil || iosFailuresLoaded else { throw CocoaError(.fileReadUnknown) }
        if let changedPath { iosFailures.removeValue(forKey: changedPath.standardizedFileURL) }
        else { iosFailures.removeAll() }
        for claim in claims { iosFailures[claim.path.standardizedFileURL] = claim.at }
        iosFailuresLoaded = true
        return iosFailures.map { (path: $0.key, at: $0.value) }
    }
    func requestReplyReconciliation() { replyReconciliationPending = true }
    func takeReplyReconciliation() -> Bool {
        defer { replyReconciliationPending = false }
        return replyReconciliationPending
    }
    func record(_ value: Bool) { deferred = value }
    var hasDeferredWork: Bool { deferred }
}

private struct DelegationOutcomeEventRunner: EventDeadlineLoopRunner {
    let underlying: DelegationOutcomeLoop
    let work: DelegationBackgroundWork
    let port: any DelegationBackgroundWorkPort
    let dataRoot: URL
    let configRoot: URL
    let deferral: DelegationDeferralState
    let watchedPaths: [URL]

    /// How soon a tick that deferred outcomes comes back. Short enough that the
    /// remainder of a burst lands while the user is still in the same sitting,
    /// long enough that a permanently failing settlement cannot spin.
    static let deferredRerunGap: TimeInterval = 60

    var loopId: String { underlying.loopId }
    var interval: TimeInterval { underlying.interval }
    // One delayed peer continuation may include a full resident chat turn.
    // The manager still owns single-flight execution and cancellation.
    var tickTimeoutOverride: TimeInterval? { 600 }

    func tickOutcome() async -> LoopTickOutcome {
        do { try await work.reconcileClosedReplyFindings(dataRoot: dataRoot, configRoot: configRoot) }
        catch { return .failed(error: "Reply let-go settlement failed: \(error.localizedDescription). Repair the reply or Desk records before reconciliation.") }
        if await deferral.takeReplyReconciliation() {
            do { try await port.reconcileReplyDeliveries(dataRoot: dataRoot) }
            catch {
                await deferral.requestReplyReconciliation()
                return .failed(error: "Reply reconciliation failed: \(error.localizedDescription)")
            }
        }
        do {
            try await work.retitleSavedDecisions(dataRoot: dataRoot)
            let archived = try await work
                .reconcileLegacySuccessfulDelegationNotices(dataRoot: dataRoot)
                + work.reconcileStaleAdverseDelegationNotices(dataRoot: dataRoot)
            if archived > 0 {
                FileHandle.standardError.write(Data(
                    "DelegationOutcomeLoop: archived \(archived) legacy delegation cards\n".utf8
                ))
            }
        } catch {
            // Outcome delivery remains available if historical inbox cleanup
            // fails; the idempotent reconciliation retries on the next event or
            // six-hour integrity tick.
            FileHandle.standardError.write(Data(
                "DelegationOutcomeLoop: legacy success reconciliation failed: \(error)\n".utf8
            ))
        }
        let outcome = await underlying.tickOutcome()
        do { try await port.retryRequestedResults(dataRoot: dataRoot) }
        catch { return .failed(error: "Requested result notifications could not be reconciled: \(error.localizedDescription)") }
        do {
            try await port.reconcileAgentConversations()
        } catch is CancellationError {
            return .skipped(reason: "Delegation reply handling cancelled", healthNeutral: true)
        } catch {
            return .failed(error: "Saved agent conversations could not be reconciled: \(error.localizedDescription)")
        }
        return outcome
    }

    func physiologyEvents() -> AsyncStream<Void> {
        let deliveryPaths = watchedPaths.filter {
            $0.path.contains("codex-nativeagent-bridge/") || $0.path.contains("omp-bridge/")
                || $0.path.contains("codex-completion-lifecycle") || $0.path.contains("/slack/")
                || $0.path.contains("/telegram/") || $0.path.contains("/icloud/")
        }
        let ordinaryPaths = watchedPaths.filter { !deliveryPaths.contains($0) }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let journalChanges = StoreChangeBus.shared.changes()
            let routes = EventDeadlinePhysiology.storeAndFileEvents(
                paths: [dataRoot.appendingPathComponent("chat/sessions.json"), dataRoot.appendingPathComponent("user_prefs.json")],
                notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange])
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        do { try await work.fileFailedIOSReplies(dataRoot: dataRoot, deferral: deferral) }
                        catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                        for await change in journalChanges where change.store == .replyDelivery
                            && change.path.standardizedFileURL.path.hasPrefix(dataRoot.standardizedFileURL.path + "/") {
                            do { try await work.fileFailedIOSReplies(dataRoot: dataRoot, deferral: deferral, changedPath: change.path) }
                            catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                            await deferral.requestReplyReconciliation()
                            continuation.yield(())
                        }
                    }
                    group.addTask {
                        for await _ in port.storeAndFileEvents(paths: deliveryPaths, loopId: nil) {
                            await deferral.requestReplyReconciliation()
                            continuation.yield(())
                        }
                    }
                    group.addTask {
                        for await _ in port.storeAndFileEvents(paths: ordinaryPaths, loopId: nil) { continuation.yield(()) }
                    }
                    group.addTask {
                        await ResidentWake.shared.routesChanged(dataRoot: dataRoot)
                        for await _ in routes {
                            await ResidentWake.shared.routesChanged(dataRoot: dataRoot)
                            await deferral.requestReplyReconciliation()
                            continuation.yield(())
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let stall = DelegationStatusProjector(configRoot: configRoot, dataRoot: dataRoot)
            .nextStallDeadline(after: now)
        // 2026-09-06: the ten-card cap and contiguous settlement leave real
        // work behind, and nothing in the store changes when they do — so the
        // remainder used to wait for the next bridge write or the six-hour
        // integrity sweep. A deferring tick books its own continuation.
        let conversation = port.nextConversationDeadline(after: now)
        var quietEnd: Date?
        if let window = TurnQuietHoursWindow.read(dataRoot: dataRoot),
           window.contains(hour: Calendar.current.component(.hour, from: now)) {
            quietEnd = window.end(after: now)
            // The existing saved-delivery pass runs at this exact crossing.
            await deferral.requestReplyReconciliation()
        }
        let deadline = [stall, conversation, quietEnd].compactMap { $0 }.min()
        guard await deferral.hasDeferredWork else { return deadline }
        let rerun = now.addingTimeInterval(Self.deferredRerunGap)
        guard let deadline else { return rerun }
        return min(deadline, rerun)
    }
}
