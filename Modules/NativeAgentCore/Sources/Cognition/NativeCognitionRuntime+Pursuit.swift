import Foundation
import NativeAgentShared
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import BackgroundLoops
import AgentWorkspace
import CognitiveSubstrate
import Context
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import Desk
import Experiences
import ProviderRouting
import Transcripts

// Blueprint: | `NativeCognitionRuntime+Pursuit.swift` | Complete Desk/queue advisory snapshots publish through LatestRead; source, presence and signal releases refresh readiness; carried habits run through the host's gated self door without planning, retaining attempted-occurrence receipts before effects and actual results through settle; needs_me or unfinished work wakes their with already_looked evidence; successful calls then fixed say words share one delivery/note/until settlement; migrated calendar speech keys share IntentionClock civil occurrence identity with carry offers; standing handling offers ride the carried arrival at most daily; clock/person/news/signal moments bypass free-time quiet; resident intent has no turn-time Desk I/O |

extension NativeCognitionRuntime: MyQueueTurnProjectionProviding {
    public func queueTurnCandidates() -> (candidates: [DeskItem]?, refreshPendingAfterWrite: Bool) {
        let revision = SwiftNativeDeskStore.currentRevision
        return (pursuitReadRevision == revision && !isFlushedForTermination ? pursuitCandidates : nil,
                !isFlushedForTermination && pursuitCompletedRefreshRevision != revision)
    }

    private static let maximumPursuitCandidates = 8

