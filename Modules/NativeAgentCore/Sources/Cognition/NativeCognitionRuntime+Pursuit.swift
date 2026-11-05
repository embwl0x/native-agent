import Foundation
import NativeAgentShared
import ChatTurnRuntime
import ChatToolParsing
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

// Blueprint: | `NativeCognitionRuntime+Pursuit.swift` | NativeCognitionRuntime+Pursuit owner. |

extension NativeCognitionRuntime: MyQueueTurnProjectionProviding {
    public func queueTurnCandidates() -> (candidates: [DeskItem]?, refreshPendingAfterWrite: Bool) {
        let revision = SwiftNativeDeskStore.currentRevision
        return (pursuitReadRevision == revision && !isFlushedForTermination ? pursuitCandidates : nil,
                !isFlushedForTermination && pursuitCompletedRefreshRevision != revision)
    }

    private static let maximumPursuitCandidates = 8

    /// Keep pursuit reads synchronous so a user turn cannot initiate Desk I/O.
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

    /// Subscribe before replay to prevent missed commits; exact-path matching keeps data roots isolated.
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
        // Reconsider waiting work when the live turn's window closes.
        turnIdleObservationTask = Task { [weak self, root = dataRoot] in
            for await _ in ChatTurnSteering.idleEdges(dataRoot: root) {
                guard !Task.isCancelled else { return }
                await self?.rescheduleResidualRepairDeadline()
            }
        }
    }

    /// Serialize condition settlement against the live Desk so concurrent completions cannot write stale copies.
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
            // Stop a possibly closed pursuit from steering attention immediately.
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

    /// Presence edges use the same carried refresh and deadline path as Desk edits without waiting for a turn.
    public func carriedPresenceChanged() async {
        await startPursuitRefresh()
    }

    /// Share part wake signal observation; the Desk release note avoids a second arrival ledger.
    public func carriedSignal(_ signal: String, payload: [String: JSONValue], suppressing echoes: Set<String> = []) async {
        guard !isFlushedForTermination, !Task.isCancelled,
              !signal.hasPrefix("schedule:"), !["held", "resumed"].contains(signal) else { return }
        do {
            // System notes name events, never message text; words enter only through their own tainted door.
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
                // A commit during replay invalidates the read rather than relabelling it.
                let revision = SwiftNativeDeskStore.currentRevision
                let state: DeskState?, readFailure: String?
                do { state = try await SwiftNativeDeskStore(dataRoot: root).liveState(); readFailure = nil }
                catch is CancellationError { state = nil; readFailure = nil }
                catch { state = nil; readFailure = "the Desk could not be read: " + error.localizedDescription }
                let context: MyQueue.Context?, conditionsFailure: String?
                do {
                    context = try state.map { _ in try AgentScreen.queueContext(dataRoot: root, now: clock(), ownTurn: true) }
                    conditionsFailure = nil
                } catch {
                    context = nil
                    conditionsFailure = "queue conditions are unavailable: " + error.localizedDescription
                    // Do not append repeat evidence on every failed refresh or the reader would wake itself.
                    do {
                        if try await RepairOwed.openDebt(ExperienceStore.at(root), operation: "queue.conditions", owner: root.path) == nil {
                            await RepairOwed.owe(root, id: UUID().uuidString, kind: .run, operation: "queue.conditions", owner: root.path,
                                words: "Queue conditions are unavailable: \(error.localizedDescription). Carried work is not admitted from this reading.",
                                tap: "Repair the reported approval or conversation storage, preserving all records.").value
                        }
                    } catch { ModuleLog(category: "Cognition")("Queue condition failure could not be retained: %@", error.localizedDescription) }
                }
                return (state: state, revision: revision, context: context, failure: readFailure ?? conditionsFailure)
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
            // A condition may settle before its wait reaches the Desk.
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
            // Finish bootstrap replay before signal ingestion can await that bootstrap; later writes join the same tail.
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
        // The refresh is judged by what it read: a Desk that would not read fails it, and a read Desk counts its open carried steps.
        if let failure = snapshot.failure {
            OrganJudge.beat("pursuit_refresh", .failed, note: failure)
        } else if let state = snapshot.state {
            let carried = state.items.filter { Self.carries($0) && !$0.status.isTerminal }.count
            OrganJudge.beat("pursuit_refresh", carried > 0 ? .worked : .nothing, note: "\(carried) carried steps open on the Desk",
                yield: carried)
        }
        guard !isFlushedForTermination else { pursuitRefreshQueued = false; return }
        let intent = currentPursuitIntent(now: now())
        attentionProjection.replacePursuit(
            activeTask: intent?.activeTask,
            goal: intent?.goal
        )
        let needsFollowUp = pursuitRefreshQueued
        pursuitRefreshQueued = false
        // Failed refresh is unavailable rather than permanently pending.
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

    /// Share salience, deadline ownership and the existing wake door.
    func considerCarried(runNow: Bool = false, besides session: String? = nil) async -> (next: Date?, result: MindClockResult) {
        guard !isFlushedForTermination, !carriedSayInFlight else { return (nil, .waiting("Carried work is running or the runtime is stopping.")) }
        await finishOwedCarriedSettlements()
        // A snapshot not yet read, in flight or invalidated waits for the pursuit refresh, whose own beat reports a Desk that would not read.
        guard !isFlushedForTermination, !carriedSayInFlight, !pursuitRefreshInFlight, !pursuitRefreshQueued,
              let revision = pursuitReadRevision, let candidates = queueTurnCandidates().candidates,
              var context = pursuitCarriedContext else { return (nil, .waiting(
                  "The current Desk readiness snapshot is not available; no work was selected.")) }
        let at = now(), root = dataRoot
        let generation = residualDeadline.generation
        guard candidates.contains(where: { Self.carries($0) && !$0.isPursuit }) else { return (nil, .init("nothing",
            "The current Desk snapshot contains no carried step.")) }
        guard !liveTurnInFlight(besides: session) else { return (nil, .waiting("A live turn is in flight.")) }
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
        guard revision == SwiftNativeDeskStore.currentRevision else { return (nil, .waiting("The Desk changed during the readiness read.")) }
        guard let opportunities = ResidentWake.carriedOpportunities(dataRoot: root,
            items: candidates.filter { Self.carries($0) && !$0.isPursuit }, at: at) else {
            return (nil, .init("unavailable", "The carried wake ledger could not be read and kept; readiness is unknown."))
        }
        var next: Date?, best: DeskItem?
        var readyByTime: [Date: Set<String>] = [:]
        for item in candidates {
            let entry = MyQueue.entry(item)
            // Project next occurrence and end boundaries even while an intention cannot be offered.
            if let step = entry?.step, let upcoming = IntentionClock.next(step, after: at) { next = min(next ?? upcoming, upcoming) }
            if let ends = entry.flatMap({ MyQueue.until($0).endsAt }), ends > at { next = min(next ?? ends, ends) }
            guard let wakeAt = opportunities[item.handle] else { continue }
            var crossing = wakeAt
            let moment = entry.flatMap(MyQueue.when)
            if case .at(let due)? = moment { crossing = max(crossing, due) }
            if case .every? = moment, let step = entry?.step {
                guard let due = IntentionClock.occurrence(step, at: at) ?? IntentionClock.next(step, after: at) else { continue }
                crossing = max(crossing, due)
            }
            if let deferred = item.deferUntil.flatMap(DeskSequencing.parseDeferStamp) { crossing = max(crossing, deferred) }
            // Clock, person, news and body signals arrive promptly; other work waits for free time.
            if moment?.isPrompt != true { crossing = max(crossing, quietAt) }
            context.now = max(at, crossing)
            let ready = readyByTime[context.now] ?? Set(MyQueueReady.ready(items: candidates, context: context).map(\.handle))
            readyByTime[context.now] = ready
            guard ready.contains(item.handle) else { continue }
            if crossing > at { next = min(next ?? crossing, crossing); continue }
            if let current = best {
                if Self.carriedTouch(item, at: at) < Self.carriedTouch(current, at: at) { best = item }
            } else { best = item }
        }
        guard let best else { return (next, .waiting(
            "No carried step is ready at the real time; readiness, occurrence, defer and offer-rest gates still apply.")) }
        let freedom = StudioWanderLane.decide(now: at, turnInFlight: liveTurnInFlight,
            lastTurnActivityAt: lastTurnActivityAt, lastWanderAt: nil, satisfyWait: runNow)
        let prompt = MyQueue.entry(best).flatMap(MyQueue.when)?.isPrompt ?? false
        guard freedom == .wander || prompt else {
            guard freedom == .notQuiet else { return (next, .waiting(freedom.rawValue)) }
            let freeAt = Date(timeIntervalSinceReferenceDate: quietAt.timeIntervalSinceReferenceDate.nextUp)
            return (min(next ?? freeAt, freeAt), .waiting(freedom.rawValue))
        }
        guard revision == SwiftNativeDeskStore.currentRevision else { return (nil, .waiting("The Desk changed before admission.")) }
        guard !liveTurnInFlight, !carriedSayInFlight,
              generation == residualDeadline.generation, !isFlushedForTermination, !Task.isCancelled else { return (next, .init("held",
                  "Carried admission changed before execution.")) }
        if let entry = MyQueue.entry(best), entry.step.action != nil {
            carriedSayInFlight = true
            defer { carriedSayInFlight = false }
            return (next, await runCarriedHabit(entry, at: at, generation: generation))
        }
        // A worded end condition needs the agent's judgment on every occurrence.
        if let entry = MyQueue.entry(best), let words = entry.step.say,
           !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           { if case .words = MyQueue.until(entry) { return false }; return true }(),
           entry.step.origin == "self" || entry.owedToPerson {
            // Quiet hours hold person-facing notifications, never the agent's work; delivery routing owns the knock.
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
                // Reserve durably before effects; an interrupted write requires reconciliation rather than permission to repeat.
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
            let reply = ToolResult(receipt)
            let outcome = reply.payload.objectValue?["result"] ?? reply.payload
            // Read authored results from returned; native action replies are direct.
            let result = outcome.objectValue?["returned"] ?? outcome
            let returnedReply = ToolResult(result)
            let resultNamesOutcome = result.objectValue.map { fields in
                ["status", "state", "ok", "success", "error", "isError", "is_error"].contains { fields[$0] != nil }
            } ?? false
            let finished = reply.outcome == .succeeded
                && !Self.hasUnknownHabitEffects(reply.payload)
                && (!resultNamesOutcome || returnedReply.outcome == .succeeded)
                && !ChatToolOutcome.isWaitingApproval(reply.payload) && !reply.isWaitingInteraction
                && !ChatToolOutcome.isWaitingApproval(returnedReply.payload) && !returnedReply.isWaitingInteraction
                && result.objectValue?["needs_me"] == nil && outcome.objectValue?["needs_me"] == nil
                && receipt.objectValue?["needs_me"] == nil
                && outcome.objectValue?["handed_back"] == nil && outcome.objectValue?["returned_note"] == nil
                && outcome.objectValue?["accounting_error"] == nil
                && (result.objectValue?["again"] == nil || result.objectValue?["again"] == .null)
            // A completed call cannot decide its own worded end condition.
            let judgedEnd: Bool = { if case .words = MyQueue.until(entry) { return true }; return false }()
            guard finished, !judgedEnd else {
                var arrival = ResidentWake.carriedArrival(entry.item, crossing: at, dataRoot: dataRoot)
                arrival.habitReceipt = reply.payload
                let kept = ResidentWake.shared.request(dataRoot: dataRoot, reason: "what your habit found", items: [arrival])
                return .init(kept ? "needs_judgment" : "failed", kept ? "The habit's actual receipt was handed to the agent."
                    : "The habit receipt was kept, but its wake was not.", fields: ["receipt": reply.payload, "handle": .string(entry.item.handle)])
            }
            guard !liveTurnInFlight, generation == residualDeadline.generation, !isFlushedForTermination, !Task.isCancelled,
                  let current = try await MyQueue.entry(entry.item.handle, store: SwiftNativeDeskStore(dataRoot: dataRoot)),
                  current.step == entry.step else { return .init("held", "The habit ran, but live admission or the step changed before settlement.",
                      fields: ["receipt": reply.payload]) }
            if let words = entry.step.say, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard entry.step.origin == "self" || entry.owedToPerson else {
                    var arrival = ResidentWake.carriedArrival(entry.item, crossing: at, dataRoot: dataRoot)
                    arrival.habitReceipt = reply.payload
                    let kept = ResidentWake.shared.request(dataRoot: dataRoot, reason: "what your habit found", items: [arrival])
                    return .init(kept ? "needs_judgment" : "failed", "The habit has no authority to say these words directly.",
                        fields: ["receipt": reply.payload])
                }
                return await deliverCarriedSay(current, words: words, at: at, revision: SwiftNativeDeskStore.currentRevision,
                    generation: generation, habitResult: returnedReply.payload)
            } else {
                return await settle { await self.settleCarriedDelivery(current, words: nil, habitResult: returnedReply.payload, at: at) }
            }
        } catch {
            nativeLog("intention habit: %@ needs reconciliation: %@", entry.item.handle, error.localizedDescription)
            return .init("unavailable", "The habit needs reconciliation: " + error.localizedDescription, fields: ["handle": .string(entry.item.handle)])
        }
    }

    /// Outer success cannot confirm uncertain inner effects.
    private static func hasUnknownHabitEffects(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let fields):
            let reply = ToolResult(value)
            return reply.effects == .unknown || fields.values.contains(where: hasUnknownHabitEffects)
        case .array(let values): return values.contains(where: hasUnknownHabitEffects)
        default: return false
        }
    }

    /// Reconcile uncertain speech at its original destination before permitting a retry.
    private func deliverCarriedSay(_ entry: MyQueue.Entry, words: String, at: Date,
                                   revision: UInt64, generation: UInt64, habitResult: JSONValue? = nil) async -> MindClockResult {
        let occurrence: String
        guard let condition = MyQueue.when(entry) else { return .init("unavailable",
            "The carried step's condition is unavailable; repair it before delivery.") }
        switch condition {
        case .every:
            guard let due = IntentionClock.occurrenceID(entry.step, at: at) else { return .init("held", "No rhythm occurrence is due.") }
            occurrence = due
        case .at(let due): occurrence = String(due.timeIntervalSince1970)
        default:
            // Include presence transitions and new external notes in carry identity; the agent's own note is not a new moment.
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
            // Stamp the destination conversation's route rather than the turn that released the intention.
            let route = try await HumanConversationReader.read(sessionID: anchor, dataRoot: dataRoot).route
            guard revision == SwiftNativeDeskStore.currentRevision, !liveTurnInFlight,
                  generation == residualDeadline.generation, !isFlushedForTermination,
                  !Task.isCancelled else { return .init("held", "Admission or the Desk changed before speech.") }
            let engine = host.studioWanderClient(dataRoot: dataRoot, usesLiveAppBody: usesLiveAppBody)
            let chat = engine.chatClient(tools: engine.toolDispatchClient())
            let turn = Turn(session: anchor).with(\.envelope, route)
            let outcome = try await chat.speakProactively(content: words, caller: .reachOut,
                idempotencyKey: key, sessionId: anchor, initiative: .intention, turn: turn)
            switch outcome {
            case .posted(let session, _):
                if !Task.isCancelled, !isFlushedForTermination {
                    do {
                        _ = try await host.deliverShoulderTap(
                            eventId: key, title: PersonaCompiler.agentDisplayName(dataRoot: dataRoot),
                            body: Reach.knockLine, reason: key,
                            userInfo: ["screen": "chat", "source": "intention", "sessionId": session], at: at, turn: turn)
                    } catch { await recordKnockFailure(error, eventID: key) }
                }
            case .duplicate:
                // A duplicate proves the append committed; finish any interrupted Desk settlement.
                break
            case .rateLimited:
                return .init("held", "The speech owner's rate limit held the intention; it stays ready.")
            }
            return await settle {
                await self.settleCarriedDelivery(entry, words: words, habitResult: habitResult, at: at)
            }
        } catch {
            // Keep failed speech ready; never turn it into a model wake.
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
            // Consume and record debt in one write; recovery closes only the unchanged once-step.
            let debt = try ResidentWake.shared.recordCarriedDelivery(entry.item, dataRoot: dataRoot, at: at,
                reason: habitResult == nil ? "said" : "habit finished", notes: notes)
            try await finishCarriedSettlement(debt)
            return .init(words == nil ? "ran" : "said", words == nil ? "The habit completed and its Desk settlement was kept."
                : "The speech owner confirmed the words; their Desk settlement was kept.", fields: ["handle": .string(entry.item.handle)])
        } catch {
            nativeLog("intention delivery: %@ settlement not kept: %@", entry.item.handle, error.localizedDescription)
            return .init(
                "failed",
                "Delivery finished but its settlement remains owed: " + error.localizedDescription,
                fields: ["handle": .string(entry.item.handle)]
            )
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
        // Never close a refiled or replacement intention through this handle.
        if let current = try await MyQueue.entry(item.handle, store: store), current.step == entry.step {
            for note in debt.notes {
                _ = try await store.appendNoteIfAbsent(item.handle, marker: note, text: note, author: "agent", after: item.updatedAt)
            }
            if case .once = MyQueue.until(entry) {
                // Close only the still-matching intention; one retry covers a concurrent write between read and close.
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

    /// Accept Desk touch stamps with or without fractional seconds.
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
