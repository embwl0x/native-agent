import Foundation
import NativeAgentShared
import MacNerves
import MindCore
import SenseCore
import NativeAgentCore
import DeskCore
import PersistenceCore
import ProviderRouting

// Blueprint: | `NativeCognitionRuntime+Pursuit.swift` | Desk moments on the one clock, checked habit receipts and fixed-word delivery |

extension NativeCognitionRuntime {
    private static let maximumPursuitCandidates = 8

    /// Keep pursuit reads synchronous so a user turn cannot initiate Desk I/O.
    private func currentPursuitIntent(now: Date) -> (activeTask: String, goal: String)? {
        guard !isAdmissionClosed, pursuitReadRevision == SwiftNativeDeskStore.currentRevision else { return nil }
        let best = pursuitCandidates
            .filter { $0.isPursuit && !$0.status.isTerminal && $0.step?.causalWait == nil }
            .prefix(Self.maximumPursuitCandidates)
            .compactMap { item in DeskPursuitChoice.score(for: item, now: now).map { (item, $0.total) } }
            .max { $0.1 < $1.1 }
        guard let p = best?.0.pursuit else { return nil }
        func bound(_ s: String) -> String { String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
        return (activeTask: bound(p.why), goal: bound(p.doneLooksLike))
    }

    /// Subscribe before replay to prevent missed commits; exact-path matching keeps data roots isolated.
    func startPursuitObservationIfNeeded() async {
        guard !isAdmissionClosed, pursuitObservationTask == nil else { return }
        startCognitiveSourceObservations()
        let sourceObservations = sourceWakes
        let deskEvents = EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("desk/desk_ops.jsonl"),
            SwiftNativeDeskStore(dataRoot: dataRoot).basePath,
            SwiftNativeDeskStore(dataRoot: dataRoot).archivePath
        ])
        let events = EventDeadlinePhysiology.storeAndFileEvents(paths: [
            dataRoot.appendingPathComponent("memory/memory.sqlite"),
            dataRoot.appendingPathComponent("memory/memory.sqlite-wal"),
            dataRoot.appendingPathComponent("workflows/approvals/requests.json")
        ])
        pursuitObservationTask = Task { [weak self] in
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        for await _ in deskEvents {
                            guard !Task.isCancelled else { return }
                            await self?.pursuitSourceInvalidated()
                            await self?.reofferQueueMoments()
                        }
                    }
                    group.addTask { [weak self] in
                        for await _ in events {
                            guard !Task.isCancelled else { return }
                            await self?.pursuitSourceInvalidated()
                        }
                    }
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
        // A turn window closing can free the agent: the Desk is read again, what is due for when free comes, and owed moments are judged.
        turnIdleObservationTask = Task { [weak self, root = dataRoot] in
            for await _ in ChatTurnSteering.idleEdges(dataRoot: root) {
                guard !Task.isCancelled else { return }
                await self?.startPursuitRefresh()
                await AdaptiveMemoryPromoter.shared.drainOwedMomentsAtWake()
            }
        }
        await OneClock.at(dataRoot).handle(MyQueueReady.owner) { [weak self] time, occurrence in
            if let handle = time.payload?.objectValue?["causalHandle"]?.stringValue,
               let since = time.payload?.objectValue?["since"]?.stringValue {
                await self?.releaseCausalMoments(.time(handle: handle, since: since, occurrence: occurrence))
                return
            }
            await self?.startPursuitRefresh()
            if time.id == MyQueueReady.owner + ":owed" { await self?.reofferQueueMoments() }
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

    private func pursuitSourceInvalidated() async {
        guard !isAdmissionClosed else { return }
        pursuitRead.write {
            pursuitReadRevision = nil
            // Stop a possibly closed pursuit from steering attention immediately.
            attentionProjection.replacePursuit(activeTask: nil, goal: nil)
        }
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        await startPursuitRefresh()
    }

    func startPursuitRefresh() async {
        guard !isAdmissionClosed else { return }
        if pursuitRefreshInFlight {
            pursuitRefreshQueued = true
            return
        }
        pursuitRefreshInFlight = true
        pursuitRefreshTask = Task { [weak self] in
            await self?.finishPursuitRefresh()
        }
    }

    /// Presence edges read the Desk again: a step waiting on the person arriving or leaving comes due there.
    public func carriedPresenceChanged() async {
        await startPursuitRefresh()
    }

    /// Share part wake signal observation; the Desk release note avoids a second arrival ledger.
    public func carriedSignal(_ signal: String, payload: [String: JSONValue]) async {
        guard !isAdmissionClosed, !Task.isCancelled,
              !signal.hasPrefix("schedule:"), !["held", "resumed"].contains(signal) else { return }
        do {
            // System notes name events, never message text; words enter only through their own tainted door.
            let summary = signal.hasPrefix("file.changed:") ? "" : (payload["path"]?.stringValue).map { String($0.prefix(160)) } ?? ""
            if try await MyQueue.releaseSignal(signal, summary: summary,
                store: SwiftNativeDeskStore(dataRoot: dataRoot), at: now()) {
                await startPursuitRefresh()
            }
        } catch {
            ModuleLog(category: "Cognition")("Body signal intention release unavailable: %@", error.localizedDescription)
        }
    }

    enum CausalEdge: Sendable {
        case time(handle: String, since: String, occurrence: Date)
        case happening(Experience)
        case desk(changed: Set<String>)
    }

    func releaseCausalMoments(_ edge: CausalEdge) async {
        guard !isAdmissionClosed, !Task.isCancelled else { return }
        let revision = SwiftNativeDeskStore.currentRevision
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        do {
            let items: [DeskItem]
            if pursuitReadRevision == revision {
                items = pursuitCandidates
            } else {
                items = try await store.liveState().items
            }
            let at = now()
            let candidates = items.compactMap(MyQueue.causalEntry).filter { !MyQueue.isOver($0, at: at) }
            guard !candidates.isEmpty else { return }
            let targets: [String: DeskItem]
            let archive: [String: ArchiveRecord]
            if case .desk(let changed) = edge {
                targets = Dictionary(items.filter { changed.contains($0.handle) }.map { ($0.handle, $0) },
                    uniquingKeysWith: { first, _ in first })
                if changed.contains(where: { targets[$0] == nil }) {
                    archive = Dictionary(try await store.archivedRecords().map { ($0.handle, $0) },
                        uniquingKeysWith: { _, last in last })
                } else { archive = [:] }
            } else {
                targets = [:]
                archive = [:]
            }
            var plan: DeskSequencing.Plan?
            for entry in candidates {
                guard !isAdmissionClosed, !Task.isCancelled,
                      let wait = entry.step.causalWait, let filed = DeskClock.parseISO(wait.since) else { return }
                let cause: String, result: String
                var source: String?
                var sources = entry.step.peers + entry.step.elevated
                switch (wait.trigger, edge) {
                case let (.at(date), .time(handle, since, occurrence))
                    where handle == entry.item.handle && since == wait.since && date == occurrence && at >= date:
                    cause = since
                    result = since
                case let (.happening(kind, subject), .happening(experience)):
                    guard var happening = experience.happening, happening.kind == kind, happening.subject == subject,
                          DeskClock.parseISO(experience.at).map({ $0 > filed }) == true else { continue }
                    cause = experience.id
                    source = experience.id
                    sources += (happening.peers ?? []) + (happening.elevated ?? []) + (experience.steeredBy ?? [])
                    happening.once = ""
                    result = try JSONValue.fromEncodable(happening).serializedSHA256()
                case let (.desk(handle), .desk(changed)):
                    guard changed.contains(handle) else { continue }
                    if let target = targets[handle] {
                        cause = target.updatedAt
                        result = try MyQueue.deskResult(target)
                    } else if let target = archive[handle] {
                        cause = target.closedAt
                        result = MyQueue.deskTerminalResult(target.finalStatus.rawValue)
                    } else { continue }
                    guard DeskClock.parseISO(cause).map({ $0 > filed }) == true else { continue }
                default: continue
                }
                if plan == nil { plan = DeskSequencing.compute(DeskState(items: items, generatedTs: ""), now: at) }
                guard plan?.byHandle[entry.item.handle]?.isReady == true else { continue }
                let root = dataRoot, item = entry.item
                let prefix = MyQueue.causalPrefix(item.handle, wait)
                let key = "queue:" + item.handle
                let line = MyQueueReady.line(item, at: at, dataRoot: root)
                let evidence = source.map { " Record: " + $0 + "." } ?? ""
                let moment = Happening(.moment, subject: key, door: key, who: "self", words: line.head,
                    once: prefix + SHA256Hex.of(utf8: cause), peers: Array(Set(sources)).sorted(),
                    shows: "What you waited for came: \(wait.trigger.words)." + evidence + " " + line.rest)
                await Attention.postCausalMoment(moment, prefix: prefix, result: result, baseline: wait.baseline,
                                                 source: source, dataRoot: root).value
            }
        } catch is CancellationError {
            return
        } catch {
            owe("causal", MyQueueReady.owner, "A declared cause could not be checked: " + error.localizedDescription)
        }
    }

    /// A line of news that touches a step waiting on news releases it: the release is the step's own Desk note, and the read that follows posts its
    /// moment. Each touching line is its own release.
    func releaseNewsIntentions(touchedBy line: String, watch: String) async {
        let store = SwiftNativeDeskStore(dataRoot: dataRoot)
        let entries: [MyQueue.Entry]
        do {
            entries = MyQueue.entries(try await store.liveState()).filter {
                if case .news? = MyQueue.when($0) { return $0.step.status != "stopped" && !MyQueue.isOver($0, at: now()) }
                return false
            }
        } catch {
            ModuleLog(category: "Cognition")("News intention release unavailable: %@", error.localizedDescription)
            return
        }
        let words = entries.compactMap { entry -> (id: String, words: String)? in
            guard case .news(let words)? = MyQueue.when(entry) else { return nil }
            return (entry.item.handle, words)
        }
        guard !words.isEmpty, let touched = await substrate.newsIntentionsTouched(by: line, among: words) else { return }
        var released = false
        for handle in touched {
            guard let weighed = entries.first(where: { $0.item.handle == handle }), !isAdmissionClosed, !Task.isCancelled else { continue }
            do {
                // Check identity, topic and closure in the release-append transaction.
                if try await MyQueue.releaseNews(weighed, summary: String(line.prefix(160)) + " (" + watch + ")", store: store, at: now()) {
                    released = true
                }
            } catch {
                ModuleLog(category: "Cognition")("News release for %@ unavailable: %@", handle, error.localizedDescription)
            }
        }
        if released { await startPursuitRefresh() }
    }

    private func finishPursuitRefresh() async {
        let root = dataRoot, clock = now
        var published = false
        var signals: [(String, SomaticSignalKind)] = []
        var changedDeskTargets: Set<String> = []
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
                    if let state {
                        context = try await AgentScreen.queueContext(items: state.items, dataRoot: root, now: clock(), ownTurn: true)
                    } else { context = nil }
                    conditionsFailure = nil
                    // A clean read is the repair: the debt a failed read opened does not outlive it. Settling appends only where one is open.
                    if state != nil {
                        try? await RepairOwed.settle(ExperienceStore.at(root), operation: "queue.conditions",
                            evidence: .init(source: "desk", id: String(describing: revision)))
                    }
                } catch is CancellationError {
                    context = nil; conditionsFailure = nil
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
            guard !isAdmissionClosed, snapshot.revision == SwiftNativeDeskStore.currentRevision,
                  let state = snapshot.state else { return }
            let before = Dictionary(pursuitCandidates.map { ($0.handle, $0) }, uniquingKeysWith: { first, _ in first })
            let watched = Set(state.items.compactMap { item -> String? in
                guard let entry = MyQueue.causalEntry(item), case .desk(let handle)? = entry.step.causalWait?.trigger else { return nil }
                return handle
            })
            if !watched.isEmpty {
                let live = Dictionary(state.items.filter { watched.contains($0.handle) }.map { ($0.handle, $0.updatedAt) },
                    uniquingKeysWith: { first, _ in first })
                changedDeskTargets = Set(watched.filter { before.isEmpty || before[$0]?.updatedAt != live[$0] })
            }
            pursuitCandidates = state.items
            pursuitCarriedContext = snapshot.context
            pursuitReadRevision = snapshot.revision
            published = true
            for item in state.items {
                let wasCarried = before[item.handle].map { !$0.status.isTerminal && Self.carries($0) } == true
                guard Self.carries(item) || wasCarried else { continue }
                if item.status.isTerminal || !Self.carries(item) {
                    if wasCarried && item.status.isTerminal {
                        signals.append((item.handle, item.status == .canceled ? .deskItemCancelled : .deskItemClosed))
                    }
                } else if !wasCarried {
                    signals.append((item.handle, .deskItemCreated))
                } else if item.status == .blocked, before[item.handle]?.status != .blocked {
                    signals.append((item.handle, .deskItemBlocked))
                }
            }
        })
        if published {
            await carriedConditionsChanged()
            if !changedDeskTargets.isEmpty { await releaseCausalMoments(.desk(changed: changedDeskTargets)) }
            for (handle, kind) in signals {
                await ingestOrganismSignal(kind: kind, sourceOrgan: "carry." + handle,
                    metadata: ["predictionCorrelationId": .string(handle)],
                    persistSynchronously: false)
            }
            if !isAdmissionClosed {
                await rescheduleResidualRepairDeadline()
            }
        }

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
        guard !isAdmissionClosed else { pursuitRefreshQueued = false; return }
        let intent = currentPursuitIntent(now: now())
        attentionProjection.replacePursuit(
            activeTask: intent?.activeTask,
            goal: intent?.goal
        )
        let needsFollowUp = pursuitRefreshQueued
        pursuitRefreshQueued = false
        if needsFollowUp {
            await startPursuitRefresh()
        } else if carriedSayTask == nil {
            carriedSayTask = Task { [weak self] in await self?.considerMoments() }
        }
    }
}