    /// Her top resident self-pursuit projection. This method is deliberately
    /// synchronous: a user turn can never initiate Desk I/O.
    private func currentPursuitIntent(now: Date) -> (activeTask: String, goal: String)? {
        guard let candidates = queueTurnCandidates().candidates else { return nil }
        let best = candidates
            .filter { $0.isPursuit && !$0.status.isTerminal }
            .prefix(Self.maximumPursuitCandidates)
            .compactMap { item in host.pursuitChoiceTotal(for: item, now: now).map { (item, $0) } }
            .max { $0.1 < $1.1 }
        guard let p = best?.0.pursuit else { return nil }
        func bound(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        return (activeTask: bound(p.why), goal: bound(p.doneLooksLike))
    }

    /// Register before the first replay so no committed Desk edge can land in
    /// the read/subscription gap. Matching by exact path preserves injected
    /// data-root hermeticity; `.desk` would cross-invalidate every runtime.
    func startPursuitObservationIfNeeded() {
        guard !isFlushedForTermination, pursuitObservationTask == nil else { return }
        startCognitiveSourceObservations()
        let sourceObservations = sourceWakes
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
            SwiftNativeDeskStore(dataRoot: dataRoot).basePath,
            dataRoot.appendingPathComponent("memory/memory.sqlite"),
            dataRoot.appendingPathComponent("memory/memory.sqlite-wal"),
            dataRoot.appendingPathComponent("workflows/approvals/requests.json"),
            dataRoot.appendingPathComponent("agents/resident-wake.json")
        ])
        pursuitObservationTask = Task { [weak self] in
            await withTaskCancellationHandler {
                for await _ in events {
                    guard !Task.isCancelled else { return }
                    await self?.pursuitSourceInvalidated()
                }
            } onCancel: {
                sourceObservations.cancelObservations()
            }
        }
        carriedExperienceObservationTask = Task { [weak self, root = dataRoot] in
            let changes = await ExperienceStore.at(root).changes()
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.carriedConditionsChanged()
            }
        }
        // Her free time opens when her last turn's window closes: every owner
        // that waited on a live turn (carried, Reach, her hour) re-considers.
        turnIdleObservationTask = Task { [weak self, root = dataRoot] in
            for await _ in ChatTurnSteering.idleEdges(dataRoot: root) {
                guard !Task.isCancelled else { return }
                await self?.rescheduleResidualRepairDeadline()
            }
        }
    }

    /// A condition that settled is written off the items that waited on it;
    /// that Desk write is what re-considers them. One pass at a time, read
    /// from the live Desk, so two settlements never write from a stale copy.
    private func carriedConditionsChanged() async {
        guard pursuitCandidates.contains(where: { !$0.status.isTerminal && $0.blockedOn.contains { $0.hasPrefix("exp:") } }) else { return }
        guard !carriedReleaseRunning else { carriedReleaseAgain = true; return }
        carriedReleaseRunning = true
        defer { carriedReleaseRunning = false }
        repeat {
            carriedReleaseAgain = false
            guard !isFlushedForTermination else { return }
            do { try await MyQueueReady.release(items: SwiftNativeDeskStore(dataRoot: dataRoot).liveState().items, dataRoot: dataRoot) }
            catch { ModuleLog(category: "Cognition")("Wait conditions unavailable: %@", error.localizedDescription) }
        } while carriedReleaseAgain
    }

    private func pursuitSourceInvalidated() {
        guard !isFlushedForTermination else { return }
        pursuitRead.write {
            pursuitReadRevision = nil
            // A possibly closed pursuit must stop steering attention immediately.
            attentionProjection.replacePursuit(activeTask: nil, goal: nil)
        }
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        Task { [weak self] in
            await self?.startPursuitRefresh()
        }
    }

    func startPursuitRefresh() async {
        guard !isFlushedForTermination else { return }
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        pursuitRefreshInFlight = true
        sourceWakes.pursuitNextAt = nil
        pursuitRefreshTask = Task { [weak self] in
            await self?.finishPursuitRefresh()
        }
    }

    /// The canonical presence edge reaches the same carried refresh and
    /// residual-deadline path as a Desk change, without waiting for a turn.
    public func carriedPresenceChanged() async {
        await startPursuitRefresh()
    }

    /// EnginePartWake's one signal observation serves parts and intentions.
    /// The Desk note is the release; no second arrival or signal ledger is kept.
    public func carriedSignal(_ signal: String, payload: [String: JSONValue], suppressing echoes: Set<String> = []) async {
        guard !isFlushedForTermination, !Task.isCancelled,
              !signal.hasPrefix("schedule:"), !["held", "resumed"].contains(signal) else { return }
        do {
            // The note names what happened, never what someone said: a message's text
            // reaches her only through its own (tainted) door, never as a system note.
            let summary = signal.hasPrefix("file.changed:") ? "" : (payload["path"]?.stringValue).map { String($0.prefix(160)) } ?? ""
            if try await MyQueue.releaseSignal(signal, summary: summary,
                store: SwiftNativeDeskStore(dataRoot: dataRoot), at: now(), suppressing: echoes) {
                await startPursuitRefresh()
            }
        } catch {
            ModuleLog(category: "Cognition")("Body signal intention release unavailable: %@", error.localizedDescription)
        }
    }

    private func finishPursuitRefresh() async {
        let root = dataRoot, clock = now
        let snapshot = await pursuitRead.read({
            let task = Task.detached(priority: .utility) {
                // A commit during replay invalidates the read, never relabels it.
                let revision = SwiftNativeDeskStore.currentRevision
                let state = try? await SwiftNativeDeskStore(dataRoot: root).liveState()
                let context: MyQueue.Context?
                do { context = try state.map { _ in try HerScreen.queueContext(dataRoot: root, now: clock(), ownTurn: true) } }
                catch {
                    context = nil
                    // Experience changes also refresh pursuit. Do not append a
                    // repeat-evidence event to the same open debt on every
                    // failed refresh and thereby wake this reader itself.
                    do {
                        if try await RepairOwed.openDebt(ExperienceStore.at(root), operation: "queue.conditions", owner: root.path) == nil {
                            await RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: "queue.conditions", owner: root.path,
                                words: "Queue conditions are unavailable: \(error.localizedDescription). Carried work is not admitted from this reading.",
                                tap: "Repair the reported approval or conversation storage, preserving all records.").value
                        }
                    } catch { ModuleLog(category: "Cognition")("Queue condition failure could not be retained: %@", error.localizedDescription) }
                }
                return (state: state, revision: revision, context: context)
            }
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }, publish: { snapshot in
            pursuitReadRevision = nil
            guard !isFlushedForTermination, snapshot.revision == SwiftNativeDeskStore.currentRevision,
                  let state = snapshot.state else { return }
            sourceWakes.pursuitNextAt = state.items.filter { !$0.status.isTerminal }
                .compactMap { $0.deferUntil.flatMap(DeskSequencing.parseDeferStamp) }.filter { $0 > now() }.min()
            let before = Dictionary(pursuitCandidates.filter { !$0.status.isTerminal }.map { ($0.handle, $0) },
                uniquingKeysWith: { first, _ in first })
            if pursuitCandidates != state.items { sourceWakes.reachDirty = true }
            pursuitCandidates = state.items
            pursuitCarriedContext = snapshot.context
            pursuitReadRevision = snapshot.revision
            // A condition may have settled before its wait reached the Desk.
            Task { await self.carriedConditionsChanged() }
            var signals: [(String, SomaticSignalKind)] = []
            for item in state.items {
                let wasCarried = before[item.handle].map(Self.carries) == true
                guard Self.carries(item) || wasCarried else { continue }
                if item.status.isTerminal || !Self.carries(item) {
                    ResidentWake.shared.withdraw(dataRoot: dataRoot, key: "carry." + item.handle)
                    if wasCarried && item.status.isTerminal {
                        signals.append((item.handle, item.status == .canceled ? .deskItemCancelled : .deskItemClosed))
                    }
                } else if !wasCarried {
                    signals.append((item.handle, .deskItemCreated))
                } else if item.status == .blocked, before[item.handle]?.status != .blocked {
                    signals.append((item.handle, .deskItemBlocked))
                }
            }
            // Bootstrap's awaited replay must finish before signal ingestion
            // can await that same bootstrap. Later writes use this same tail.
            Task { [weak self] in
                for (handle, kind) in signals {
                    await self?.ingestOrganismSignal(kind: kind, sourceOrgan: "carry." + handle,
                        metadata: ["predictionCorrelationId": .string(handle)],
                        persistSynchronously: false)
                }
                await self?.rescheduleResidualRepairDeadline()
            }
        })

        pursuitRefreshInFlight = false
        pursuitRefreshTask = nil
        guard !isFlushedForTermination else { pursuitRefreshQueued = false; return }
        let intent = currentPursuitIntent(now: now())
        attentionProjection.replacePursuit(
            activeTask: intent?.activeTask,
            goal: intent?.goal
        )
        let needsFollowUp = pursuitRefreshQueued
        pursuitRefreshQueued = false
        // A failed settled refresh stays unavailable, but no longer claims to be pending.
        if !needsFollowUp { pursuitCompletedRefreshRevision = snapshot.revision }
        if needsFollowUp {
            await startPursuitRefresh()
        }
        await rescheduleResidualRepairDeadline()
    }
}

