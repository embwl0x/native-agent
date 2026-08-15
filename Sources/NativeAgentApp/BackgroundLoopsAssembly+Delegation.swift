import Foundation
import BackgroundLoops
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - DelegationOutcomeLoop registration (W2b, upgrade campaign 2026-08)
//
// The two halves this file joins deliberately live apart:
//
//   • `DelegationStatusProjector` (ChatOrchestration) owns READING the two
//     wake-job stores. It is the same reader `delegation_status` uses, so the
//     tool and the cards can never disagree about what a record says.
//   • `DelegationOutcomeLoop` (BackgroundLoops) owns the CURSOR, the terminal
//     classification, and the card text. It knows nothing about ChatOrchestration.
//
// Only the app layer imports both, so only the app layer can wire them — which
// is exactly why this factory exists rather than a module dependency edge.
//
// HONEST LIMIT, stated where the wiring happens: the codex bridge UNLINKS a
// reply-job file once delivery succeeds (codex_thread_wakeup.js
// finalizeReplyJobFile). A cleanly-delivered codex job therefore leaves no
// record for this loop to read, and no success card is filed for it. What the
// codex side DOES surface is the failure half — jobs preserved under
// `reply-jobs/undelivered/` — which is the half worth a card anyway. Claude
// records survive past completion (the file is the O_EXCL dedup marker), so
// both outcomes card on that side.

extension BackgroundLoopsAssembly {

    /// Reads both wake-job stores every 5 minutes and files ONE inbox card per
    /// newly-terminal delegated job. Cursor lives at
    /// `<dataRoot>/logs/delegation_outcome_cursor.json`.
    ///
    /// `configRoot` mirrors `SwiftToolDispatcher.agentBridgeConfigRoot` (nil =
    /// the real `~/.config`); it exists so an integration test can point the
    /// whole loop at a fixture store.
    static func makeDelegationOutcomeLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configRoot: URL? = nil
    ) -> DelegationOutcomeLoop {
        DelegationOutcomeLoop(
            cursorPath: DelegationOutcomeLoop.defaultCursorPath(dataRoot: dataRoot),
            readJobs: {
                // maxLimit, not defaultLimit: the default (20) is a chat-tool
                // display budget. A loop that only ever looked at the newest 20
                // rows could step over a terminal job during a busy window and
                // never card it — the cursor would then advance past it.
                DelegationStatusProjector(configRoot: configRoot)
                    .recentJobs(now: Date(), limit: DelegationStatusProjector.maxLimit)
                    .map(delegationJobSnapshot(from:))
            },
            fileCard: { card in
                await fileDelegationOutcomeNotice(dataRoot: dataRoot, card: card)
            }
        )
    }

    /// Field-for-field passthrough. No re-derivation lives here on purpose: if
    /// this function ever started deciding anything, the loop's tests would stop
    /// covering what production actually does.
    static func delegationJobSnapshot(from row: DelegationJobProjection) -> DelegationJobSnapshot {
        DelegationJobSnapshot(
            id: row.id,
            source: row.source,
            agent: row.agent,
            topicSlug: row.topicSlug,
            state: row.state,
            status: row.status,
            runStatus: row.runStatus,
            completedAt: row.completedAt,
            deliveryOutcome: row.deliveryOutcome,
            deliveryLost: row.deliveryLost,
            completionTextHead: row.completionTextHead
        )
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
                    let signatureMatches: Bool = {
                        if case .string(let old)? = obj["error_signature"] { return old == card.jobKey }
                        return false
                    }()
                    if signatureMatches,
                       case .string(let oldStatus)? = obj["status"],
                       oldStatus != "unread",
                       case .object(var newObj) = row {
                        newObj["status"] = obj["status"] ?? .string("unread")
                        newObj["read_at"] = obj["read_at"] ?? .null
                        replacement = .object(newObj)
                        pushWorthy = false
                    }
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
}
