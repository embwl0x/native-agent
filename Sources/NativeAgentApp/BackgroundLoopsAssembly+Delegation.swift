import Foundation
import BackgroundLoops
import ChatOrchestration
import NativeAgentCore
import NotificationInbox
import PersistenceCore

// MARK: - DelegationOutcomeLoop registration (W2b, upgrade campaign 2026-08)
//
// The two halves this file joins deliberately live apart:
//
//   • `DelegationStatusProjector` (ChatOrchestration) owns READING the bridge
//     wake-job stores. It is the same reader `delegation_status` uses, so the
//     tool and the cards can never disagree about what a record says.
//   • `DelegationOutcomeLoop` (BackgroundLoops) owns the CURSOR, the terminal
//     classification, and the card text. It knows nothing about ChatOrchestration.
//
// Only the app layer imports both, so only the app layer can wire them — which
// is exactly why this factory exists rather than a module dependency edge.
//
// Codex unlinks a reply-job file once delivery succeeds, but the sibling
// reply-deliveries ledger durably preserves the terminal turn and bridge
// receipt. The projector joins that terminal half back to the exact originating
// message id, and this runner watches the ledger as part of the same lifecycle.

extension BackgroundLoopsAssembly {

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
    static func makeDelegationOutcomeLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configRoot: URL? = nil
    ) -> some EventDeadlineLoopRunner {
        let root = configRoot ?? NativeAgentPaths.bridgeConfigRoot(dataRoot: dataRoot)
        let deferral = DelegationDeferralState()
        let underlying = DelegationOutcomeLoop(
            // Normal reconciliation is event-driven. Six hours is only the
            // missed-vnode/restart integrity sweep.
            interval: 6 * 60 * 60,
            cursorPath: DelegationOutcomeLoop.defaultCursorPath(dataRoot: dataRoot),
            readJobsWithAvailability: {
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
                let read = DelegationStatusProjector(configRoot: root)
                    .allJobsWithAvailability(now: Date())
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
                return DelegationJobsRead(
                    jobs: read.jobs.map(delegationJobSnapshot(from:)),
                    allStoresReadable: read.allStoresReadable
                )
            },
            fileCard: { card in
                await fileDelegationOutcomeNotice(dataRoot: dataRoot, card: card)
            },
            observeTransition: { job in
                if dataRoot.standardizedFileURL
                    == PersistenceCore.defaultDataRoot().standardizedFileURL {
                    await NativeCognitionRuntime.shared.observeMotorActionState(
                        job.motorActionReadModel()
                    )
                }
                return await recordBoundDelegationSettlement(dataRoot: dataRoot, job: job)
            },
            reportDeferral: { deferred in await deferral.record(deferred) }
        )
        return DelegationOutcomeEventRunner(
            underlying: underlying,
            dataRoot: dataRoot,
            configRoot: root,
            deferral: deferral,
            watchedPaths: [
                root.appendingPathComponent("claude-bridge/wake-jobs", isDirectory: true),
                root.appendingPathComponent("codex-nativeagent-bridge/reply-jobs", isDirectory: true),
                root.appendingPathComponent("codex-nativeagent-bridge/reply-jobs/undelivered", isDirectory: true),
                root.appendingPathComponent("codex-nativeagent-bridge/reply-deliveries.jsonl"),
                root.appendingPathComponent("omp-bridge/wake-jobs", isDirectory: true),
                AgentConversationStore(dataRoot: dataRoot).fileURL,
                dataRoot.appendingPathComponent("bots/run-queue.json"),
                dataRoot.appendingPathComponent("bots/shelf-index.json"),
            ]
        )
    }

    /// Field-for-field passthrough. No re-derivation lives here on purpose: if
    /// this function ever started deciding anything, the loop's tests would stop
    /// covering what production actually does.
    static func delegationJobSnapshot(from row: DelegationJobProjection) -> DelegationJobSnapshot {
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
            deliveryLost: row.deliveryLost,
            completionTextHead: row.completionTextHead,
            recoveryNote: row.recoveryNote,
            deskHandle: row.deskHandle,
            stalled: row.stalled,
            stallBasis: row.stallBasis.rawValue,
            lastLiveness: row.lastLiveness,
            agentReplyTextHead: row.agentReplyTextHead
        )
    }

    /// Settle terminal delegated work back onto the exact Desk item selected
    /// when it was sent. This is execution/delivery evidence only: it never
    /// closes the item or promotes an unverified agent answer into task proof.
    static func recordBoundDelegationSettlement(
        dataRoot: URL,
        job: DelegationJobSnapshot
    ) async -> Bool {
        guard job.isTerminal, let handle = job.deskHandle else { return true }
        let marker = "delegation-settlement:\(job.source):\(job.id)"
        let run = job.runStatus ?? job.status ?? job.terminalOutcome?.rawValue ?? "unknown"
        let delivery = job.deliveryOutcome ?? "unreported"
        let completed = job.completedAt ?? "timestamp unavailable"
        let note = "\(marker) — \(job.agent) run \(run); delivery \(delivery); completed \(completed). "
            + "Execution/delivery evidence only; \(AgentVoice.live.subject) must still assess the result against the request."
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
    static func fileDelegationOutcomeNotice(
        dataRoot: URL,
        card: DelegationOutcomeCard
    ) async -> Bool {
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        let row = card.toJSON()

        // Routine successful delegations are useful recent activity, but one
        // unread row per job turned the notification surface into a completion
        // ledger (406 live unread cards in the 2026-08-29 audit). Keep exactly
        // one active informational rollup per bridge source. Failed, unknown,
        // delivery-lost, backlog, and resolved/stall cards retain their exact
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
        // outcome now folds into one summary per agent; stall and backlog
        // cards (whose ids are not `delegation-outcome:<jobKey>`) keep theirs.
        if card.outcome == .failed || card.outcome == .unknown, !card.resolved,
           card.severityOverride == nil, card.cardId == "delegation-outcome:\(card.jobKey)" {
            return await fileAdverseDelegationRollup(inboxPath: inboxPath, dataRoot: dataRoot, card: card)
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
                    // the job's outcome worsened (finished → unconfirmed) or
                    // the backlog moved — and lands as a fresh unread row that
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
                await InboxPushNotifier.notifyIfAttentionWorthy(
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
    private static func fileAdverseDelegationRollup(
        inboxPath: URL,
        dataRoot: URL,
        card: DelegationOutcomeCard
    ) async -> Bool {
        let rollupID = "delegation-outcome:\(card.source):adverse-rollup"
        let entry = "\(card.outcome.rawValue)|\(card.jobKey)"
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
                    if case .object(let obj)? = line.row, case .string(rollupID)? = obj["id"], isActive(obj) {
                        existing = obj
                    }
                }
                var jobs: [String] = []
                if case .array(let values)? = existing?["adverse_jobs"] {
                    jobs = values.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                }
                if jobs.contains(entry) { return .some(nil) }
                jobs.removeAll { $0.hasSuffix("|\(card.jobKey)") }
                jobs.append(entry)
                if jobs.count > 500 { jobs.removeFirst(jobs.count - 500) }
                let unconfirmed = jobs.filter { $0.hasPrefix("\(DelegationOutcome.unknown.rawValue)|") }.count
                let failed = jobs.count - unconfirmed
                let counts = [failed > 0 ? "\(failed) failed" : nil,
                              unconfirmed > 0 ? "\(unconfirmed) unconfirmed" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                let title = "\(name): \(counts)"
                // The push router dedupes on id + summary, and the id never
                // changes: counts and the job's identity lead the summary so a
                // newly counted job always reads as a new fact.
                let summary = "\(counts). Latest (\(card.jobKey), \(card.createdAt)): \(card.summary)"

                guard case .object(var obj) = card.toJSON() else { return nil }
                obj["id"] = .string(rollupID)
                obj["title"] = .string(title)
                obj["summary"] = .string(String(summary.prefix(500)))
                obj["detail"] = .string(String(("Latest: \(card.title)\n\(card.detail)").prefix(2_000)))
                obj["error_signature"] = .string("delegation_outcome.adverse.\(card.source)")
                obj["adverse_jobs"] = .array(jobs.map { .string($0) })
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
                await InboxPushNotifier.notifyIfAttentionWorthy(
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

    /// Archives per-job failed/unconfirmed cards older than seven days, written
    /// before those outcomes moved into the per-agent summary. Stall, backlog,
    /// and summary cards do not match.
    static func reconcileStaleAdverseDelegationNotices(
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
                           "\(jobKey):\(DelegationOutcome.unknown.rawValue)"]
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
    /// outcomes, backlog cards, current rollups, and already-handled history do
    /// not match this migration.
    static func reconcileLegacySuccessfulDelegationNotices(
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
    func record(_ value: Bool) { deferred = value }
    var hasDeferredWork: Bool { deferred }
}

private struct DelegationOutcomeEventRunner: EventDeadlineLoopRunner {
    let underlying: DelegationOutcomeLoop
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
        do {
            let archived = try await BackgroundLoopsAssembly
                .reconcileLegacySuccessfulDelegationNotices(dataRoot: dataRoot)
                + BackgroundLoopsAssembly.reconcileStaleAdverseDelegationNotices(dataRoot: dataRoot)
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
        do {
            try await AgentConversationContinuation(dataRoot: dataRoot).tick()
        } catch is CancellationError {
            return .skipped(reason: "Delegation reply handling cancelled", healthNeutral: true)
        } catch {
            return .failed(error: "Saved agent conversations could not be reconciled: \(error.localizedDescription)")
        }
        return outcome
    }

    func physiologyEvents() -> AsyncStream<Void> {
        EventDeadlinePhysiology.storeAndFileEvents(paths: watchedPaths)
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        let stall = DelegationStatusProjector(configRoot: configRoot)
            .nextStallDeadline(after: now)
        // 2026-09-06: the ten-card cap and contiguous settlement leave real
        // work behind, and nothing in the store changes when they do — so the
        // remainder used to wait for the next bridge write or the six-hour
        // integrity sweep. A deferring tick books its own continuation.
        let conversation = AgentConversationContinuation(dataRoot: dataRoot).nextDeadline(after: now)
        let deadline = [stall, conversation].compactMap { $0 }.min()
        guard await deferral.hasDeferredWork else { return deadline }
        let rerun = now.addingTimeInterval(Self.deferredRerunGap)
        guard let deadline else { return rerun }
        return min(deadline, rerun)
    }
}
