import Foundation
import AttentionRouting
import AgentConversations
import BackgroundLoops
import ChatTurnRuntime
import ChatToolRuntime
import AgentWorkspace
import Cognition
import NativeAgentCore
import Experiences
import PersistenceCore
import Desk
import DeviceSync
import TelegramBot
import SlackBot
import NativeAgentShared
import ProviderRouting
import StandingBots
// Blueprint: | `DelegationBackgroundWork.swift` | Delegation matters roll up canonical jobs; handled outcomes read their recorded claims |

// MARK: - DelegationOutcomeLoop registration
// The delivery ledger retains terminal evidence after the reply-job file is unlinked.
// Join it to the exact originating message and watch both in the same lifecycle.

public struct DelegationBackgroundWork: Sendable {
    private let port: any DelegationBackgroundWorkPort

    public init(port: any DelegationBackgroundWorkPort) { self.port = port }

    fileprivate func reconcileClosedReplyFindings(dataRoot: URL, configRoot: URL) async throws {
        let closed = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items.filter {
            $0.project == BodyQueue.project && $0.status.isTerminal && $0.closedAt != nil
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

    private static func replyRefs(_ jobs: [DelegationReadout]) throws -> [DeskRef] {
        let ids = try jobs.map { job in
            guard let id = job.completionDeliveryID, !id.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return id
        }
        return Set(ids).sorted().map { DeskRef(refId: $0, kind: .trace(id: $0, kind: "reply_delivery")) }
    }

    private func fileFailedHumanReplies(dataRoot: URL) async throws {
        try await fileFailedReplies(TelegramUpdateInbox.failedReplyClaims(dataRoot: dataRoot),
            route: "telegram", destination: "on Telegram", dataRoot: dataRoot)
        try await fileFailedReplies(SlackInboundDeliveryJournal.failedReplyClaims(dataRoot: dataRoot), route: "slack", destination: "on Slack",
            dataRoot: dataRoot)
    }

    fileprivate func fileFailedIOSReplies(dataRoot: URL, deferral: DelegationDeferralState, changedPath: URL? = nil) async throws {
        let directory = dataRoot.appendingPathComponent("icloud/chat_transactions", isDirectory: true).standardizedFileURL
        if let changedPath, changedPath.deletingLastPathComponent().standardizedFileURL != directory { return }
        let claims = try iCloudBridge.failedReplyClaims(dataRoot: dataRoot, changedPath: changedPath)
        let failed = try await deferral.updateIOSFailures(claims, changedPath: changedPath)
        try await fileFailedReplies(failed, route: "ios", destination: "on iOS",
            dataRoot: dataRoot)
    }

    private func fileFailedReplies(_ records: [(path: URL, at: String?)], deliveryRefs: [DeskRef] = [], route: String, destination: String,
                                   dataRoot: URL) async throws {
        let key = "delivery-failed-before-answer|" + route
        guard !records.isEmpty else {
            let note = "No replies \(destination) remain failed before an answer."
            try await BodyQueue.resolve(key: key, note: note, dataRoot: dataRoot)
            return
        }
        var ordered: [(path: URL, date: Date?)] = records.map { record in
            (path: record.path, date: record.at.flatMap(DeskClock.parseISO))
        }
        ordered.sort { lhs, rhs in
            if lhs.date == rhs.date { return lhs.path.path < rhs.path.path }
            if let left = lhs.date, let right = rhs.date { return left > right }
            return lhs.date != nil
        }
        let dated = ordered.compactMap(\.date)
        let undated = ordered.count - dated.count
        let span = dated.first.flatMap { newest in dated.last.map { oldest in
            " (\(DeskClock.dayStamp(oldest)) – \(DeskClock.dayStamp(newest)))"
        } } ?? ""
        let missingDates = undated == 0 ? "" : "; \(undated) delivery timestamps unavailable — inspect their records"
        var seen = Set<URL>()
        let refs = deliveryRefs + ordered.filter { seen.insert($0.path).inserted }.prefix(12).map {
            DeskRef(refId: $0.path.path, kind: .file(path: $0.path.path, line: nil, label: nil))
        }
        let title = "Replies \(destination) failed before an answer"
        _ = try await BodyQueue.file(BodyFinding(key: key, title: title,
            summary: "\(records.count) replies \(destination) failed before an answer\(span)\(missingDates) — inspect or let go",
            owner: .agent, refs: refs, source: .loop), dataRoot: dataRoot, refreshRefs: true)
    }


    /// Bind projection to this install’s resolved bridge root so another install’s replies cannot count.
    /// Successful outcomes share a source rollup; failed or unconfirmed ones share an actionable summary.
    /// The durable cursor lives at `<dataRoot>/logs/delegation_outcome_cursor.json`.
    public func makeDelegationOutcomeLoop(
        dataRoot: URL = PersistenceCore.defaultDataRoot(),
        configRoot: URL? = nil
    ) -> some EventDeadlineLoopRunner {
        let root = configRoot ?? InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)
        let deferral = DelegationDeferralState()
        let underlying = DelegationOutcomeLoop(
            wake: .every(6 * 60 * 60),
            cursorPath: DelegationOutcomeLoop.defaultCursorPath(dataRoot: dataRoot),
            readJobsWithAvailability: {
                do { try await fileFailedHumanReplies(dataRoot: dataRoot) }
                catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                // A display cap could skip terminal jobs as the cursor advances.
                // Read all jobs with availability so unreadable stores hold the cursor.
                // The resolved root keeps projection on the assembly’s bridge store.
                let read = DelegationStatusProjector(configRoot: root, dataRoot: dataRoot)
                    .allJobsWithAvailability(now: Date())
                let contacts = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
                let jobs = read.jobs.map { projection in
                    var job = projection
                    let id = job.agent.hasPrefix("peer:") ? String(job.agent.dropFirst(5)) : job.agent
                    job.contactName = contacts.first { $0.id == id }?.name
                    return job
                }
                let rows: [AgentConversationRecord]
                do { rows = try AgentConversationStore(dataRoot: dataRoot).records() }
                catch {
                    return DelegationJobsRead(jobs: jobs, allStoresReadable: false,
                        availabilityError: """
                            Delegation conversation routing is unavailable: \(error.localizedDescription). Repair the conversation records, then retry \
                            outcome reconciliation.
                            """)
                }
                if read.allStoresReadable {
                    do { try await reconcileAdverseRollups(dataRoot: dataRoot, jobs: jobs) }
                    catch { nativeLog("Delegation rollup reconciliation failed: %@", error.localizedDescription) }
                    for peer in Set(read.jobs.map(\.agent)).sorted() {
                        let owed = read.jobs.filter { $0.agent == peer && $0.replyOwed }
                        let key = "delivery-residue|" + peer
                        if owed.isEmpty {
                            try? await BodyQueue.resolve(key: key, note: "No saved answers remain owed.", dataRoot: dataRoot)
                        } else {
                            // Preserve the contact name that agent.contacts exposes.
                            let id = peer.hasPrefix("peer:") ? String(peer.dropFirst(5)) : peer
                            // A helper's run is named by its helper, as its conversation row names it; never by its id.
                            let name = contacts.first { $0.id == id }?.name
                                ?? owed.lazy.compactMap(\.contactName).first { !$0.isEmpty }
                                ?? (peer.hasPrefix("bot-run:") ? "a helper" : DelegationOutcomeCard.displayName(source: peer, agent: peer))
                            _ = try? await BodyQueue.file(BodyFinding(key: key,
                                title: "Replies owed to " + name,
                                summary: "\(owed.count) saved replies to \(name) remain owed: the call that asked for each can no longer take it. "
                                    + "Wait on one with desk.wait {handle, on: <its id on this item>}, or let it go with repair.let_go {id, reason}.",
                                owner: .agent, refs: try Self.replyRefs(owed), source: .loop), dataRoot: dataRoot, refreshRefs: true)
                        }
                        do {
                            let failedJobs = read.jobs.filter { $0.agent == peer && $0.deliveryOutcome == "failed_before_answer" }
                            let failed = try failedJobs.map { job in
                                guard let path = job.recoveryNote else { throw CocoaError(.fileReadCorruptFile) }
                                return (path: URL(fileURLWithPath: path), at: job.deliveryUpdatedAt)
                            }
                            try await fileFailedReplies(failed, deliveryRefs: Self.replyRefs(failedJobs), route: peer,
                                destination: "to " + DelegationOutcomeCard.displayName(source: peer, agent: peer),
                                dataRoot: dataRoot)
                        } catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                    }
                }
                // Only matching open delegations get the resident notice; other routes keep the person’s push.
                // Unreadable conversations cannot select another audience; reconciliation stays owed.
                return DelegationJobsRead(
                    jobs: jobs.map { snapshot in
                        var job = snapshot
                        job.reachesAgent = rows.contains { conversation in
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
                    var action = job
                    action.motorOwnerID = job.motorOwnerID ?? job.id
                    await port.observeMotorActionState(action.motorActionReadModel())
                }
                // Wake the originating delegated chat as well as surfacing the person’s card.
                do {
                    try AgentConversationStore(dataRoot: dataRoot).noteDelegationEvent(
                        agent: job.agent, messageIDs: job.acceptedMessageIDs.sorted()
                    ) { row in
                        DelegationOutcomeCard.residentNotice(from: job, conversation: row.label)
                            .map { AgentConversationNotice(event: $0.event, text: $0.text) }
                    }
                } catch {
                    FileHandle.standardError.write(Data(("DelegationOutcomeLoop: conversation notice failed "
                        + "for \(job.source):\(job.id): \(error.localizedDescription)\n").utf8))
                    return false
                }
                // A failed channel returns to the agent's own mind stream, never down that channel.
                if job.terminalOutcome == .failed,
                   !job.reachesAgent || DelegationOutcomeCard.residentNotice(from: job, conversation: "") == nil {
                    let name = job.displayName
                    let head = (job.agentReplyTextHead ?? job.completionTextHead)?
                        .split(whereSeparator: \.isNewline).first.map { String($0.prefix(140)) }
                    let signIn = head.map { AgentLocalHealth.authenticationFailure(.string($0)) } == true
                    let word = job.runStatus ?? job.status ?? "failed"
                    var line = "\(name)'s wake failed" + (word == "failed" ? "" : " (\(word))")
                    if signIn { line += ": its sign-in failed or expired" } else if let head { line += ": \"\(head)\"" }
                    // The line quotes the contact's words only when it carries the head of its reply.
                    let quoted: [String]? = signIn || head == nil || job.agent.isEmpty ? nil : [job.agent]
                    Attention.post(Happening(.returned, subject: "wake:" + job.agent, door: "delegation:" + job.source, words: line,
                        once: "wake-failed:\(job.source):\(job.id)", peers: quoted), dataRoot: dataRoot)
                }
                return await recordBoundDelegationSettlement(dataRoot: dataRoot, job: job)
            },
            reportDeferral: { remaining in
                guard remaining, !Task.isCancelled else { return }
                NotificationCenter.default.post(name: DelegationOutcomeLoop.workRemaining, object: dataRoot)
            },
            readHandledOutcomes: {
                var handled = Set<String>()
                for matter in try await ForPerson.at(dataRoot).matters()
                    where matter.face?.from == "delegation_outcome" && ForPerson.reading(matter) != .unread {
                    for claim in matter.claims {
                        guard claim.claim.hasPrefix("delegation outcome: ") else { continue }
                        let outcome = String(claim.claim.dropFirst("delegation outcome: ".count))
                        guard DelegationOutcome(rawValue: outcome) != nil else { throw CocoaError(.fileReadCorruptFile) }
                        for ref in claim.evidence where ref.source == Matter.delegations {
                            handled.insert(ref.id + ":" + outcome)
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
                AgentConversationStore(dataRoot: dataRoot).fileURL,
                dataRoot.appendingPathComponent("bots/run-queue.json"),
                dataRoot.appendingPathComponent("bots/shelf-index.json"),
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

    /// Settle only the selected Desk item; delivery evidence neither closes it nor proves the answer correct.
    public func recordBoundDelegationSettlement(
        dataRoot: URL,
        job: DelegationReadout
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
            // An archived item has no live settlement target; retrying forever would pin the outcome cursor.
            return true
        } catch {
            // Log settlement failures and return false so the loop retries.
            FileHandle.standardError.write(Data(("DelegationOutcomeLoop: Desk settlement failed "
                + "for \(job.source):\(job.id) on \(handle): \(error)\n").utf8))
            return false
        }
    }

    /// The job owns the outcome; a matter owns what the person has been told about it.
    public func fileDelegationOutcomeNotice(dataRoot: URL, card: DelegationOutcomeCard, read: DelegationJobsRead) async -> Bool {
        do {
            if card.resolved {
                try await BodyNotice.resolve(key: card.cardId, from: "delegation_outcome", dataRoot: dataRoot)
                return true
            }
            if card.outcome == .succeeded, card.severity == "info" {
                guard read.allStoresReadable else { return false }
                try await BodyNotice.resolve(key: card.cardId, from: "delegation_outcome", dataRoot: dataRoot)
                return try await fileDelegationRollup(dataRoot: dataRoot, card: card, jobs: read.jobs, adverse: false)
            }
            if card.outcome == .failed || card.outcome == .unknown,
               card.severityOverride == nil, card.cardId == "delegation-outcome:\(card.jobKey)" {
                guard read.allStoresReadable else { return false }
                try await BodyNotice.resolve(key: card.cardId, from: "delegation_outcome", dataRoot: dataRoot)
                return try await fileDelegationRollup(dataRoot: dataRoot, card: card, jobs: read.jobs, adverse: true)
            }
            try await BodyNotice.tell(key: card.cardId, from: "delegation_outcome",
                                                  finding: card.signature, dataRoot: dataRoot) { id in
                let form: Matter.Form = card.severity == "info" ? .done : card.outcome == .unknown ? .ask : .wentWrong
                try await port.tell(Matter(id: id, form: form, from: "delegation_outcome",
                    title: card.title, summary: String(card.summary.prefix(500)), words: String(card.detail.prefix(2_000)),
                    open: "page:delegations", choices: [.init(id: "view", label: "View"), .init(id: "archive", label: "Archive"),
                                                      .init(id: "dismiss", label: "Dismiss")],
                    evidence: [.init(source: Matter.delegations, id: card.jobKey)]),
                    dataRoot: dataRoot, reach: card.severity == "info" ? .inbox : .person(from: nil), turn: nil)
                try await recordDelegationClaims(id: id, jobs: [(card.jobKey, card.outcome)], dataRoot: dataRoot)
            }
            return true
        } catch {
            nativeLog("DelegationOutcomeLoop: matter could not be told for %@: %@", card.cardId, error.localizedDescription)
            return false
        }
    }

    /// Counts read the current jobs, without a second list of absorbed occurrences.
    private func fileDelegationRollup(dataRoot: URL, card: DelegationOutcomeCard, jobs: [DelegationReadout], adverse: Bool) async throws -> Bool {
        let members = jobs.filter { job in
            guard job.source == card.source, let outcome = job.terminalOutcome else { return false }
            if !adverse { return outcome == .succeeded }
            return !["owed", "sent_unconfirmed", "failed_before_answer"].contains(job.deliveryOutcome ?? "")
                && (outcome == .failed || outcome == .unknown)
        }
        guard !members.isEmpty else { return false }
        let forPerson = ForPerson.at(dataRoot)
        let key = "delegation-outcome:\(card.source):\(adverse ? "adverse" : "successful")-rollup:"
        let open = try await forPerson.matters().first {
            $0.face?.from == "delegation_outcome" && $0.id.hasPrefix(key)
                && (ForPerson.reading($0) == .unread || ForPerson.reading($0) == .read)
        }
        var id = open?.id ?? key + UUID().uuidString.lowercased()
        let failed = members.filter { $0.terminalOutcome == .failed }.count
        let unknown = members.filter { $0.terminalOutcome == .unknown }.count
        let counts = adverse
            ? [failed > 0 ? "\(failed) failed" : nil, unknown > 0 ? "\(unknown) unconfirmed" : nil].compactMap { $0 }.joined(separator: ", ")
            : "\(members.count) finished"
        let name = card.contactName ?? DelegationOutcomeCard.displayName(source: card.source, agent: card.agent)
        func matter(_ id: String) -> Matter {
            Matter(id: id, form: !adverse ? .done : failed > 0 ? .wentWrong : .ask, from: "delegation_outcome",
            title: name + ": " + counts, summary: String((counts + ". Latest: " + card.summary).prefix(500)),
            words: String(("Latest: " + card.title + "\n" + card.detail).prefix(2_000)), badge: String(members.count),
            open: "page:delegations", choices: [.init(id: "view", label: "View"), .init(id: "archive", label: "Archive"),
                                              .init(id: "dismiss", label: "Dismiss")],
            evidence: members.map { .init(source: Matter.delegations, id: $0.source + ":" + $0.id) })
        }
        let doors = adverse && !card.reachesAgent ? Door.person(thread: nil) : []
        if try await forPerson.tell(matter(id), doors: doors) == .settled {
            id = key + UUID().uuidString.lowercased()
            try await forPerson.tell(matter(id), doors: doors)
        }
        try await recordDelegationClaims(id: id, jobs: members.compactMap { job in
            job.terminalOutcome.map { (job.source + ":" + job.id, $0) }
        }, dataRoot: dataRoot)
        return true
    }

    /// Claims preserve which observed outcome the person read, even if that job later changes.
    private func recordDelegationClaims(id: String, jobs: [(String, DelegationOutcome)], dataRoot: URL) async throws {
        try await ExperienceStore.at(dataRoot).append(jobs.map { key, outcome in
            .claim(.init(claim: "delegation outcome: " + outcome.rawValue, evidence: [.init(source: Matter.delegations, id: key)]))
        }, to: id)
    }

    private func reconcileAdverseRollups(dataRoot: URL, jobs: [DelegationReadout]) async throws {
        let forPerson = ForPerson.at(dataRoot)
        for matter in try await forPerson.matters()
            where matter.face?.from == "delegation_outcome" && matter.id.contains(":adverse-rollup:")
                && (ForPerson.reading(matter) == .unread || ForPerson.reading(matter) == .read) {
            guard let marker = matter.id.range(of: ":adverse-rollup:") else { continue }
            let source = String(matter.id[..<marker.lowerBound].dropFirst("delegation-outcome:".count))
            let matching = jobs.filter { $0.source == source }
            let adverse = matching.filter {
                !["owed", "sent_unconfirmed", "failed_before_answer"].contains($0.deliveryOutcome ?? "")
                    && ($0.terminalOutcome == .failed || $0.terminalOutcome == .unknown)
            }
            // Missing members are not evidence of recovery; only observed replacement outcomes clear the rollup.
            let refs = (matter.evidence + matter.claims.flatMap(\.evidence)).filter { $0.source == Matter.delegations }
            guard !refs.isEmpty, refs.allSatisfy({ ref in matching.contains { $0.source + ":" + $0.id == ref.id } }) else { continue }
            if adverse.isEmpty { try await BodyNotice.resolve(matter, dataRoot: dataRoot) }
            else if let latest = adverse.first, let card = DelegationOutcomeCard.make(from: latest, now: Date()) {
                _ = try await fileDelegationRollup(dataRoot: dataRoot, card: card, jobs: jobs, adverse: true)
            }
        }
    }

    /// The passage of seven days retires this notice, without a verdict about the job.
    public func reconcileStaleAdverseDelegationNotices(dataRoot: URL, now: Date = Date()) async throws -> Int {
        var count = 0
        for matter in try await ForPerson.at(dataRoot).matters() {
            guard matter.face?.from == "delegation_outcome", !matter.id.contains("-rollup:"),
                  matter.face?.row?.tone == .failed || matter.owes["decide"] != nil,
                  ForPerson.reading(matter) == .unread || ForPerson.reading(matter) == .read,
                  let at = NativeTimestampFormat.parseISO8601FractionalFirst(matter.at),
                  at <= now.addingTimeInterval(-7 * 86_400) else { continue }
            try await BodyNotice.resolve(matter, dataRoot: dataRoot)
            count += 1
        }
        return count
    }

}

actor DelegationDeferralState {
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
}

private struct DelegationOutcomeEventRunner: EventDeadlineLoopRunner {
    let underlying: DelegationOutcomeLoop
    let work: DelegationBackgroundWork
    let port: any DelegationBackgroundWorkPort
    let dataRoot: URL
    let configRoot: URL
    let deferral: DelegationDeferralState
    let watchedPaths: [URL]

    var loopId: String { underlying.loopId }
    var wake: OrganWake { underlying.wake }
    // Reconciliation admits contact work under the checked provider guard.
    // Retained contact turns own their execution lifetime and cancellation.
    var tickTimeoutOverride: TimeInterval? {
        let config = ProviderStreamGuardConfig.fromEnvironment()
        do { try config.validate(); return config.wallTimeout + 60 }
        // No provider tick is admitted below; the scheduler retains its own
        // envelope for reporting this configuration failure.
        catch { return nil }
    }

    func shutdown() async { await port.stopAgentConversations() }

    func tickOutcome() async -> LoopTickOutcome {
        do { try ProviderStreamGuardConfig.fromEnvironment().validate() }
        catch { return .failed(error: error.localizedDescription) }
        do { try await work.reconcileClosedReplyFindings(dataRoot: dataRoot, configRoot: configRoot) }
        catch { return .failed(error: """
            Reply let-go settlement failed: \(error.localizedDescription). Repair the reply or Desk records before reconciliation.
            """) }
        if await deferral.takeReplyReconciliation() {
            do { try await port.reconcileReplyDeliveries(dataRoot: dataRoot) }
            catch {
                await deferral.requestReplyReconciliation()
                return .failed(error: "Reply reconciliation failed: \(error.localizedDescription)")
            }
        }
        do {
            let archived = try await work.reconcileStaleAdverseDelegationNotices(dataRoot: dataRoot)
            if archived > 0 {
                FileHandle.standardError.write(Data(
                    "DelegationOutcomeLoop: archived \(archived) stale adverse delegation cards\n".utf8
                ))
            }
        } catch {
            // Inbox cleanup failure must not block outcome delivery; retry at the next event or integrity tick.
            FileHandle.standardError.write(Data(
                "DelegationOutcomeLoop: stale adverse notice reconciliation failed: \(error)\n".utf8
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
            $0.path.contains("codex-completion-lifecycle") || $0.path.contains("/slack/")
                || $0.path.contains("/telegram/") || $0.path.contains("/icloud/")
        }
        let ordinaryPaths = watchedPaths.filter { !deliveryPaths.contains($0) }
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let journalChanges = StoreChangeBus.shared.changes()
            let routes = EventDeadlinePhysiology.storeAndFileEvents(
                paths: [dataRoot.appendingPathComponent("chat/sessions.json"), dataRoot.appendingPathComponent("user_prefs.json")],
                notifications: [.NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
                    DelegationOutcomeLoop.workRemaining])
            let deliveryEvents = EventDeadlinePhysiology.storeAndFileEvents(paths: deliveryPaths, loopId: nil)
            let ordinaryEvents = EventDeadlinePhysiology.storeAndFileEvents(
                paths: ordinaryPaths, notifications: [BotRunQueue.didChange], loopId: nil)
            let networkChanges = NetworkSense.changes
            let task = Task {
                await withTaskGroup(of: String.self) { group in
                    group.addTask {
                        for await up in networkChanges {
                            guard !Task.isCancelled else { break }
                            if up { continuation.yield(()) }
                        }
                        return "network path"
                    }
                    group.addTask {
                        guard !Task.isCancelled else { return "reply-delivery journal" }
                        do { try await work.fileFailedIOSReplies(dataRoot: dataRoot, deferral: deferral) }
                        catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                        for await change in journalChanges where change.store == .replyDelivery
                            && NativeAgentWorkspaceRoot.relativePath(
                                change.path.standardizedFileURL.path,
                                under: dataRoot.standardizedFileURL.path
                            ).map({ !$0.isEmpty }) == true {
                            guard !Task.isCancelled else { break }
                            do { try await work.fileFailedIOSReplies(dataRoot: dataRoot, deferral: deferral, changedPath: change.path) }
                            catch { nativeLog("Reply failure filing failed: %@", error.localizedDescription) }
                            guard !Task.isCancelled else { break }
                            await deferral.requestReplyReconciliation()
                            guard !Task.isCancelled else { break }
                            continuation.yield(())
                        }
                        return "reply-delivery journal"
                    }
                    group.addTask {
                        for await _ in deliveryEvents {
                            guard !Task.isCancelled else { break }
                            await deferral.requestReplyReconciliation()
                            guard !Task.isCancelled else { break }
                            continuation.yield(())
                        }
                        return "delivery files"
                    }
                    group.addTask {
                        for await _ in ordinaryEvents {
                            guard !Task.isCancelled else { break }
                            continuation.yield(())
                        }
                        return "delegation files"
                    }
                    group.addTask {
                        guard !Task.isCancelled else { return "reply routes" }
                        for await _ in routes {
                            guard !Task.isCancelled else { break }
                            await deferral.requestReplyReconciliation()
                            guard !Task.isCancelled else { break }
                            continuation.yield(())
                        }
                        return "reply routes"
                    }
                    // Finish before draining: an infinite sibling must not hide source loss from the listener restart owner.
                    if let source = await group.next(), !Task.isCancelled {
                        nativeLog("DelegationOutcomeLoop: %@ event source ended; rebuilding fan-in", source)
                        continuation.finish()
                    }
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func nextMeaningfulDeadline(after now: Date) async -> Date? {
        var quietEnd: Date?
        do {
            if let window = try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot),
               window.contains(hour: Calendar.current.component(.hour, from: now)) {
                quietEnd = window.end(after: now)
                await deferral.requestReplyReconciliation()
            }
        } catch {
            await settle {
                await BackgroundLoopLifetimes.shared.recordOutOfBandOutcome(loopId: loopId,
                    outcome: .failed(error: """
                        Reply quiet-hours preferences unavailable: \(error.localizedDescription). Repair user_prefs.json to rearm release.
                        """))
            }
        }
        return quietEnd
    }
}
