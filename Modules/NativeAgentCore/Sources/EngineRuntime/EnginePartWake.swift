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
// Blueprint: | `EnginePartWake.swift` | `EnginePartWake`: `start`, `deliver`, `run`, `readsOnly`, `reindex`; one signal observer feeds parts and cognition's intention releases; open intentions join header-declared file watches by canonical path through a LatestRead Desk projection, retired on closure, with bounded directory-member identities from the senses' shared manifest; Autonomy-gated wake index, per-part single flight, including source-triggered sense interpretation (material/transport stay source-owned, bundled senses need no wake header); a `held`, `resumed` or source-subscription wake Autonomy refused waits (`holdBack`, preserving source slot/helper generation independently of the header index) and is delivered when a trust-policy change finds the switch on; unreadable authority clears the part index with repair owed, and a `held` or `resumed` wake meanwhile waits for it to read again; tainted signals skip write-capable parts (`tainted_signal` trace, no card); gated resident tools/skills and resident senses; sense header/source wakes await readiness at their own read, each file subscription bounds readiness then reports unavailable news and waits for the installer's success edge until repair or Stop, without holding unrelated part signals; current Chat model and signal audit; file-change watches name added/edited/removed members in capped `changed` records with `changed_more`, keep the declared signal and self-write scope, consume the source owner's explicit change/absent/unavailable readings, clear membership only on checked absence, retire only the exiting subscription generation, and merge waiting member news per part/watched path; directory metadata churn is not a member edit; stop joins runs and all current/replaced file, Desk and trust watchers; turn-end steer retained; `resumed` delivered once at launch; `person.away`/`person.here` read PersonPresence from Mac input edges and durable phone motion, refreshing carried readiness; the first presence deadline is armed from existing idle after this observer registers; `network.down`/`network.up` arrive from the shared NetworkSense after a five-second stable path, through the same AbilityStore signal and intention release path; header-declared runs are `HerOpened` work |