extension NativeCognitionRuntime {
    static func carries(_ item: DeskItem) -> Bool {
        item.project == MyQueue.project || item.assignee == "agent"
    }

    static func carriedTouch(_ item: DeskItem, at now: Date) -> Date {
        max(Self.deskDate(item.openedAt) ?? now,
            item.notes.filter { $0.author == "agent" }.compactMap { Self.deskDate($0.ts) }.max() ?? .distantPast)
    }

    /// One salience law, one exact-deadline owner and one existing wake door.
    func considerCarried(runNow: Bool = false) async -> (next: Date?, result: MindClockResult) {
        guard !isFlushedForTermination, !carriedSayInFlight else { return (nil, .init("held", "Carried work is running or the runtime is stopping.")) }
        await finishOwedCarriedSettlements()
        guard !isFlushedForTermination, !carriedSayInFlight, !pursuitRefreshInFlight, !pursuitRefreshQueued,
              let revision = pursuitReadRevision, let candidates = queueTurnCandidates().candidates,
              var context = pursuitCarriedContext else { return (nil, .init("unavailable", "The current Desk readiness snapshot is not available; no work was selected.")) }
        let at = now(), root = dataRoot
        let generation = residualDeadline.generation
        guard candidates.contains(where: { Self.carries($0) && !$0.isPursuit }) else { return (nil, .init("nothing", "The current Desk snapshot contains no carried step.")) }
        guard !liveTurnInFlight else { return (nil, .init("held", "A live turn is in flight.")) }
        // An intention whose until time has passed is done: it lets itself go.
        for entry in candidates.compactMap(MyQueue.entry) where MyQueue.isOver(entry, at: at) {
            do {
                try await MyQueue.finish(entry, dropped: false, why: "its time ran out (until \(entry.step.until ?? ""))",
                                         store: SwiftNativeDeskStore(dataRoot: root))
            } catch {
                let cause = Self.bodySourceFailure(error, source: "intention expiry " + entry.item.handle, dataRoot: root)
                if pursuitReadRevision == revision {
                    pursuitRead.write { pursuitReadRevision = nil }
                }
                return (nil, .init("unavailable", cause))
            }
        }
        let lastTurnActivityAt = await ChatTurnSteering.shared.turnActivityOrSeed(for: root, at: at)
        let quietAt = runNow ? at : lastTurnActivityAt.addingTimeInterval(StudioWanderLane.quietInterval)
        guard revision == SwiftNativeDeskStore.currentRevision else { return (nil, .init("held", "The Desk changed during the readiness read.")) }
        guard let opportunities = ResidentWake.carriedOpportunities(dataRoot: root,
            items: candidates.filter { Self.carries($0) && !$0.isPursuit }, at: at) else {
            return (nil, .init("unavailable", "The carried wake ledger could not be read and kept; readiness is unknown."))
        }
        var next: Date?, best: DeskItem?
        var readyByTime: [Date: Set<String>] = [:]
        for item in candidates {
            let entry = MyQueue.entry(item)
            // A rhythm's next time and an until's end are deadlines whether or not it can be offered now:
            // the occurrence after an offered one is a new offer only once its time comes.
            if let step = entry?.step, let upcoming = IntentionClock.next(step, after: at) { next = min(next ?? upcoming, upcoming) }
            if let ends = entry.flatMap({ MyQueue.until($0).endsAt }), ends > at { next = min(next ?? ends, ends) }
            guard let wakeAt = opportunities[item.handle] else { continue }
            var crossing = wakeAt
            let moment = entry.flatMap(MyQueue.when)
            if case .at(let due)? = moment { crossing = max(crossing, due) }
            if case .every? = moment, let step = entry?.step {
                // Its occurrence due now, else its next one; a rhythm past its end has none.
                guard let due = IntentionClock.occurrence(step, at: at) ?? IntentionClock.next(step, after: at) else { continue }
                crossing = max(crossing, due)
            }
            if let deferred = item.deferUntil.flatMap(DeskSequencing.parseDeferStamp) { crossing = max(crossing, deferred) }
            // Clock, person, news and body signals come promptly; the rest wait for free time.
            if moment?.isPrompt != true { crossing = max(crossing, quietAt) }
            context.now = max(at, crossing)
            let ready = readyByTime[context.now] ?? Set(MyQueueReady.ready(items: candidates, context: context, dataRoot: dataRoot).map(\.handle))
            readyByTime[context.now] = ready
            guard ready.contains(item.handle) else { continue }
            if crossing > at { next = min(next ?? crossing, crossing); continue }
            if let current = best {
                if Self.carriedTouch(item, at: at) < Self.carriedTouch(current, at: at) { best = item }
            } else { best = item }
        }
        guard let best else { return (next, .init("held", "No carried step is ready at the real time; readiness, occurrence, defer and offer-rest gates still apply.")) }
        let freedom = StudioWanderLane.decide(now: at, turnInFlight: liveTurnInFlight,
            lastTurnActivityAt: lastTurnActivityAt, lastWanderAt: nil, satisfyWait: runNow)
        let prompt = MyQueue.entry(best).flatMap(MyQueue.when)?.isPrompt ?? false
        guard freedom == .wander || prompt else {
            guard freedom == .notQuiet else { return (next, .init("held", freedom.rawValue)) }
            let freeAt = Date(timeIntervalSinceReferenceDate: quietAt.timeIntervalSinceReferenceDate.nextUp)
            return (min(next ?? freeAt, freeAt), .init("held", freedom.rawValue))
        }
        guard revision == SwiftNativeDeskStore.currentRevision else { return (nil, .init("held", "The Desk changed before admission.")) }
        guard !liveTurnInFlight, !carriedSayInFlight,
              generation == residualDeadline.generation, !isFlushedForTermination, !Task.isCancelled else { return (next, .init("held", "Carried admission changed before execution.")) }
        if let entry = MyQueue.entry(best), entry.step.action != nil {
            carriedSayInFlight = true
            defer { carriedSayInFlight = false }
            return (next, await runCarriedHabit(entry, at: at, generation: generation))
        }
        // An end in words ("until User answers") needs her judgment each time: that one wakes her.
        if let entry = MyQueue.entry(best), let words = entry.step.say,
           !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           { if case .words = MyQueue.until(entry) { return false }; return true }(),
           entry.owedToPerson(dataRoot: root) || entry.step.origin == "self" || entry.step.origin == "person" {
            // Quiet hours hold what reaches him, not her work (User 10-12): the words
            // land at their time and the router holds the informational knock.
            carriedSayInFlight = true
            defer { carriedSayInFlight = false }
            return (next, await deliverCarriedSay(entry, words: words, at: at, revision: revision, generation: generation))
        }
        var arrival = ResidentWake.carriedArrival(best, crossing: at, dataRoot: dataRoot)
        arrival.habitSuggestion = await CarriedHabits.shared.suggestion(for: best, dataRoot: root, at: at)
        guard revision == SwiftNativeDeskStore.currentRevision, !liveTurnInFlight,
              generation == residualDeadline.generation, !isFlushedForTermination, !Task.isCancelled else {
            return (next, .init("held", "Carried admission changed while reading its habit suggestion."))
        }
        let kept = ResidentWake.shared.request(dataRoot: root, reason: "what you carry", items: [arrival])
        return (next, .init(kept ? "woke" : "failed", kept ? "A ready step was offered through ResidentWake." : "The carried wake was not kept.",
                           fields: ["handle": .string(best.handle), "arrival": .string(arrival.id)]))
    }