extension NativeCognitionRuntime {
    static func carries(_ item: DeskItem) -> Bool {
        item.project == MyQueue.project || item.assignee == "agent"
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

    // MARK: - Moments

    /// MY QUEUE's moments from the Desk as last read. One pass at a time; a read published while a pass runs is taken by the same pass before it ends.
    func considerMoments() async {
        defer { carriedSayTask = nil }
        await finishOwedCarriedSettlements()
        var taken: Date?
        while !isAdmissionClosed, !Task.isCancelled, let context = pursuitCarriedContext, context.now != taken {
            taken = context.now
            await moments(context)
        }
    }

    /// One pass over the current read: steps whose time ran out close; what came due is posted as a moment (a habit or fixed words run as reflexes
    /// first); each open step's next time, and the agent's next free time when work waits for it, are kept on the one clock.
    private func moments(_ read: MyQueue.Context) async {
        // A read not yet published, in flight or invalidated is taken when its refresh publishes.
        guard !isAdmissionClosed, !pursuitRefreshInFlight, !pursuitRefreshQueued, let revision = pursuitReadRevision,
              revision == SwiftNativeDeskStore.currentRevision else { return }
        let items = pursuitCandidates
        let root = dataRoot, at = now()
        var context = read
        context.now = at
        let store = SwiftNativeDeskStore(dataRoot: root)
        for entry in items.compactMap(MyQueue.entry) where MyQueue.isOver(entry, at: at) {
            guard !isAdmissionClosed, !Task.isCancelled else { return }
            do {
                try await MyQueue.finish(entry, dropped: false, why: "its time ran out (until \(entry.step.until ?? ""))", store: store)
            } catch is MyQueue.Superseded {
                // The step changed or closed first; the Desk read that change triggers takes it.
            } catch is CancellationError {
                return
            } catch {
                owe("expiry", entry.item.handle, "Its time ran out, but it could not be closed: " + error.localizedDescription)
            }
        }
        let freeAt = await ChatTurnSteering.shared.turnActivityOrSeed(for: root, at: at).addingTimeInterval(MyQueue.freeAfter)
        let free = at >= freeAt && ChatTurnSteering.liveSessions(dataRoot: root).isEmpty
        let due = MyQueueReady.due(items: items, context: context, free: free)
        for moment in due.moments {
            let admission = MomentAdmission(moment: moment, revision: revision)
            // An earlier moment may have suspended while the Desk changed. The fresh read takes the remainder.
            guard currentMomentRead(admission) else { return }
            if await admits(admission) { await take(admission, at: now()) }
        }
        guard !pursuitRefreshInFlight, !pursuitRefreshQueued,
              pursuitReadRevision == revision, SwiftNativeDeskStore.currentRevision == revision else { return }
        // Select deadlines from the readiness boundary. OneClock fires a deadline that crossed during this pass
        // on declaration, requesting a fresh Desk read. After freeAt, a live turn's closing is the next free edge.
        await keepTimes(items, at: at, freeAt: due.waitingForFree && freeAt > at ? freeAt : nil)
    }

    private struct MomentAdmission {
        let moment: MyQueueReady.Moment
        let revision: UInt64
    }

    private func currentMomentRead(_ admission: MomentAdmission) -> Bool {
        !isAdmissionClosed && !Task.isCancelled && !pursuitRefreshInFlight && !pursuitRefreshQueued
            && pursuitReadRevision == admission.revision && SwiftNativeDeskStore.currentRevision == admission.revision
    }

    /// Reuse the readiness owner at the current time, including until, grace, blockers and presence; never authorize from a frozen due batch.
    private func admits(_ admission: MomentAdmission) async -> Bool {
        guard currentMomentRead(admission) else { return false }
        let freeAt = await ChatTurnSteering.shared.turnActivityOrSeed(for: dataRoot, at: now()).addingTimeInterval(MyQueue.freeAfter)
        guard currentMomentRead(admission), var context = pursuitCarriedContext else { return false }
        context.now = now()
        let free = context.now >= freeAt && ChatTurnSteering.liveSessions(dataRoot: dataRoot).isEmpty
        let due = MyQueueReady.due(items: pursuitCandidates, context: context, free: free).moments.contains {
            $0.item.handle == admission.moment.item.handle && $0.occurrence == admission.moment.occurrence
        }
        // Time alone may have crossed until/grace or a new free-time boundary; take a fresh pass to close or re-arm it.
        if !due { await startPursuitRefresh() }
        return due
    }

    /// A due step's reflex runs, or its moment is posted: a habit runs on CPU and hands the agent only what needs judgment; fixed words are said as
    /// they are and the moment still comes to her; everything else opens a thought.
    private func take(_ admission: MomentAdmission, at: Date) async {
        let moment = admission.moment
        let once = MyQueueReady.once(moment.item, moment.occurrence)
        guard let entry = MyQueue.entry(moment.item) else { await post(moment.item, once: once, at: at, admission: admission); return }
        if entry.step.action != nil {
            await runHabit(entry, once: once, at: at, admission: admission)
        } else if let words = MyQueue.spoken(entry) {
            // Quiet hours hold person-facing notifications, never the agent's work; delivery routing owns the knock.
            await deliverSay(entry, words: words, once: once, at: at, admission: admission)
        } else {
            await post(moment.item, once: once, at: at, admission: admission)
        }
    }

    /// A moment owed to the agent: it opens a thought in the agent's mind stream, or, for a promise made to the person, in the conversation it was
    /// made in, replying by its recorded route. A habit's receipt rides beside the line: handing back a run settles it, without admitting new work.
    private func post(_ item: DeskItem, once: String, at: Date, receipt: JSONValue? = nil, admission: MomentAdmission) async {
        if receipt == nil { guard await admits(admission) else { return } }
        let root = dataRoot, step = item.step
        let line = MyQueueReady.line(item, at: at, dataRoot: root)
        var shows = line.rest
        let owed = step?.owedToPerson == true
        var reply: String?
        do {
            if owed, let route = step?.replyRoute { reply = try route.serialize(pretty: false) }
            if let receipt {
                shows += "\nalready_looked at \(MyQueue.shown(at)) (your habit already ran; start from this receipt, do not blindly repeat the call): "
                let text = try receipt.serialize(pretty: false), cut = " … (cut here; make the call again for the rest)"
                let room = Happening.showsLimit - shows.count
                shows += text.count <= room ? text : String(text.prefix(max(0, room - cut.count))) + cut
            }
        } catch {
            owe("moment", item.handle, "Its moment could not be written: " + error.localizedDescription)
            return
        }
        var happening = Happening(.moment, subject: "queue:" + item.handle, door: "queue:" + item.handle, who: "self", words: line.head,
            once: once, route: owed ? step?.session : nil, reply: reply, peers: step?.peers, elevated: step?.elevated, shows: shows)
        // A suggestion is offered once a day, so only a moment not yet in the record carries one.
        if receipt == nil {
            do {
                if try await ExperienceStore.at(root).experience(happening.id) == nil,
                   let suggestion = await CarriedHabits.shared.suggestion(for: item, dataRoot: root, at: at) {
                    happening.shows = String((shows + " " + suggestion).prefix(Happening.showsLimit))
                }
            } catch {
                owe("moment", item.handle, "Its occurrence record could not be read: " + error.localizedDescription)
                return
            }
        }
        if receipt == nil { guard await admits(admission) else { return } }
        // Finish this occurrence's handoff before the carried pass can replace its run with a later occurrence.
        let accepted = happening
        await settle { await Attention.post(accepted, dataRoot: root).value }
    }

    private func runHabit(_ entry: MyQueue.Entry, once: String, at: Date, admission: MomentAdmission) async {
        let root = dataRoot, handle = entry.item.handle
        let store = SwiftNativeDeskStore(dataRoot: root)
        do {
            let receipt: JSONValue
            let ranNow: Bool
            if let run = try await MyQueueCarried.run(once: once, dataRoot: root) {
                guard run.done != true else { return }
                // A run kept before its effects is never repeated: it continues from what it returned, or goes to the agent if it never returned.
                guard let saved = run.habitReceipt else {
                    throw PersistenceCoreError.ioFailure("The saved habit run has no receipt: " + once)
                }
                receipt = saved
                ranNow = false
            } else {
                guard await admits(admission) else { return }
                let engine = try rootEngine()
                let reserved = JSONValue.object(["status": .string("outcome_unknown"),
                    "detail": .string("This habit's attempt was interrupted. Reconcile its effects before repeating it."),
                    "call": entry.step.action ?? .null])
                try await MyQueueCarried.keep(entry.item, once: once, receipt: reserved, store: store)
                guard await admits(admission) else {
                    // No call began. Withdraw only this exact reservation, so a fresh pass may admit unchanged work.
                    let withdrawn: Result<Void, Error> = await settle {
                        do { try await MyQueueCarried.withdrawUnstarted(once: once, receipt: reserved, dataRoot: root); return .success(()) }
                        catch { return .failure(error) }
                    }
                    try withdrawn.get()
                    return
                }
                receipt = await EnginePartWake.runCarried(entry.step, handle: handle, engine: engine)
                ranNow = true
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
                && outcome.objectValue?["handed_back"] == nil
                && outcome.objectValue?["accounting_error"] == nil
                && (result.objectValue?["again"] == nil || result.objectValue?["again"] == .null)
            // A completed call cannot decide its own worded end condition.
            let judgedEnd: Bool = { if case .words = MyQueue.until(entry) { return true }; return false }()
            let ran = reply.payload.objectValue?["receipts"]?.arrayValue?.compactMap(\.objectValue) ?? [reply.payload.objectValue ?? [:]]
            let looked = !ran.isEmpty && ran.allSatisfy {
                $0["read_only"] == .bool(true) && $0["action"]?.stringValue?.hasPrefix("authored.") != true
            }
            // Fixed words from other origins need judgment even when the action finished.
            let hasWords = entry.step.say.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            let words = MyQueue.spoken(entry)
            let completed = finished && !judgedEnd && !looked && (!hasWords || words != nil)
            let note: String? = if completed { try Self.habitNote(returnedReply.payload, at: at) } else { nil }
            let noteAwaitingSpeech = words == nil ? nil : note
            let pending: MyQueueCarried.Settlement?
            if ranNow || noteAwaitingSpeech != nil {
                let saved: Result<MyQueueCarried.Settlement?, Error> = await settle {
                    do {
                        return .success(try await MyQueueCarried.keep(entry.item, once: once, receipt: receipt,
                            noteAwaitingSpeech: noteAwaitingSpeech, store: store))
                    } catch { return .failure(error) }
                }
                pending = try saved.get()
            } else {
                pending = nil
            }
            guard completed else {
                await post(entry.item, once: once, at: at, receipt: reply.payload, admission: admission)
                return
            }
            if let words {
                // Speaking is new work; only the still-current step can admit it.
                if !isAdmissionClosed, !Task.isCancelled,
                   let current = try await MyQueue.entry(handle, store: store), current.step == entry.step {
                    await deliverSay(current, words: words, once: once, at: at,
                        habitNote: pending?.notes.first ?? note, admission: admission)
                }
                if let pending {
                    let unsaved: (any Error)? = await settle {
                        do { try await MyQueueCarried.finish(pending, store: store); return nil }
                        catch { return error }
                    }
                    if let unsaved { throw unsaved }
                }
            } else {
                await settle { await self.settleCarriedDelivery(entry, once: once, words: nil, habitNote: note, at: at) }
            }
        } catch is CancellationError {
            return
        } catch {
            owe("habit", handle, "Its habit needs reconciliation: " + error.localizedDescription)
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

    private static let knockLine = "Left you something in chat. No reply needed."

    /// Fixed words land in the current conversation between turns. Speech is keyed by the moment, so an uncertain delivery is reconciled at its original
    /// destination before any repeat; words that could not be said stay due and are tried again at the next read, never turned into a thought.
    private func deliverSay(_ entry: MyQueue.Entry, words: String, once: String, at: Date, habitNote: String? = nil,
                            admission: MomentAdmission) async {
        let root = dataRoot, handle = entry.item.handle
        let key = SwiftNativeChatOrchestrationClient.proactiveSpeechIdempotencyKey(scope: "intention.say:" + handle, content: once)
        guard let anchor = ConversationAnchor.currentSessionId(dataRoot: root) else {
            nativeLog("intention say: no current conversation for %@", handle)
            return
        }
        do {
            if habitNote == nil, try await MyQueueCarried.run(once: once, dataRoot: root)?.done == true {
                await post(entry.item, once: once, at: at, admission: admission)
                return
            }
            // Stamp the destination conversation's route rather than the turn that released the intention.
            let route = try await HumanConversationReader.read(sessionID: anchor, dataRoot: root).route
            guard ChatTurnSteering.liveSessions(dataRoot: root).isEmpty, await admits(admission) else { return }
            let engine = try rootEngine()
            let chat = engine.chatClient(tools: engine.toolDispatchClient(enforceAppAutonomy: false))
            let turn = Turn(dataRoot: root, session: anchor).with(\.envelope, route)
            let outcome = try await chat.speakProactively(content: words, caller: .reachOut,
                idempotencyKey: key, sessionId: anchor, turn: turn)
            switch outcome {
            case .posted(let session, _):
                if !Task.isCancelled, !isAdmissionClosed {
                    do {
                        let attention = engine.ports.backgroundWork.attention
                        guard attention.dataRoot.standardizedFileURL == root.standardizedFileURL else {
                            throw PersistenceCoreError.ioFailure("Notification delivery is unavailable for this data root.")
                        }
                        try await attention.tell(Matter(id: key, form: .words, from: "intention",
                            title: PersonaCompiler.agentDisplayName(dataRoot: root), summary: Self.knockLine, open: "chat:" + session),
                            reach: .person(from: nil), at: at, turn: turn)
                    } catch { await knockFailed(error, eventID: key) }
                }
            case .duplicate:
                // A duplicate proves the append committed; finish any interrupted Desk settlement.
                break
            }
            await settle { await self.settleCarriedDelivery(entry, once: once, words: words, habitNote: habitNote, at: at) }
        } catch {
            nativeLog("intention say: %@ stays due: %@", handle, error.localizedDescription)
        }
    }

    private func knockFailed(_ error: Error, eventID: String) async {
        RepairOwed.owe(dataRoot, id: "notification:" + eventID, kind: .run,
            operation: "cognition.notification:" + eventID, owner: "AttentionRouter",
            words: "The words were posted, but their notification is unavailable: " + error.localizedDescription,
            tap: "Repair notification delivery in Settings → Doctor. Do not post the words again.")
        await substrate.recordReceipt(kind: "notification.unavailable", payload: .object([
            "eventId": .string(eventID), "speech": .string("posted"),
            "error": .string(error.localizedDescription),
        ]))
    }

    private static func habitNote(_ result: JSONValue, at: Date) throws -> String {
        let clock = DateFormatter(); clock.locale = Locale(identifier: "en_US_POSIX"); clock.dateFormat = "h:mm a"
        let fields = result.objectValue
        let summary = try fields?["summary"]?.stringValue ?? fields?["detail"]?.stringValue
            ?? fields?["confirmation"]?.stringValue ?? result.serialize(pretty: false)
        return "Ran \(clock.string(from: at)): " + String(summary.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(500))
    }

    private func settleCarriedDelivery(_ entry: MyQueue.Entry, once: String, words: String?, habitNote: String?, at: Date) async {
        do {
            var notes = [habitNote].compactMap { $0 }
            if let words {
                notes.append("Said \(MyQueue.shown(at)): \"\(words)\"")
            }
            // Spend the moment and record its Desk debt in one write; recovery closes only the unchanged once-step.
            let store = SwiftNativeDeskStore(dataRoot: dataRoot)
            let debt = try await MyQueueCarried.delivered(entry.item, once: once, notes: notes,
                reason: habitNote == nil ? "said" : "habit finished", store: store)
            try await MyQueueCarried.finish(debt, store: store)
        } catch {
            owe("settlement", entry.item.handle, "Its delivery finished but its Desk settlement remains owed: " + error.localizedDescription)
        }
    }

    /// Delivered effects whose Desk notes and once-close did not land yet are finished; each debt is its own, and one that fails stays owed.
    func finishOwedCarriedSettlements() async {
        await settle {
            do {
                let store = SwiftNativeDeskStore(dataRoot: self.dataRoot)
                for debt in try await MyQueueCarried.owedSettlements(dataRoot: store.dataRoot) {
                    do { try await MyQueueCarried.finish(debt, store: store) }
                    catch { nativeLog("intention settlement: %@ remains owed: %@", debt.id, error.localizedDescription) }
                }
            } catch { nativeLog("intention settlements unreadable: %@", error.localizedDescription) }
        }
    }

    private func keepTimes(_ items: [DeskItem], at: Date, freeAt: Date?) async {
        let clock = OneClock.at(dataRoot)
        var wanted: [String: OneClock.Time] = [:]
        for item in items {
            if let entry = MyQueue.causalEntry(item), let wait = entry.step.causalWait,
               case .at(let date) = wait.trigger, !MyQueue.isOver(entry, at: at) {
                let id = MyQueueReady.causalTime(item.handle)
                wanted[id] = OneClock.Time(id: id, next: date,
                    payload: .object(["causalHandle": .string(item.handle), "since": .string(wait.since)]))
            }
            guard let next = MyQueueReady.next(item, after: at) else { continue }
            let id = MyQueueReady.time(item.handle)
            wanted[id] = OneClock.Time(id: id, rhythm: MyQueueReady.rhythm(item), next: next, payload: .object(["handle": .string(item.handle)]))
        }
        if let freeAt { wanted[MyQueueReady.freeTime] = OneClock.Time(id: MyQueueReady.freeTime, next: freeAt) }
        let owedTime = MyQueueReady.owner + ":owed"
        do {
            let parked = Set(items.filter { $0.step?.causalWait != nil }.map { "queue:" + $0.handle })
            let offers = try await Attention.owed(dataRoot: dataRoot).filter {
                guard let happening = $0.happening else { return false }
                return happening.kind == .moment && happening.subject.hasPrefix("queue:")
                    && !MyQueue.isCausalMoment(happening) && !parked.contains(happening.subject)
            }.compactMap { NativeTimestampFormat.parseISO8601FractionalFirst($0.at) }.map { born in
                var offset: TimeInterval = 60
                while born + offset <= at { offset += min(offset, 1800) }
                return born + offset
            }
            if let next = offers.min() { wanted[owedTime] = OneClock.Time(id: owedTime, next: next) }
        } catch { owe("clock", owedTime, "What is still owed could not be read, so it is not offered again on the clock: " + error.localizedDescription) }
        do {
            for time in try await clock.times(owner: MyQueueReady.owner) where wanted[time.id] == nil {
                do { try await clock.withdraw(time.id) }
                catch { owe("clock", time.id, "Its time could not be withdrawn from the clock: " + error.localizedDescription) }
            }
        } catch { owe("clock", MyQueueReady.owner, "MY QUEUE's times could not be read from the clock: " + error.localizedDescription) }
        for time in wanted.values {
            do { try await clock.declare(time) }
            catch { owe("clock", time.id, "Its time could not be kept on the clock, so it would not come: " + error.localizedDescription) }
        }
    }

    /// A MY QUEUE failure is owed as a repair on what it concerns; a repeat joins the open debt.
    private func owe(_ operation: String, _ subject: String, _ words: String) {
        nativeLog("MY QUEUE %@ %@: %@", operation, subject, words)
        RepairOwed.owe(dataRoot, id: "queue." + operation + ":" + subject, kind: .run, operation: "queue." + operation, owner: subject,
            words: subject + ": " + words, tap: "Repair the named storage, preserving its records; the Desk's next read takes the step again.")
    }
}
