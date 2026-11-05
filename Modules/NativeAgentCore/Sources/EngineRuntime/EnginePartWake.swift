import AuthoredCapabilities
import ApprovalTransactions
import AgentConversations
import AgentWorkspace
import AppToolRuntime
import BackgroundLoops
import BackgroundWork
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ChatToolParsing
import Cognition
import Desk
import Foundation
import Experiences
import MacControl
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import ToolExecution
import TurnTrace
import NativeAgentShared
import AppKit
// Blueprint: | `EnginePartWake.swift` | `EnginePartWake`, `start`, `deliver`, `run`, `readsOnly`, `reindex`, `held`, `resumed`, `holdBack`, `tainted_signal`, `changed`, `changed_more`, `person.away`, `person.here`, `network.down`, `network.up`, `AgentOpened` |

/// Deliver source signals after their own work settles, including durable turn terminals. Schedules belong to TriggerScheduler and file watches to
/// senses; this owner never polls. Autonomy and unreadable catalogs hold wakes without consuming their input; source subscriptions retain their helper
/// generation. Each unattended run gets its own resident gate chain, approval route, current Trust and source taint; approvals wait through quiet hours.
/// Suppress self-write and self-turn echoes, and serialize arrivals through one ResidentWake thread.
actor EnginePartWake {
    static let shared = EnginePartWake()
    /// Unreadable catalogs leave the signal index unavailable, never empty.
    private var index: [String: [AbilityStore.File]]?
    private var watched: [String: [URL]] = [:]
    /// Share the senses watch for each declared `file.changed:` path.
    private var watches: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var unavailableFileWatches: Set<String> = []
    private var intentionFiles: [String: Set<String>] = [:]
    private let intentionRead = LatestRead()
    private var deskObservation: Task<Void, Never>?
    /// One run at a time per part, so a resident part keeps one context.
    private var runs: [UUID: (part: String, source: Bool, task: Task<Void, Never>)] = [:]
    private var tails: [String: UUID] = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var workspaceCenter: NotificationCenter?
    private var lifecycle: UUID?
    private var stopped = false
    /// Retain signal receipt, not presence state, so late sources can refine departure without signalling absence twice.
    private var lastSignalledPresence: Bool?
    /// Coalesce identical pending news per part.
    private var waiting: [String: UUID] = [:]
    /// Coalesce file news by part and watched path without dropping member changes.
    private var fileInputs: [UUID: [String: JSONValue]] = [:]
    /// Hold wakes across Autonomy or catalog unavailability without losing source helper generations.
    private var heldBack: [String: (signal: String, part: String?, payload: [String: JSONValue])] = [:]
    /// Observe Trust only while wakes are held.
    private var autonomyWatch: Task<Void, Never>?
    private var retiringWatches: [UUID: Task<Void, Never>] = [:]

    private func retireWatch(_ task: Task<Void, Never>?, cancel: Bool = true) {
        guard let task else { return }
        if cancel { task.cancel() }
        let id = UUID()
        retiringWatches[id] = Task {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            self.retiringWatches.removeValue(forKey: id)
        }
    }

    /// Register before loop sources fire; sense consumers own readiness.
    func start(dataRoot: URL) async {
        guard lifecycle == nil, !stopped, !Task.isCancelled else { return }
        let epoch = UUID()
        lifecycle = epoch
        let root = dataRoot.standardizedFileURL
        let center = NotificationCenter.default
        // Carry the completed turn’s own steering taint into its signal.
        TurnTraceEvent.steer = { turn in
            if let taint = turn.peerSteering, taint.isTainted { return taint.sourceDescription }
            let envelope = TurnEnvelope.current(turn: turn, surface: "")
            guard PeerTurnEffectPolicy.isPeerBridge(surface: envelope.surface), !PeerDataTaint.trustedTurn(turn) else { return nil }
            return envelope.verifiedUserId.map { "peer:" + $0 } ?? "another agent"
        }
        observers.append(center.addObserver(forName: AbilityStore.signalled, object: nil, queue: nil) { note in
            guard note.object as? String == root.path, let signal = note.userInfo?["signal"] as? String else { return }
            let part = note.userInfo?["part"] as? String
            let payload = note.userInfo?["payload"] as? [String: JSONValue] ?? [:]
            Task { await Self.shared.signalled(signal, only: part, payload, dataRoot: root, epoch: epoch) }
        })
        observers.append(center.addObserver(forName: .turnTraceTerminalPersisted, object: nil, queue: nil) { note in
            guard let info = note.userInfo, let seq = info["seq"] as? Int64,
                  let turn = info["turnId"] as? String, let kind = info["kind"] as? String else { return }
            var payload: [String: JSONValue] = ["turn_id": .string(turn), "outcome": .string(kind),
                "seq": .int(seq),
                "session_id": (info["sessionId"] as? String).map(JSONValue.string) ?? .null]
            if let steer = info["agent"] as? String { payload["agent"] = .string(steer) }
            let starter = info["part"] as? String
            let resident = info["sessionId"] as? String == ResidentWake.session
            let wake = payload
            Task {
                guard await Self.holdsDetail(seq: seq, turn: turn, kind: kind, dataRoot: root) else { return }
                if resident { Task { await EngineCarriedHabits.record(turn: turn, dataRoot: root) } }
                await Self.shared.signalled("turn.ended", except: starter, wake, dataRoot: root, epoch: epoch)
            }
        })
        // Dispatch closure can persist after the terminal; its closing trace repeats the idempotent read after dispatches land.
        observers.append(center.addObserver(forName: .turnTraceDispatchClosedPersisted, object: nil, queue: nil) { note in
            guard let info = note.userInfo, let seq = info["seq"] as? Int64,
                  let turn = info["turnId"] as? String else { return }
            Task {
                guard await Self.holdsDetail(seq: seq, turn: turn, kind: "tool.dispatch.closed", dataRoot: root) else { return }
                await EngineCarriedHabits.record(turn: turn, dataRoot: root)
            }
        })
        observers.append(center.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { _ in
            Task { await Self.shared.refresh(dataRoot: root, epoch: epoch) }
        })
        let desk = SwiftNativeDeskStore(dataRoot: root)
        let deskChanges = EventDeadlinePhysiology.storeAndFileEvents(paths: [desk.opsPath, desk.basePath])
        deskObservation = Task {
            for await _ in deskChanges {
                guard self.lifecycle == epoch, !Task.isCancelled else { return }
                await self.refreshIntentions(dataRoot: root, epoch: epoch)
            }
        }
        await refreshIntentions(dataRoot: root, epoch: epoch)
        guard lifecycle == epoch, !Task.isCancelled else { return }
        // Use shared sense transitions to avoid duplicate body signals.
        observers.append(center.addObserver(forName: MacPersonInput.presenceChanged, object: nil, queue: nil) { note in
            guard let signal = note.userInfo?["signal"] as? String else { return }
            let idle = note.userInfo?["idle_seconds"] as? Double ?? 0
            Task { await Self.shared.presence(signal, idle: idle, dataRoot: root, epoch: epoch) }
        })
        MacPersonInput.startPresenceWakes()
        observers.append(center.addObserver(forName: PhoneSenseHistory.changed, object: nil, queue: nil) { note in
            let source = note.userInfo?["source"] as? String
            let at = note.userInfo?["timestamp"] as? Date
            Task { await Self.shared.phonePresence(source: source, at: at, dataRoot: root, epoch: epoch) }
        })
        let workspace = await MainActor.run { NSWorkspace.shared.notificationCenter }
        guard lifecycle == epoch, !Task.isCancelled else { return }
        workspaceCenter = workspace
        for (name, awake) in [(NSWorkspace.didWakeNotification, true), (NSWorkspace.willSleepNotification, false)] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await Self.shared.awake(awake, dataRoot: root, epoch: epoch) }
            })
        }
        observers.append(center.addObserver(forName: NetworkSense.changed, object: nil, queue: nil) { note in
            guard let up = note.userInfo?["is_up"] as? Bool else { return }
            Task { await Self.shared.network(up, dataRoot: root, epoch: epoch) }
        })
        _ = NetworkSense.isUp
        // Resume each part with the code and state that knows what it held.
        await deliver("resumed", [:], dataRoot: root, epoch: epoch)
    }

    private func presence(_ signal: String, idle: Double, dataRoot: URL, epoch: UUID) async {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        let reading = PersonPresence.read(dataRoot: dataRoot)
        guard let transition = reading.transition else { return }
        await NativeAgentEngine.cognitionRuntime(for: dataRoot).rhythmPresenceChanged(here: transition.here)
        guard lifecycle == epoch, !Task.isCancelled else { return }
        // A newer callback can run during suspension; never overwrite its receipt with an older reading.
        if let current = PersonPresence.read(dataRoot: dataRoot).transition {
            signalPresence(current.here, payload: ["idle_seconds": .double(idle)], dataRoot: dataRoot)
        }
        await NativeAgentEngine.cognitionRuntime(for: dataRoot).carriedPresenceChanged()
    }

    private func phonePresence(source: String?, at: Date?, dataRoot: URL, epoch: UUID) async {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        let reading = PersonPresence.read(dataRoot: dataRoot)
        if source == "motion", let at, let transition = reading.transition, transition.here == false, transition.since == at {
            signalPresence(false, payload: ["source": .string("phone motion")], dataRoot: dataRoot)
        }
        await NativeAgentEngine.cognitionRuntime(for: dataRoot).carriedPresenceChanged()
    }

    private func signalPresence(_ here: Bool, payload: [String: JSONValue], dataRoot: URL) {
        guard lastSignalledPresence != here else { return }
        // Record before posting or suspending because both source callbacks share this actor.
        lastSignalledPresence = here
        AbilityStore(dataRoot: dataRoot).signal(here ? "person.here" : "person.away", payload)
    }

    private func network(_ up: Bool, dataRoot: URL, epoch: UUID) {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        AbilityStore(dataRoot: dataRoot).signal(up ? "network.up" : "network.down", ["is_up": .bool(up)])
    }

    private func awake(_ awake: Bool, dataRoot: URL, epoch: UUID) async {
        guard lifecycle == epoch else { return }
        await NativeAgentEngine.cognitionRuntime(for: dataRoot).rhythmAwakeChanged(awake: awake)
    }

    func stop() async {
        stopped = true
        lifecycle = nil // Close admission before cancelling any resident work.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for observer in workspaceObservers { workspaceCenter?.removeObserver(observer) }
        workspaceObservers.removeAll()
        workspaceCenter = nil
        for watch in watches.values { retireWatch(watch.task) }
        watches.removeAll(); watched.removeAll()
        unavailableFileWatches.removeAll()
        retireWatch(deskObservation); deskObservation = nil
        intentionRead.write { replaceIntentionFiles([:]) }
        let admitted = runs.values.map(\.task)
        for task in admitted { task.cancel() }
        tails.removeAll(); waiting.removeAll(); fileInputs.removeAll(); heldBack.removeAll()
        retireWatch(autonomyWatch); autonomyWatch = nil
        index = nil
        // Capture and join settling runs before retiring their dependencies.
        await settle { for task in admitted { await task.value } }
        while !retiringWatches.isEmpty {
            let watches = Array(retiringWatches.values)
            for watch in watches { watch.cancel() }
            await settle { for watch in watches { await watch.value } }
        }
    }

    /// Release intentions only at the original source edge; held delivery is not a second release.
    private func signalled(_ signal: String, only: String? = nil, except: String? = nil,
                           _ payload: [String: JSONValue], dataRoot: URL, epoch: UUID) async {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        var echoes = Set<String>()
        if signal.hasPrefix("file.changed:") {
            for (pattern, handles) in intentionFiles where MyQueue.signalMatches(signal, pattern: pattern, dataRoot: dataRoot) {
                for handle in handles where PhysiologySelfWriteRegistry.shared.isSelfWriteEcho(
                    loopId: PhysiologySelfWriteRegistry.intentionWriteID("carry." + handle, Self.watchedURL(pattern, dataRoot: dataRoot))) {
                    echoes.insert(handle)
                }
            }
        }
        await NativeAgentEngine.cognitionRuntime(for: dataRoot).carriedSignal(signal, payload: payload, suppressing: echoes)
        await deliver(signal, only: only, except: except, payload, dataRoot: dataRoot, epoch: epoch)
    }

    private func deliver(_ signal: String, only: String? = nil, except: String? = nil,
                         _ payload: [String: JSONValue], dataRoot: URL, epoch: UUID) async {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        // Source subscriptions use the same admission owner even without a wake header.
        if signal == "sense.source.changed", let part = only,
           case .string(let slot)? = payload["slot"],
           case .string(let value)? = payload["generation"], let generation = UUID(uuidString: value) {
            let key = part + "\u{0}" + slot + "\u{0}" + value
            let id = UUID()
            guard waiting[key] == nil else { return }
            waiting[key] = id
            let previous = tails[part].flatMap { runs[$0]?.task }
            let task = Task.detached(priority: .utility) {
                await self.runSource(part, key: key, id: id, epoch: epoch, previous: previous,
                                     slot: slot, generation: generation, dataRoot: dataRoot)
            }
            runs[id] = (part, true, task)
            tails[part] = id
            return
        }
        await refresh(dataRoot: dataRoot, epoch: epoch)
        guard lifecycle == epoch, !Task.isCancelled else { return }
        let indexed = Self.indexedSignal(signal, dataRoot: dataRoot)
        let fileNews = signal.hasPrefix("file.changed:") && payload["changed"] != nil
        // Queue identity excludes member paths but retains provenance, including peer taint.
        let identity = fileNews ? payload.filter { !["path", "changed", "changed_more"].contains($0.key) } : payload
        let news = (fileNews ? indexed : signal) + ((try? JSONValue.object(identity).serialize(pretty: false)) ?? "")
        guard let index else {
            // Keep unread wakes pending until the catalog reads again.
            if ["held", "resumed"].contains(signal) { heldBack[(only ?? "") + "\u{0}" + news] = (signal, only, payload) }
            return
        }
        let parts = (index[indexed] ?? []).filter { (only == nil || $0.id == only) && $0.id != except }
        guard !parts.isEmpty else { return }
        // Keep wake evidence separate from part input, which receives `input.wake`.
        var input = payload
        input["signal"] = .string(signal)
        input["at"] = .string(ISO8601DateFormatter().string(from: Date()))
        for file in parts {
            let key = file.id + "\u{0}" + news
            let id = UUID()
            if let pending = waiting[key] {
                if fileNews, let earlier = fileInputs[pending] {
                    fileInputs[pending] = Self.mergeFileNews(earlier, input, watched: Self.watchedURL(signal, dataRoot: dataRoot).path)
                }
                continue
            }
            waiting[key] = id
            if fileNews { fileInputs[id] = input }
            let previous = tails[file.id].flatMap { runs[$0]?.task }
            let task = Task {
                defer { self.finished(file.id, id: id, key: key, epoch: epoch) }
                await previous?.value
                guard self.lifecycle == epoch, !Task.isCancelled else { return }
                let input = self.fileInputs.removeValue(forKey: id) ?? input
                self.begin(key, id: id)
                // A busy resident part retains its wake for fresh admission after the call settles.
                repeat {
                    // Recheck Autonomy at execution because it may change while queued.
                    let allowed = await UnattendedWork.allowed(dataRoot: dataRoot)
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    self.reindex(dataRoot: dataRoot)
                    // Retain held and resumed wakes while the catalog is unavailable.
                    if self.index == nil, ["held", "resumed"].contains(signal) {
                        return self.holdBack(key, signal, part: file.id, payload, dataRoot: dataRoot, epoch: epoch)
                    }
                    guard let current = self.index?[indexed]?.first(where: { $0.id == file.id }) else { return }
                    guard allowed else {
                        if ["held", "resumed"].contains(signal) { self.holdBack(key, signal, part: file.id, payload, dataRoot: dataRoot, epoch: epoch) }
                        return nativeLog("[wake] %@ did not wake %@: Autonomy is off", signal, file.id)
                    }
                    // Suppress exact self-write echoes rather than interpreting them as news.
                    if signal.hasPrefix("file.changed:"),
                       PhysiologySelfWriteRegistry.shared.isSelfWriteEcho(loopId: Self.echo(file.id, Self.watchedURL(signal, dataRoot: dataRoot))) { return }
                    await Self.run(current, input: input, dataRoot: dataRoot)
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    // A source arrival has no caller deadline; lifecycle cancellation and slot release end this wait.
                    let waited = await OwnedProgramRunner.waitedForSlot(file.id, dataRoot: dataRoot, deadline: nil)
                    guard self.lifecycle == epoch, !Task.isCancelled, waited else { return }
                } while true
            }
            runs[id] = (file.id, false, task)
            tails[file.id] = id
        }
    }

    private func runSource(_ part: String, key: String, id: UUID, epoch: UUID,
                           previous: Task<Void, Never>?, slot: String, generation: UUID, dataRoot: URL) async {
        defer { finished(part, id: id, key: key, epoch: epoch) }
        await previous?.value
        guard lifecycle == epoch, !Task.isCancelled else { return }
        begin(key, id: id)
        let allowed = await UnattendedWork.allowed(dataRoot: dataRoot)
        guard lifecycle == epoch, !Task.isCancelled else { return }
        if allowed {
            do {
                try await SensesHub.shared.waitUntilReady()
                guard lifecycle == epoch, !Task.isCancelled else { return }
                guard let runner = SensesHub.shared.runner else {
                    throw SenseFailure(code: "source_unavailable", message: "The sense runner is not installed.")
                }
                await runner.sourceChanged(slot: slot, generation: generation)
            } catch is CancellationError { return }
            catch { nativeLog("[wake] source wake unavailable for %@: %@", part, error.localizedDescription) }
        } else {
            holdBack(key, "sense.source.changed", part: part,
                     ["slot": .string(slot), "generation": .string(generation.uuidString)], dataRoot: dataRoot, epoch: epoch)
        }
    }

    private func begin(_ key: String, id: UUID) {
        if waiting[key] == id { waiting.removeValue(forKey: key) }
    }

    private func finished(_ part: String, id: UUID, key: String, epoch: UUID) {
        runs.removeValue(forKey: id)
        fileInputs.removeValue(forKey: id)
        guard lifecycle == epoch else { return }
        begin(key, id: id)
        if tails[part] == id { tails.removeValue(forKey: part) }
    }

    /// Process-wide notices carry a sequence; only the matching written detail in this root can wake its parts.
    private static func holdsDetail(seq: Int64, turn: String, kind: String, dataRoot: URL) async -> Bool {
        guard seq > 0 else { return false }
        do {
            let read = try await TurnTracePersistLane(dataRootOverride: dataRoot)
                .events(.init(subjects: [turn], kinds: [kind], after: seq - 1, limit: 1))
            return read.isClean && read.lastSeq == seq && read.events.first?.turnId == turn
        } catch {
            nativeLog("part wake detail %lld could not be read: %@", seq, error.localizedDescription)
            return false
        }
    }

    /// Preserve successive member changes and count source or merge omissions.
    private static func mergeFileNews(_ earlier: [String: JSONValue], _ later: [String: JSONValue], watched: String) -> [String: JSONValue] {
        guard case .array(let first)? = earlier["changed"], case .array(let next)? = later["changed"] else { return later }
        var merged = later
        merged["path"] = earlier["path"] == later["path"] ? earlier["path"] : .string(watched)
        let changes = first + next
        merged["changed"] = .array(Array(changes.prefix(50)))
        var more = Int64(max(0, changes.count - 50))
        for payload in [earlier, later] {
            if case .int(let omitted)? = payload["changed_more"] { more += omitted }
        }
        merged["changed_more"] = more > 0 ? .int(more) : nil
        return merged
    }

    /// Held arrivals stay unread; only `resumed` continues held work. Retain newest source material and recheck Trust both at policy changes and delivery.
    private func holdBack(_ key: String, _ signal: String, part: String, _ payload: [String: JSONValue], dataRoot: URL, epoch: UUID) {
        heldBack[key] = (signal, part, payload)
        guard autonomyWatch == nil else { return }
        let policy = dataRoot.appendingPathComponent("trust/policy.json")
        autonomyWatch = Task {
            // The first policy edge covers a switch-on before watch registration.
            let changes = FileChangeEvents(paths: [policy])
            for await _ in changes.stream {
                if await UnattendedWork.allowed(dataRoot: dataRoot) { break }
            }
            changes.cancel()
            guard self.lifecycle == epoch, !Task.isCancelled else { return }
            self.retireWatch(self.autonomyWatch, cancel: false)
            self.autonomyWatch = nil
            await self.releaseHeld(dataRoot: dataRoot, epoch: epoch)
        }
    }

    private func releaseHeld(dataRoot: URL, epoch: UUID) async {
        retireWatch(autonomyWatch); autonomyWatch = nil
        let pending = heldBack
        heldBack.removeAll()
        for wake in pending.values {
            guard lifecycle == epoch, !Task.isCancelled else { return }
            await deliver(wake.signal, only: wake.part, wake.payload, dataRoot: dataRoot, epoch: epoch)
        }
    }

    private static func run(_ file: AbilityStore.File, input: [String: JSONValue], dataRoot: URL) async {
        let wake = "wake-" + UUID().uuidString.lowercased()
        let taint = PeerDataTaint()
        if case .string(let agent)? = input["agent"], !PeerTrust.ownerTrusts(agent, dataRoot: dataRoot) { taint.mark(peer: agent) }
        let work = "wake:" + file.id
        let turn = Turn(id: wake, run: wake, session: ResidentWake.session)
            .with(\.envelope, .native(work)).with(\.verifiedSessionID, ResidentWake.session)
            .with(\.partID, file.id).with(\.peerSteering, taint).with(\.speechInitiative, taint.isTainted ? .scheduled : .intention)
        // Tainted signals may reach only read-only parts; effectful parts skip with a trace because a card itself is a decision.
        let readOnly: Bool
        do {
            if taint.isTainted { readOnly = try Self.readsOnly(file, dataRoot: dataRoot) }
            else { readOnly = false }
        }
        catch {
            await RepairOwed.owe(dataRoot, id: "wake-classification:" + wake, kind: .run,
                operation: "wake.classification:\(file.id)", owner: "abilities/\(file.id)",
                words: """
                    Wake admission could not read the action catalog: \(error.localizedDescription). Repair the catalog before this part handles another \
                    peer-steered wake.
                    """).value
            TurnTraceBus.fire(TurnTraceEvent(turnId: wake, kind: "part.wake", sessionId: ResidentWake.session, surface: "chat",
                payload: .object(["part": .string(file.id), "result": .object(["status": .string("unavailable"),
                    "reason": .string("action_catalog_unavailable"), "detail": .string(error.localizedDescription), "effects": .string("none")])]), turn: turn))
            return
        }
        if taint.isTainted, !readOnly {
            let peer = taint.sourceDescription
            // Read peer identity from authenticated contact bindings, never steering text; name every authenticated peer or none.
            let sources: [String] = if case .string(let agent)? = input["agent"] { agent.components(separatedBy: ", ") } else { [] }
            let names = sources.map { PeerDataTaint.sourceName($0) }
            let tap = !names.isEmpty && names.allSatisfy({ $0 != nil })
                ? names.compactMap { $0 }.map { "Trust > Connected agents > " + $0 }.joined(separator: "; ") : nil
            let failure = CapabilityLifecycle.peerRefusal(peer, tap: tap)
            nativeLog("[wake] %@ skipped a tainted %@ signal: it can write", file.id, String(describing: input["signal"]))
            let result: JSONValue = .object(["status": .string("skipped"), "reason": .string("tainted_signal"),
                "detail": .string(failure.message), "remedy": Repair.why(owner: failure.owner ?? "peer \(peer) (not elevated)",
                    tap: failure.tap ?? "Trust > Connected agents (steering peer unidentified)")])
            TurnTraceBus.fire(TurnTraceEvent(turnId: wake, kind: "part.wake",
                sessionId: ResidentWake.session, surface: "chat",
                payload: .object(["part": .string(file.id), "input": .object(input), "result": result]), turn: turn))
            return
        }
        // A watch's signal is its pacing, as an intention's moment is: its notices skip the hourly quota and stay
        // deduplicated. A peer-steered signal keeps the quota.
        let result = await throughOwnDoor(work: work, turn: turn, dataRoot: dataRoot, wake: .object(input)) { door in
            if file.kind == .sense { return try await sense(file.id, input: .object(["wake": .object(input)]), turn: door.turn) }
            // Provide wake material through `input.wake`, never the part’s own input.
            let call: [String: JSONValue] = ["action": .string("authored." + file.id), "args": .object([:])]
            return try await door.perform("app", call)
        }
        // Every unattended run must leave a resident-session trace.
        TurnTraceBus.fire(TurnTraceEvent(turnId: wake, kind: "part.wake",
            sessionId: ResidentWake.session, surface: "chat",
            payload: .object(["part": .string(file.id), "input": .object(input), "result": Self.outcome(result)]), turn: turn))
    }

    /// Retain carried steering when admitting a habit as the agent’s own call.
    static func runCarried(_ step: DeskStep, handle: String, dataRoot: URL) async -> JSONValue {
        guard await UnattendedWork.allowed(dataRoot: dataRoot) else {
            return .object(["status": .string("refused"), "reason": .string("autonomy_off"),
                "detail": .string("The habit did not run: Autonomy is off."), "effects": .string("none")])
        }
        guard let call = DeskStep.plannedAction(step.action)?.objectValue else {
            return .object(["status": .string("refused"), "reason": .string("invalid_action"), "effects": .string("none"),
                "detail": .string("The stored habit is not {action,args?}; repair or drop it with queue.update.")])
        }
        let action = call["action"]?.stringValue ?? ""
        let part = action.hasPrefix("authored.") ? String(action.dropFirst(9)) : nil
        let taint = PeerDataTaint(restoring: step.peers, elevated: step.elevated)
        taint.keep(line: step.words)
        let run = "habit-" + UUID().uuidString.lowercased()
        let work = "carry." + handle
        let turn = Turn(id: run, run: run, session: ResidentWake.session)
            .with(\.envelope, .native(work)).with(\.verifiedSessionID, ResidentWake.session)
            .with(\.partID, part).with(\.peerSteering, taint).with(\.speechInitiative, .intention)
        let result = await throughOwnDoor(work: work, turn: turn, dataRoot: dataRoot) { door in
            try await door.perform("app", call)
        }
        TurnTraceBus.fire(TurnTraceEvent(turnId: run, kind: "habit.run", sessionId: ResidentWake.session, surface: "chat",
            payload: .object(["workIdentity": .string(work), "call": .object(call), "result": Self.outcome(result)]), turn: turn))
        return result
    }

    /// Share one unattended posture and gate chain across signalled parts and carried moments, without a planning model.
    private static func throughOwnDoor(work: String, turn: Turn, dataRoot: URL, wake: JSONValue? = nil,
        operation: @escaping @Sendable (PartDoor) async throws -> JSONValue) async -> JSONValue {
        let wrote: @Sendable (URL) -> Void = { url in
            PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: echo(turn.partID ?? work, url))
            if work.hasPrefix("carry.") {
                PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: PhysiologySelfWriteRegistry.intentionWriteID(work, url))
            }
        }
        let engine = NativeAgentEngine.forRoot(dataRoot)
        let client = engine.chatClient(profile: .background)
        AgentOpened.shared.began(turn.id)
        let result = await TurnTraceContext.$turnId.withValue(turn.id) {
            do {
                return try await client.withCurrentChatModel(turn: turn) { turn, admit in
                    try await engine.tools.withPartDoor(envelope: .native(work), turn: turn,
                        wake: wake, wrote: wrote, admitModel: { turn in
                            guard let turn else { throw PartError.invalid("The model call has no originating turn.") }
                            return try await admit(turn)
                        }) { door in
                        try Task.checkCancellation()
                        return try await operation(door)
                    }
                }
            } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
        }
        await settle { AgentOpened.shared.ended(turn.id, dataRoot: dataRoot) }
        return result
    }

    /// Read-only requires every declared capability and dependency action to be a read by the registry’s classification.
    private static func readsOnly(_ file: AbilityStore.File, dataRoot: URL) throws -> Bool {
        if file.kind == .part, let own = try AppActions.authored(dataRoot: dataRoot, turn: nil).first(where: { $0.id == "authored." + file.id }) {
            return own.read
        }
        var capabilities: [String] = [], actions: [String] = []
        if case .object(let reach)? = file.metadata["reach"], case .array(let list)? = reach["capabilities"] {
            capabilities = list.compactMap { if case .string(let s) = $0 { return s }; return nil }
        }
        if case .object(let record)? = file.metadata["record"], case .array(let list)? = record["actions"] {
            actions = list.compactMap { if case .string(let s) = $0 { return s }; return nil }
        }
        let capabilitiesRead = capabilities.allSatisfy { ["app_data_read", "computer_files"].contains($0) || $0.hasPrefix("app_read:") }
        return try capabilitiesRead && actions.allSatisfy { try AppActions.action($0, dataRoot: dataRoot, turn: nil)?.read == true }
    }

    /// Bound outcome detail so its trace row is never cut.
    private static func outcome(_ result: JSONValue) -> JSONValue {
        guard case .object(let fields) = result else { return result }
        return .object(fields.filter { ["status", "reason", "detail", "effects", "log", "remedy"].contains($0.key) })
    }

    /// Deliver sense wakes through the resident owner.
    private static func sense(_ id: String, input: JSONValue, turn: Turn) async throws -> JSONValue {
        let hub = SensesHub.shared
        try await hub.waitUntilReady()
        guard let receiver = hub.runner, let source = hub.source,
              let record = try await hub.registry?.all().first(where: { $0.id == id && $0.status == .on }) else {
            throw SenseFailure(code: "unavailable", message: "Sense \(id) is off, or the senses are not installed.")
        }
        try Task.checkCancellation()
        if case .failed(let failure) = await receiver.run(record, request: .event(input), source: source,
            operation: .init(turn: turn, passive: true)) {
            throw failure
        }
        return .object(["status": .string("ok")])
    }

    /// Resolve relative and `workspace/` paths from the agent’s workspace, never the app’s working directory.
    private static func watchedURL(_ signal: String, dataRoot: URL) -> URL {
        NativeAgentWorkspaceRoot.resolveFileEntryPath(
            NativeAgentWorkspaceRoot.fileSpelling(String(signal.dropFirst(13))), dataRoot: dataRoot)
    }
    private static func indexedSignal(_ signal: String, dataRoot: URL) -> String {
        signal.hasPrefix("file.changed:") ? "file.changed:" + watchedURL(signal, dataRoot: dataRoot).path : signal
    }
    private static func echo(_ part: String, _ url: URL) -> String { "part:" + part + ":" + url.standardizedFileURL.path }

    /// Register Desk before the first read; older reads cannot restore a closed watch.
    private func refreshIntentions(dataRoot: URL, epoch: UUID) async {
        _ = await intentionRead.read({ () -> Result<[String: Set<String>], Error> in
            do {
                let state = try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()
                let now = Date()
                var files: [String: Set<String>] = [:]
                for entry in MyQueue.entries(state) {
                    guard case .signal(let name)? = MyQueue.when(entry), name.hasPrefix("file.changed:"),
                          entry.step.status != "stopped", !MyQueue.isOver(entry, at: now) else { continue }
                    files[Self.indexedSignal(name, dataRoot: dataRoot), default: []].insert(entry.item.handle)
                }
                return .success(files)
            } catch { return .failure(error) }
        }, publish: { result in
            guard lifecycle == epoch, !Task.isCancelled else { return }
            switch result {
            case .success(let files): replaceIntentionFiles(files)
            case .failure(let error):
                replaceIntentionFiles([:])
                nativeLog("[wake] intention file watches stopped: Desk does not read (%@)", error.localizedDescription)
            }
            reindex(dataRoot: dataRoot)
        })
    }

    /// Preserve stamps for unchanged canonical paths; release them on closure, unreadability or shutdown.
    private func replaceIntentionFiles(_ files: [String: Set<String>]) {
        for (signal, handles) in intentionFiles {
            let url = URL(fileURLWithPath: String(signal.dropFirst("file.changed:".count)))
            for handle in handles.subtracting(files[signal] ?? []) {
                PhysiologySelfWriteRegistry.shared.clear(loopId: PhysiologySelfWriteRegistry.intentionWriteID("carry." + handle, url))
            }
        }
        for (signal, handles) in files {
            let url = URL(fileURLWithPath: String(signal.dropFirst("file.changed:".count)))
            for handle in handles.subtracting(intentionFiles[signal] ?? []) {
                PhysiologySelfWriteRegistry.shared.register(
                    loopId: PhysiologySelfWriteRegistry.intentionWriteID("carry." + handle, url), paths: [url])
            }
        }
        intentionFiles = files
    }

    /// Catalog recovery must deliver wakes held while it was unreadable.
    private func refresh(dataRoot: URL, epoch: UUID) async {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        let unread = index == nil
        reindex(dataRoot: dataRoot)
        if unread, index != nil, !heldBack.isEmpty { await releaseHeld(dataRoot: dataRoot, epoch: epoch) }
    }

    private func reindex(dataRoot: URL) {
        let files: [AbilityStore.File]
        do { files = try AbilityStore(dataRoot: dataRoot).files(includeProposals: false) }
        catch {
            index = nil
            watched.removeAll()
            updateFileWatches(dataRoot: dataRoot)
            let failure = error as? ToolFailureError ?? AbilityStore(dataRoot: dataRoot).repairFailure(
                source: dataRoot.appendingPathComponent("abilities"), detail: error.localizedDescription)
            RepairOwed.owe(dataRoot, id: "parts-index:" + UUID().uuidString.lowercased(), kind: .run,
                operation: "parts.index", owner: failure.owner ?? dataRoot.appendingPathComponent("abilities").path,
                words: """
                    Part wakes stopped because the catalog did not read: \(error.localizedDescription). Preserve the named source before repairing it; old \
                    wake wiring is not current authority.
                    """,
                nextCall: failure.nextCall)
            return nativeLog("[wake] part wakes stopped: abilities do not read (%@)", error.localizedDescription)
        }
        var built: [String: [AbilityStore.File]] = [:]
        for file in files {
            for signal in Set(file.wakes.map({ Self.indexedSignal($0, dataRoot: dataRoot) })) {
                built[signal, default: []].append(file)
            }
        }
        index = built
        let live = Set(files.filter { !$0.wakes.isEmpty }.map(\.id))
        // Source wakes retain their helper generation even without a wake header.
        for run in runs.values where !run.source && !live.contains(run.part) { run.task.cancel() }
        // Cancelled tasks retain serialization until exit; identity-checked cleanup must not remove a newly admitted arrival.
        waiting = waiting.filter { _, id in runs[id].map { $0.source || live.contains($0.part) } ?? false }
        heldBack = heldBack.filter { _, wake in
            // The runner owns source generation fencing even without a wake header.
            wake.signal == "sense.source.changed"
                || (wake.part.map { part in built[Self.indexedSignal(wake.signal, dataRoot: dataRoot)]?.contains(where: { $0.id == part }) == true } ?? true)
        }
        watched = watched.filter { live.contains($0.key) }
        if heldBack.isEmpty { retireWatch(autonomyWatch); autonomyWatch = nil }
        RepairOwed.settle(dataRoot, operation: "parts.index", evidence: .init(source: "abilities", id: "index-rebuilt:" + UUID().uuidString.lowercased()))
        for file in files where live.contains(file.id) {
            let paths = file.wakes.filter { $0.hasPrefix("file.changed:") }.map { Self.watchedURL($0, dataRoot: dataRoot) }
            guard watched[file.id] != paths else { continue }
            watched[file.id] = paths
            for url in paths { PhysiologySelfWriteRegistry.shared.register(loopId: Self.echo(file.id, url), paths: [url]) }
        }
        updateFileWatches(dataRoot: dataRoot)
    }

    private func updateFileWatches(dataRoot: URL) {
        let wanted = Set((index ?? [:]).keys.filter { $0.hasPrefix("file.changed:") }).union(intentionFiles.keys)
        unavailableFileWatches.formIntersection(wanted)
        for signal in Set(watches.keys).subtracting(wanted) { retireWatch(watches.removeValue(forKey: signal)?.task) }
        for signal in wanted where watches[signal] == nil {
            guard let epoch = lifecycle else { return }
            let file = Self.watchedURL(signal, dataRoot: dataRoot).path
            let generation = UUID()
            let task = Task {
                defer {
                    // Actual exit retires only its subscription, never a replacement admitted during cancellation.
                    if watches[signal]?.id == generation { watches.removeValue(forKey: signal) }
                }
                var last: [String: [Int64]]?
                func unavailable(_ failure: SenseFailure) async {
                    unavailableFileWatches.insert(signal)
                    let detail = "File watch unavailable: " + failure.message
                    nativeLog("[wake] %@ %@", signal, detail)
                    await SenseNewsBoard.shared.keep(SenseNews(senseID: "file-watch", version: 1,
                        address: signal, summary: detail, at: Date(), observationID: file))
                }
                func news(_ now: [String: [Int64]], available: Bool) {
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    // Repair proves availability even without a prior identity, never guessed membership additions.
                    let paths = last.map { before in
                        Set(before.keys).union(now.keys).filter { before[$0] != now[$0] }.sorted()
                    } ?? []
                    guard !paths.isEmpty || available else { return }
                    let changed: [JSONValue] = paths.prefix(50).map { path in
                        let change = last?[path] == nil ? "added" : now[path] == nil ? "removed" : "edited"
                        return .object(["path": .string(path), "change": .string(change)])
                    }
                    var payload: [String: JSONValue] = ["path": .string(paths.count == 1 ? paths[0] : file), "changed": .array(changed)]
                    if available { payload["available"] = .bool(true) }
                    if paths.count > 50 { payload["changed_more"] = .int(Int64(paths.count - 50)) }
                    AbilityStore(dataRoot: dataRoot).signal(signal, payload)
                }
                let corner = SenseCorner.fileKind(URL(fileURLWithPath: file).pathExtension.lowercased())
                // Arm before readiness reads so repair racing the bounded wait stays buffered.
                let repairs = EventDeadlinePhysiology.storeAndFileEvents(paths: [], notifications: [SensesHub.didBecomeReady])
                var ready = repairs.makeAsyncIterator()
                while !Task.isCancelled {
                    do {
                        try await SensesHub.shared.waitUntilReady()
                        break
                    } catch is CancellationError { return }
                    catch {
                        guard self.lifecycle == epoch, !Task.isCancelled else { return }
                        await unavailable(SenseFailure(error, code: "source_unavailable"))
                        // A missing repair edge leaves this subscription unavailable; Stop retires its wait without blocking resident ownership.
                        guard await ready.next() != nil else { return }
                    }
                }
                do {
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    guard let provider = SensesHub.shared.source as? any SenseSourceWatchingProvider else {
                        throw SenseFailure(code: "source_unavailable", message: "The senses' file source is not installed.")
                    }
                    // This passive subscription has no turn, action callback or enclosing read deadline.
                    let stream = try await provider.changes(for: corner, address: file, operation: .init(turn: nil, passive: true))
                    for await change in stream {
                        guard self.lifecycle == epoch, !Task.isCancelled else { return }
                        switch change {
                        case .changed(_, let identity):
                            guard let identity else {
                                await unavailable(SenseFailure(code: "source_unavailable", message: "The file source supplied no checked membership identity."))
                                continue
                            }
                            let available = unavailableFileWatches.remove(signal) != nil
                            if available {
                                await SenseNewsBoard.shared.keep(SenseNews(senseID: "file-watch", version: 1,
                                    address: signal, summary: "File watch available again.", at: Date(), observationID: file))
                            }
                            news(identity, available: available)
                            last = identity
                        case .absent:
                            // Checked root absence is an empty baseline; deletion removes members and creation adds them.
                            let available = unavailableFileWatches.remove(signal) != nil
                            if available {
                                await SenseNewsBoard.shared.keep(SenseNews(senseID: "file-watch", version: 1,
                                    address: signal, summary: "File watch available again; watched path is absent.", at: Date(), observationID: file))
                            }
                            news([:], available: available)
                            last = [:]
                        case .unavailable(let failure):
                            // Retain the admitted identity on failure; unreadability never proves member removal.
                            await unavailable(failure)
                        }
                    }
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    await unavailable(SenseFailure(code: "source_unavailable",
                        message: "Source observation ended; a part/catalog change registers the source again."))
                } catch {
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    await unavailable(SenseFailure(code: "source_unavailable", message: error.localizedDescription))
                }
            }
            watches[signal] = (generation, task)
        }
    }
}