    private func runCarriedHabit(_ entry: MyQueue.Entry, at: Date, generation: UInt64) async -> MindClockResult {
        do {
            let receipt: JSONValue
            if let previous = try ResidentWake.carriedRunReceipt(entry.item, dataRoot: dataRoot, at: at) {
                receipt = previous
            } else {
                // Reserve durably before effects. An interruption becomes a
                // question for her, never permission to repeat an unknown write.
                let unknown: JSONValue = .object(["status": .string("outcome_unknown"),
                    "detail": .string("This habit's attempt was interrupted. Reconcile its effects before repeating it."),
                    "call": entry.step.action ?? .null])
                try ResidentWake.shared.recordCarriedRun(entry.item, receipt: unknown, dataRoot: dataRoot, at: at)
                receipt = await host.runCarriedAction(entry.step, handle: entry.item.handle, dataRoot: dataRoot)
                let root = dataRoot
                let saved: Result<Void, Error> = await settle {
                    Result { try ResidentWake.shared.recordCarriedRun(entry.item, receipt: receipt, dataRoot: root, at: at) }
                }
                try saved.get()
            }
            let outcome = receipt.objectValue?["result"] ?? receipt
            // Authored runs retain their own receipt, with the ability's
            // returned JSON under `returned`; native actions return directly.
            let result = outcome.objectValue?["returned"] ?? outcome
            let resultNamesOutcome = result.objectValue.map { fields in
                ["status", "state", "ok", "success", "error", "isError", "is_error"].contains { fields[$0] != nil }
            } ?? false
            let finished = ChatToolOutcome.exactResultClass(receipt) == .succeeded
                && !Self.hasUnknownHabitEffects(receipt)
                && (!resultNamesOutcome || ChatToolOutcome.exactResultClass(result) == .succeeded)
                && !ChatToolOutcome.isWaitingOnPerson(receipt) && !ChatToolOutcome.isWaitingOnPerson(result)
                && result.objectValue?["needs_me"] == nil && outcome.objectValue?["needs_me"] == nil
                && receipt.objectValue?["needs_me"] == nil
                && outcome.objectValue?["handed_back"] == nil && outcome.objectValue?["returned_note"] == nil
                && outcome.objectValue?["accounting_error"] == nil
                && (result.objectValue?["again"] == nil || result.objectValue?["again"] == .null)
            // An end in words is still hers to judge even when the call finished.
            let judgedEnd: Bool = { if case .words = MyQueue.until(entry) { return true }; return false }()
            guard finished, !judgedEnd else {
                var arrival = ResidentWake.carriedArrival(entry.item, crossing: at, dataRoot: dataRoot)
                arrival.habitReceipt = receipt
                let kept = ResidentWake.shared.request(dataRoot: dataRoot, reason: "what your habit found", items: [arrival])
                return .init(kept ? "needs_judgment" : "failed", kept ? "The habit's actual receipt was handed to her." : "The habit receipt was kept, but its wake was not.", fields: ["receipt": receipt, "handle": .string(entry.item.handle)])
            }
            guard !liveTurnInFlight, generation == residualDeadline.generation, !isFlushedForTermination, !Task.isCancelled,
                  let current = try await MyQueue.entry(entry.item.handle, store: SwiftNativeDeskStore(dataRoot: dataRoot)),
                  current.step == entry.step else { return .init("held", "The habit ran, but live admission or the step changed before settlement.", fields: ["receipt": receipt]) }
            if let words = entry.step.say, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard entry.owedToPerson(dataRoot: dataRoot) || entry.step.origin == "self" || entry.step.origin == "person" else {
                    var arrival = ResidentWake.carriedArrival(entry.item, crossing: at, dataRoot: dataRoot)
                    arrival.habitReceipt = receipt
                    let kept = ResidentWake.shared.request(dataRoot: dataRoot, reason: "what your habit found", items: [arrival])
                    return .init(kept ? "needs_judgment" : "failed", "The habit has no authority to say these words directly.", fields: ["receipt": receipt])
                }
                return await deliverCarriedSay(current, words: words, at: at, revision: SwiftNativeDeskStore.currentRevision,
                    generation: generation, habitResult: result)
            } else {
                return await settle { await self.settleCarriedDelivery(current, words: nil, habitResult: result, at: at) }
            }
        } catch {
            nativeLog("intention habit: %@ needs reconciliation: %@", entry.item.handle, error.localizedDescription)
            return .init("unavailable", "The habit needs reconciliation: " + error.localizedDescription, fields: ["handle": .string(entry.item.handle)])
        }
    }

    /// An outer success cannot confirm an inner action's uncertain effects.
    private static func hasUnknownHabitEffects(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields):
            return fields["effects"] == .string("unknown") || fields.values.contains(where: hasUnknownHabitEffects)
        case .array(let values): return values.contains(where: hasUnknownHabitEffects)
        default: return false
        }
    }

    /// Words already chosen need no thought. The speech owner reconciles an
    /// uncertain append at its original destination before permitting a retry.
    private func deliverCarriedSay(_ entry: MyQueue.Entry, words: String, at: Date,
                                   revision: UInt64, generation: UInt64, habitResult: JSONValue? = nil) async -> MindClockResult {
        let occurrence: String
        guard let condition = MyQueue.when(entry) else { return .init("unavailable", "The carried step's condition is unavailable; repair it before delivery.") }
        switch condition {
        case .every:
            guard let due = IntentionClock.occurrenceID(entry.step, at: at) else { return .init("held", "No rhythm occurrence is due.") }
            occurrence = due
        case .at(let due): occurrence = String(due.timeIntervalSince1970)
        default:
            // Presence transitions are in the carry fingerprint; a new news
            // release or person note is a new moment too, unlike her own note.
            occurrence = ResidentWake.carriedFingerprint(entry.item, at: at, dataRoot: dataRoot) + "\u{1F}"
                + (entry.item.notes.filter { $0.author != "agent" }.map(\.ts).max() ?? entry.item.openedAt)
        }
        let key = SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(
            scope: "intention.say:" + entry.item.handle, content: occurrence)
        guard let anchor = ConversationAnchor.currentSessionId(dataRoot: dataRoot) else {
            nativeLog("intention say: no current conversation for %@", entry.item.handle)
            return .init("unavailable", "There is no current conversation for the intention's words.")
        }
        do {
            // Like chat.post, stamp his conversation's route, never the turn
            // that happened to release the intention.
            let route = try await HumanConversationReader.read(sessionID: anchor, dataRoot: dataRoot).route
            guard revision == SwiftNativeDeskStore.currentRevision, !liveTurnInFlight,
                  generation == residualDeadline.generation, !isFlushedForTermination,
                  !Task.isCancelled else { return .init("held", "Admission or the Desk changed before speech.") }
            let engine = host.studioWanderClient(dataRoot: dataRoot, usesLiveAppBody: usesLiveAppBody)
            let chat = engine.chatClient(tools: engine.toolDispatchClient())
            let outcome = try await ChatToolSessionContext.$envelope.withValue(route) {
                try await ChatToolSessionContext.withReplyRoute(route?.replyRoute) {
                    try await chat.speakProactively(content: words, caller: .reachOut,
                        idempotencyKey: key, sessionId: anchor, initiative: .intention)
                }
            }
            switch outcome {
            case .posted(let session, _):
                if !Task.isCancelled, !isFlushedForTermination {
                    do {
                        _ = try await host.deliverShoulderTap(
                            eventId: key, title: PersonaCompiler.agentDisplayName(dataRoot: dataRoot),
                            body: Reach.knockLine, reason: key,
                            userInfo: ["screen": "chat", "source": "intention", "sessionId": session], at: at)
                    } catch { await recordKnockFailure(error, eventID: key) }
                }
            case .duplicate:
                // A duplicate proves the original transcript row committed.
                // Finish any Desk settlement interrupted after that append.
                break
            case .rateLimited:
                return .init("held", "The speech owner's rate limit held the intention; it stays ready.")
            }
            return await settle {
                await self.settleCarriedDelivery(entry, words: words, habitResult: habitResult, at: at)
            }
        } catch {
            // Leave it ready. Never turn a speech failure into a model wake.
            nativeLog("intention say: %@ remains ready: %@", entry.item.handle, error.localizedDescription)
            return .init("unavailable", "The intention stays ready; speech could not be confirmed: " + error.localizedDescription)
        }
    }

    private func settleCarriedDelivery(_ entry: MyQueue.Entry, words: String?, habitResult: JSONValue? = nil, at: Date) async -> MindClockResult {
        do {
            var notes: [String] = []
            if let result = habitResult {
                let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "h:mm a"
                let fields = result.objectValue
                let summary = try fields?["summary"]?.stringValue ?? fields?["detail"]?.stringValue
                    ?? fields?["confirmation"]?.stringValue ?? result.serialize(pretty: false)
                notes.append("Ran \(clock.string(from: at)): " + String(summary.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(500)))
            }
            if let words {
                notes.append("Said \(ResidentWake.shown(at)): \"\(words)\"")
            }
            // Consumption and the debt are one durable write. Recovery only
            // keeps these notes and closes the unchanged once-step.
            let debt = try ResidentWake.shared.recordCarriedDelivery(entry.item, dataRoot: dataRoot, at: at,
                reason: habitResult == nil ? "said" : "habit finished", notes: notes)
            try await finishCarriedSettlement(debt)
            return .init(words == nil ? "ran" : "said", words == nil ? "The habit completed and its Desk settlement was kept." : "The speech owner confirmed the words; their Desk settlement was kept.", fields: ["handle": .string(entry.item.handle)])
        } catch {
            nativeLog("intention delivery: %@ settlement not kept: %@", entry.item.handle, error.localizedDescription)
            return .init("failed", "Delivery finished but its settlement remains owed: " + error.localizedDescription, fields: ["handle": .string(entry.item.handle)])
        }
    }

    func finishOwedCarriedSettlements() async {
        guard !carriedSayInFlight else { return }
        carriedSayInFlight = true
        defer { carriedSayInFlight = false }
        await settle {
            do {
                for debt in try ResidentWake.owedCarriedSettlements(dataRoot: self.dataRoot) {
                    do { try await self.finishCarriedSettlement(debt) }
                    catch { nativeLog("intention settlement: %@ remains owed: %@", debt.id, error.localizedDescription) }
                }
            } catch { nativeLog("intention settlements unreadable: %@", error.localizedDescription) }
        }
    }

    private func finishCarriedSettlement(_ debt: ResidentWake.CarriedSettlement) async throws {
        guard let item = DeskItem.fromJSON(debt.item), let entry = MyQueue.entry(item) else {
            throw PersistenceCoreError.ioFailure("The intention's settlement snapshot is unreadable.")
        }
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        // Never close a refiling or a replacement intention on this handle.
        if let current = try await MyQueue.entry(item.handle, store: store), current.step == entry.step {
            for note in debt.notes {
                _ = try await store.appendNoteIfAbsent(item.handle, marker: note, text: note, author: "agent", after: item.updatedAt)
            }
            if case .once = MyQueue.until(entry) {
                // Close the fresh item while it is still the intention that ran or spoke;
                // one retry covers a write that landed between the read and the close.
                for attempt in 0..<2 {
                    guard let current = try await MyQueue.entry(entry.item.handle, store: store),
                          current.step == entry.step else { break }
                    do {
                        try await MyQueue.finish(current, dropped: false, why: debt.reason, store: store)
                        break
                    } catch is MyQueue.Superseded where attempt == 0 { continue }
                }
            }
        }
        try ResidentWake.shared.settleCarried(debt, dataRoot: dataRoot)
    }

    /// Desk touch stamps are ISO-8601, with or without fractional seconds.
    static func deskDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = NativeTimestampFormat.parseISO8601FractionalFirst(trimmed) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }
}