/// The stem delivering signals (AGENT_IS_THE_APP S4). A source that fired
/// posts `AbilityStore.signalled` after its own work (a turn's end is its
/// durable terminal row); each part whose `wake` lists the signal runs once
/// with it as input: a tool or skill through the door, the way a turn calls
/// it (a resident part keeps its context), a sense through its resident
/// owner. Nothing here polls or keeps a clock: a schedule is the part's
/// TriggerScheduler job, a declared file is the senses' own watch, the rest
/// are posted by their sources. Like every unattended runner, nothing runs
/// while the owner's Autonomy switch is off; a `held` arrival waits for it,
/// since what came stays unread and nothing more is read until its part runs,
/// and so does `resumed`, since nothing else takes up what a part held;
/// either also waits out a catalog that does not read.
/// A live sense's explicit source subscription is already its wake: its
/// newest captured material returns through this same per-part admission,
/// without requiring a second subscription in the part header. Its wake
/// waits out Autonomy too, retaining the source slot and helper generation.
///
/// A run has no turn behind it, so it gets its own gate chain (contract #2):
/// principal her, on her resident session, so a card it raises reaches the
/// person like any approval and the run waits for it, through his quiet
/// hours too; autonomy the current Trust level; origin the signal; taint when
/// the signal carries the words of anyone the person has not trusted.
///
/// A part is not woken by its own hand: its own writes to a file it watches
/// are echoes, a turn its run started does not wake it, and its arrivals
/// share one ResidentWake thread.
actor EnginePartWake {
    static let shared = EnginePartWake()
    /// Each signal's parts, rebuilt when a part changes; nil while the catalog does not read.
    private var index: [String: [AbilityStore.File]]?
    /// The files each part watches, as the self-write registry holds them.
    private var watched: [String: [URL]] = [:]
    /// `file.changed:` through the senses' watch, one per declared path.
    private var watches: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Receipt of the last unavailable source reading, including exited tasks.
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
    /// Receipt of the last presence signal, not a presence reading. A late
    /// source can refine the departure time without signalling absence twice.
    private var lastSignalledPresence: Bool?
    /// The same signal already waiting for a part is the same news.
    private var waiting: [String: UUID] = [:]
    /// File arrivals keep one waiting input per part/watched path, with all its news.
    private var fileInputs: [UUID: [String: JSONValue]] = [:]
    /// `held` and `resumed` wakes wait out Autonomy or an unread catalog;
    /// source wakes wait out Autonomy with their helper generation intact.
    private var heldBack: [String: (signal: String, part: String?, payload: [String: JSONValue])] = [:]
    /// The trust policy's own watch, only while something is held back.
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

    /// Once at launch before loop sources fire; sense consumers own readiness.
    func start(dataRoot: URL) async {
        guard lifecycle == nil, !stopped, !Task.isCancelled else { return }
        let epoch = UUID()
        lifecycle = epoch
        let root = dataRoot.standardizedFileURL
        let center = NotificationCenter.default
        // A turn's end carries whose words steered it, from the turn's own taint.
        TurnTraceEvent.steer = {
            if let taint = PeerDataTaint.current, taint.isTainted { return taint.sourceDescription }
            let turn = TurnEnvelope.current(surface: "")
            guard PeerTurnEffectPolicy.isPeerBridge(surface: turn.surface), !PeerDataTaint.trustedTurn else { return nil }
            return turn.verifiedUserId.map { "peer:" + $0 } ?? "another agent"
        }
        observers.append(center.addObserver(forName: AbilityStore.signalled, object: nil, queue: nil) { note in
            guard note.object as? String == root.path, let signal = note.userInfo?["signal"] as? String else { return }
            let part = note.userInfo?["part"] as? String
            let payload = note.userInfo?["payload"] as? [String: JSONValue] ?? [:]
            Task { await Self.shared.signalled(signal, only: part, payload, dataRoot: root, epoch: epoch) }
        })
        observers.append(center.addObserver(forName: .turnTraceTerminalPersisted, object: nil, queue: nil) { note in
            guard let info = note.userInfo, let trace = info["trace"] as? String,
                  let tail = NativeAgentWorkspaceRoot.relativePath(trace, under: root.path), !tail.isEmpty,
                  let turn = info["turnId"] as? String, let kind = info["kind"] as? String else { return }
            var payload: [String: JSONValue] = ["turn_id": .string(turn), "outcome": .string(kind),
                "trace": .string("turn_traces/" + URL(fileURLWithPath: trace).lastPathComponent),
                "session_id": (info["sessionId"] as? String).map(JSONValue.string) ?? .null]
            if let steer = info["agent"] as? String { payload["agent"] = .string(steer) }
            let starter = info["part"] as? String
            Task { await Self.shared.signalled("turn.ended", except: starter, payload, dataRoot: root, epoch: epoch) }
            if info["sessionId"] as? String == ResidentWake.session {
                Task { await EngineCarriedHabits.record(turn: turn, dataRoot: root) }
            }
        })
        // A private keep can outlive the terminal. Its closing trace retries
        // the same idempotent trial read after all dispatches have landed.
        observers.append(center.addObserver(forName: .turnTraceDispatchClosedPersisted, object: nil, queue: nil) { note in
            guard let info = note.userInfo, let trace = info["trace"] as? String,
                  let tail = NativeAgentWorkspaceRoot.relativePath(trace, under: root.path), !tail.isEmpty,
                  let turn = info["turnId"] as? String else { return }
            Task { await EngineCarriedHabits.record(turn: turn, dataRoot: root) }
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
        // Body changes, once per transition, from their shared sense owners.
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
        _ = NetworkSense.isUp // Start the body's shared path observation at launch.
        // The app came back: each ability that wakes on it takes up again
        // what it held (its own code and state know what that was).
        await deliver("resumed", [:], dataRoot: root, epoch: epoch)
    }

    private func presence(_ signal: String, idle: Double, dataRoot: URL, epoch: UUID) async {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        let reading = PersonPresence.read(dataRoot: dataRoot)
        guard let transition = reading.transition else { return }
        await NativeAgentEngine.cognitionRuntime(for: dataRoot).rhythmPresenceChanged(here: transition.here)
        guard lifecycle == epoch, !Task.isCancelled else { return }
        // A newer source callback may have run while rhythm settled. Never
        // overwrite its delivery receipt with the pre-suspension reading.
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
        // Record before posting or suspending: both source callbacks share
        // this actor, including when the other callback arrives during a wake.
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
        // Runs remove themselves while settling; join the captured tasks before
        // their caller retires the senses, programs and tool dependencies.
        await settle { for task in admitted { await task.value } }
        while !retiringWatches.isEmpty {
            let watches = Array(retiringWatches.values)
            for watch in watches { watch.cancel() }
            await settle { for watch in watches { await watch.value } }
        }
    }

    /// The original source edge releases intentions once. A part's later
    /// held-back delivery is still the same edge, not a second release.
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
        // A source retains the newest material; it asks this same admission
        // owner to interpret it, including bundled senses without a wake header.
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
        // Member paths are the news, not separate queue identities. Other
        // provenance still distinguishes arrivals (in particular peer taint).
        let identity = fileNews ? payload.filter { !["path", "changed", "changed_more"].contains($0.key) } : payload
        let news = (fileNews ? indexed : signal) + ((try? JSONValue.object(identity).serialize(pretty: false)) ?? "")
        guard let index else {
            // What came stays unread, so its wake waits for the catalog to read again.
            if ["held", "resumed"].contains(signal) { heldBack[(only ?? "") + "\u{0}" + news] = (signal, only, payload) }
            return
        }
        let parts = (index[indexed] ?? []).filter { (only == nil || $0.id == only) && $0.id != except }
        guard !parts.isEmpty else { return }
        // The wake's own record, kept apart from the part's input (it arrives as input.wake).
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
                // A resident part busy with a call it was given keeps the wake
                // until that call ends; then the wake is admitted afresh.
                repeat {
                    // Read when it runs, not when it queued: Autonomy may have gone off while it waited.
                    let allowed = await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    self.reindex(dataRoot: dataRoot)
                    // A catalog that stopped reading keeps held/resumed wakes for its recovery.
                    if self.index == nil, ["held", "resumed"].contains(signal) {
                        return self.holdBack(key, signal, part: file.id, payload, dataRoot: dataRoot, epoch: epoch)
                    }
                    guard let current = self.index?[indexed]?.first(where: { $0.id == file.id }) else { return }
                    guard allowed else {
                        if ["held", "resumed"].contains(signal) { self.holdBack(key, signal, part: file.id, payload, dataRoot: dataRoot, epoch: epoch) }
                        return nativeLog("[wake] %@ did not wake %@: Autonomy is off", signal, file.id)
                    }
                    // Exactly as the part's own write left it: its echo, not news.
                    if signal.hasPrefix("file.changed:"),
                       PhysiologySelfWriteRegistry.shared.isSelfWriteEcho(loopId: Self.echo(file.id, Self.watchedURL(signal, dataRoot: dataRoot))) { return }
                    await Self.run(current, input: input, dataRoot: dataRoot)
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    let waited = await OwnedProgramRunner.waitedForSlot(file.id, dataRoot: dataRoot)
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
        let allowed = await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot)
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

    /// Preserve each observed change, including successive changes to one member.
    /// The count includes records omitted by either source arrival or this merge.
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

    /// A held connection, program or listener reads nothing more while its
    /// arrival waits unread, and what a part held is taken up only by its
    /// `resumed`. Source helpers likewise retain their newest unread material.
    /// Their wakes wait too: each change of the trust policy re-reads the switch,
    /// and once it allows unattended work every held-back wake is delivered
    /// (checked again there).
    private func holdBack(_ key: String, _ signal: String, part: String, _ payload: [String: JSONValue], dataRoot: URL, epoch: UUID) {
        heldBack[key] = (signal, part, payload)
        guard autonomyWatch == nil else { return }
        let policy = dataRoot.appendingPathComponent("trust/policy.json")
        autonomyWatch = Task {
            // Its first edge closes the race with a switch-on before the watch armed.
            let changes = FileChangeEvents(paths: [policy])
            for await _ in changes.stream {
                if await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) { break }
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
        // A tainted signal reaches only a part that can do no harm with it: a
        // part that can write skips it with a trace row; a card is a decision.
        let readOnly: Bool
        do {
            if taint.isTainted { readOnly = try Self.readsOnly(file, dataRoot: dataRoot) }
            else { readOnly = false }
        }
        catch {
            await RepairOwed.owe(dataRoot, id: "wake-classification:" + wake, kind: .run,
                operation: "wake.classification:\(file.id)", owner: "abilities/\(file.id)",
                words: "Wake admission could not read the action catalog: \(error.localizedDescription). Repair the catalog before this part handles another peer-steered wake.").value
            TurnTraceBus.fire(TurnTraceEvent(turnId: wake, kind: "part.wake", sessionId: ResidentWake.session, surface: "chat",
                payload: .object(["part": .string(file.id), "result": .object(["status": .string("unavailable"),
                    "reason": .string("action_catalog_unavailable"), "detail": .string(error.localizedDescription), "effects": .string("none")])])))
            return
        }
        if taint.isTainted, !readOnly {
            let peer = taint.sourceDescription
            // The peer's name comes from its authenticated contact binding,
            // never from parsing the steer's own words.
            // Several authenticated peers may have steered it; each is named, or none is.
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
                payload: .object(["part": .string(file.id), "input": .object(input), "result": result])))
            return
        }
        let result = await throughOwnDoor(work: "wake:" + file.id, run: wake, part: file.id, taint: taint, dataRoot: dataRoot) {
            if file.kind == .sense { return try await sense(file.id, input: .object(["wake": .object(input)])) }
            // It is given none of its own input; what woke it rides as input.wake.
            let call: [String: JSONValue] = ["action": .string("authored." + file.id), "args": .object([:])]
            return try await OwnedProgramRunner.$wake.withValue(.object(input)) {
                guard let dispatch = AppDoorReentry.perform else { throw PartError.invalid("The part door has no dispatcher.") }
                return try await dispatch("app", call)
            }
        }
        // Every run leaves a trace, on her resident session.
        TurnTraceBus.fire(TurnTraceEvent(turnId: wake, kind: "part.wake",
            sessionId: ResidentWake.session, surface: "chat",
            payload: .object(["part": .string(file.id), "input": .object(input), "result": Self.outcome(result)])))
    }

    /// A habit is her own call, with the carried step's steering still intact.
    static func runCarried(_ step: DeskStep, handle: String, dataRoot: URL) async -> JSONValue {
        guard await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) else {
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
        let result = await ProactiveSpeechInitiative.$current.withValue(.intention) {
            await throughOwnDoor(work: "carry." + handle, run: run, part: part, taint: taint, dataRoot: dataRoot) {
                guard let dispatch = AppDoorReentry.perform else { throw PartError.invalid("The part door has no dispatcher.") }
                return try await dispatch("app", call)
            }
        }
        TurnTraceBus.fire(TurnTraceEvent(turnId: run, kind: "habit.run", sessionId: ResidentWake.session, surface: "chat",
            payload: .object(["workIdentity": .string("carry." + handle), "call": .object(call), "result": Self.outcome(result)])))
        return result
    }

    /// One posture and gate chain for unattended self calls, whether a part
    /// heard its signal or her carried moment came round. No planning model.
    private static func throughOwnDoor(work: String, run: String, part: String?, taint: PeerDataTaint, dataRoot: URL,
                                       operation: @escaping @Sendable () async throws -> JSONValue) async -> JSONValue {
        let wrote: @Sendable (URL) -> Void = { url in
            PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: echo(part ?? work, url))
            if work.hasPrefix("carry.") {
                PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: PhysiologySelfWriteRegistry.intentionWriteID(work, url))
            }
        }
        HerOpened.shared.began(run)
        let result = await TurnTraceContext.$turnId.withValue(run) { await SkillRunContext.$partID.withValue(part) {
            await SkillRunContext.$wrote.withValue(wrote) { await PeerDataTaint.$current.withValue(taint) {
                do {
                    return try await NativeAgentEngine.forRoot(dataRoot).chatClient(profile: .background).withCurrentChatModel {
                        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: .native(work)) {
                            try Task.checkCancellation()
                            return try await operation()
                        }
                    }
                } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
            } }
        } }
        await settle { HerOpened.shared.ended(run, dataRoot: dataRoot) }
        return result
    }

    /// A part that reads only: every capability it declares is a read and every
    /// action it depends on is a read, by the registry's own classification.
    private static func readsOnly(_ file: AbilityStore.File, dataRoot: URL) throws -> Bool {
        if file.kind == .part, let own = try AppActions.authored(dataRoot: dataRoot).first(where: { $0.id == "authored." + file.id }) {
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
        return try capabilitiesRead && actions.allSatisfy { try AppActions.action($0, dataRoot: dataRoot)?.read == true }
    }

    /// What the run came to, small enough that its trace row is never cut.
    private static func outcome(_ result: JSONValue) -> JSONValue {
        guard case .object(let fields) = result else { return result }
        return .object(fields.filter { ["status", "reason", "detail", "effects", "log", "remedy"].contains($0.key) })
    }

    /// A sense hears its wake through its resident owner, as an event.
    private static func sense(_ id: String, input: JSONValue) async throws -> JSONValue {
        let hub = SensesHub.shared
        try await hub.waitUntilReady()
        guard let receiver = hub.runner, let source = hub.source,
              let record = try await hub.registry?.all().first(where: { $0.id == id && $0.status == .on }) else {
            throw SenseFailure(code: "unavailable", message: "Sense \(id) is off, or the senses are not installed.")
        }
        try Task.checkCancellation()
        try await SensesHub.$passiveObservation.withValue(true) {
            if case .failed(let failure) = await receiver.run(record, request: .event(input), source: source) {
                throw failure
            }
        }
        return .object(["status": .string("ok")])
    }

    /// A declared path read the way her files are: relative names (and the
    /// workspace/ alias) start in her workspace, so a relative wake watches the
    /// file she named instead of a path from the app's working directory.
    private static func watchedURL(_ signal: String, dataRoot: URL) -> URL {
        NativeAgentWorkspaceRoot.resolveFileEntryPath(
            NativeAgentWorkspaceRoot.fileSpelling(String(signal.dropFirst(13))), dataRoot: dataRoot)
    }
    private static func indexedSignal(_ signal: String, dataRoot: URL) -> String {
        signal.hasPrefix("file.changed:") ? "file.changed:" + watchedURL(signal, dataRoot: dataRoot).path : signal
    }
    private static func echo(_ part: String, _ url: URL) -> String { "part:" + part + ":" + url.standardizedFileURL.path }

    /// Desk registration precedes the first read; older reads cannot restore
    /// a watch after a newer closure has published.
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

    /// Keys are already canonical file.changed paths. Unchanged memberships
    /// retain their stamps; closure, unreadability and shutdown release them.
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

    /// The index again; when the catalog reads after it did not, what waited for it goes now.
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
                words: "Part wakes stopped because the catalog did not read: \(error.localizedDescription). Preserve the named source before repairing it; old wake wiring is not current authority.",
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
        // Source wakes belong to the helper generation, including bundled
        // senses without a wake header; the runner retires that generation.
        for run in runs.values where !run.source && !live.contains(run.part) { run.task.cancel() }
        // Retired queued arrivals no longer suppress a later, newly admitted
        // arrival. Their cancelled tasks still keep their serialization slot
        // until actual exit; identity-checked cleanup cannot remove the new key.
        waiting = waiting.filter { _, id in runs[id].map { $0.source || live.contains($0.part) } ?? false }
        heldBack = heldBack.filter { _, wake in
            // Source subscriptions need no header; the runner owns their generation fence.
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
                    // Actual exit retires only this subscription, never a
                    // replacement installed while its cancellation settled.
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
                    // A repaired read is an edge even when no earlier identity
                    // was admitted. It asserts availability, never guessed additions.
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
                // Arm before reading readiness: a repair racing the bounded
                // wait or its unavailable news remains buffered for this path.
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
                        // No repair edge leaves this subscription unavailable,
                        // not a blocked resident owner; Stop retires its wait.
                        guard await ready.next() != nil else { return }
                    }
                }
                do {
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    guard let provider = SensesHub.shared.source as? any SenseSourceWatchingProvider else {
                        throw SenseFailure(code: "source_unavailable", message: "The senses' file source is not installed.")
                    }
                    let stream = try await provider.changes(for: corner, address: file)
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
                            // A checked absent root is a real empty baseline:
                            // deletion removes it; later creation adds it.
                            let available = unavailableFileWatches.remove(signal) != nil
                            if available {
                                await SenseNewsBoard.shared.keep(SenseNews(senseID: "file-watch", version: 1,
                                    address: signal, summary: "File watch available again; watched path is absent.", at: Date(), observationID: file))
                            }
                            news([:], available: available)
                            last = [:]
                        case .unavailable(let failure):
                            // Keep the last admitted identity. A failed read
                            // is never evidence of a removed member.
                            await unavailable(failure)
                        }
                    }
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    await unavailable(SenseFailure(code: "source_unavailable", message: "Source observation ended; a part/catalog change registers the source again."))
                } catch {
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    await unavailable(SenseFailure(code: "source_unavailable", message: error.localizedDescription))
                }
            }
            watches[signal] = (generation, task)
        }
    }
}
