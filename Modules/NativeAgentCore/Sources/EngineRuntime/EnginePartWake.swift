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
// Blueprint: | `EnginePartWake.swift` | `EnginePartWake`: `start`, `deliver`, `run`, `readsOnly`, `reindex`; Autonomy-gated wake index, per-part single flight, including source-triggered sense interpretation (material/transport stay source-owned, bundled senses need no wake header); a `held`, `resumed` or source-subscription wake Autonomy refused waits (`holdBack`, preserving source slot/helper generation independently of the header index) and is delivered when a trust-policy change finds the switch on; unreadable authority clears the index with repair owed, and a `held` or `resumed` wake meanwhile waits for it to read again; tainted signals skip write-capable parts (`tainted_signal` trace, no card); gated resident tools/skills and resident senses; current Chat model and signal audit; file-change watches survive absence and suppress self-writes; stop joins runs and all current/replaced file and trust watchers; turn-end steer retained; `resumed` delivered once at launch; `person.away`/`person.here` signalled from `MacPersonInput.presenceChanged`, whose first deadline is armed from existing idle after this observer registers; header-declared runs are `HerOpened` work |

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
    private var watches: [String: Task<Void, Never>] = [:]
    /// One run at a time per part, so a resident part keeps one context.
    private var runs: [UUID: (part: String, source: Bool, task: Task<Void, Never>)] = [:]
    private var tails: [String: UUID] = [:]
    private var observers: [NSObjectProtocol] = []
    private var lifecycle: UUID?
    private var stopped = false
    /// The same signal already waiting for a part is the same news.
    private var waiting: [String: UUID] = [:]
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

    /// Once at launch, once the senses are installed and before any source fires.
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
            Task { await Self.shared.deliver(signal, only: part, payload, dataRoot: root, epoch: epoch) }
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
            Task { await Self.shared.deliver("turn.ended", except: starter, payload, dataRoot: root, epoch: epoch) }
        })
        observers.append(center.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { _ in
            Task { await Self.shared.refresh(dataRoot: root, epoch: epoch) }
        })
        // The person away or here again, once per transition, from the one presence owner.
        observers.append(center.addObserver(forName: MacPersonInput.presenceChanged, object: nil, queue: nil) { note in
            guard let signal = note.userInfo?["signal"] as? String else { return }
            let idle = note.userInfo?["idle_seconds"] as? Double ?? 0
            Task { await Self.shared.presence(signal, idle: idle, dataRoot: root, epoch: epoch) }
        })
        MacPersonInput.startPresenceWakes()
        // The app came back: each ability that wakes on it takes up again
        // what it held (its own code and state know what that was).
        await deliver("resumed", [:], dataRoot: root, epoch: epoch)
    }

    private func presence(_ signal: String, idle: Double, dataRoot: URL, epoch: UUID) {
        guard lifecycle == epoch else { return }
        AbilityStore(dataRoot: dataRoot).signal(signal, ["idle_seconds": .double(idle)])
    }

    func stop() async {
        stopped = true
        lifecycle = nil // Close admission before cancelling any resident work.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for watch in watches.values { retireWatch(watch) }
        watches.removeAll(); watched.removeAll()
        let admitted = runs.values.map(\.task)
        for task in admitted { task.cancel() }
        tails.removeAll(); waiting.removeAll(); heldBack.removeAll()
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
        let news = signal + ((try? JSONValue.object(payload).serialize(pretty: false)) ?? "")
        guard let index else {
            // What came stays unread, so its wake waits for the catalog to read again.
            if ["held", "resumed"].contains(signal) { heldBack[(only ?? "") + "\u{0}" + news] = (signal, only, payload) }
            return
        }
        let parts = (index[signal] ?? []).filter { (only == nil || $0.id == only) && $0.id != except }
        guard !parts.isEmpty else { return }
        // The wake's own record, kept apart from the part's input (it arrives as input.wake).
        var input = payload
        input["signal"] = .string(signal)
        input["at"] = .string(ISO8601DateFormatter().string(from: Date()))
        for file in parts {
            let key = file.id + "\u{0}" + news
            let id = UUID()
            guard waiting[key] == nil else { continue }
            waiting[key] = id
            let previous = tails[file.id].flatMap { runs[$0]?.task }
            let task = Task {
                defer { self.finished(file.id, id: id, key: key, epoch: epoch) }
                await previous?.value
                guard self.lifecycle == epoch, !Task.isCancelled else { return }
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
                    guard let current = self.index?[signal]?.first(where: { $0.id == file.id }) else { return }
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
            await SensesHub.shared.runner?.sourceChanged(slot: slot, generation: generation)
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
        guard lifecycle == epoch else { return }
        begin(key, id: id)
        if tails[part] == id { tails.removeValue(forKey: part) }
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
        if taint.isTainted, !Self.readsOnly(file, dataRoot: dataRoot) {
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
        // Bound for the whole run, so a card it raises waits and names the part,
        // and each file it writes is stamped as it stood right after the write.
        let wrote: @Sendable (URL) -> Void = { url in
            PhysiologySelfWriteRegistry.shared.stampAfterTick(loopId: echo(file.id, url))
        }
        // What it opens on the Mac is hers, as in a turn, and its end tells her.
        HerOpened.shared.began(wake)
        let result: JSONValue = await TurnTraceContext.$turnId.withValue(wake) { await SkillRunContext.$partID.withValue(file.id) { await SkillRunContext.$wrote.withValue(wrote) {
            await PeerDataTaint.$current.withValue(taint) {
                do {
                    return try await NativeAgentEngine.forRoot(dataRoot).chatClient(profile: .background).withCurrentChatModel {
                        try await NativeAgentEngine.forRoot(dataRoot).tools.withPartDoor(envelope: TurnEnvelope(
                            surface: "chat", agent: "self", declaredRemote: false, workIdentity: "wake:" + file.id)) {
                            try Task.checkCancellation()
                            if file.kind == .sense { return try await sense(file.id, input: .object(["wake": .object(input)])) }
                            // It is given none of its own input; what woke it rides as input.wake.
                            let call: [String: JSONValue] = ["action": .string("authored." + file.id), "args": .object([:])]
                            return try await OwnedProgramRunner.$wake.withValue(.object(input)) {
                                guard let dispatch = AppDoorReentry.perform else { throw PartError.invalid("The part door has no dispatcher.") }
                                return try await dispatch("app", call)
                            }
                        }
                    }
                } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
            }
        } } }
        HerOpened.shared.ended(wake, dataRoot: dataRoot)
        // Every run leaves a trace, on her resident session.
        TurnTraceBus.fire(TurnTraceEvent(turnId: wake, kind: "part.wake",
            sessionId: ResidentWake.session, surface: "chat",
            payload: .object(["part": .string(file.id), "input": .object(input), "result": Self.outcome(result)])))
    }

    /// A part that reads only: every capability it declares is a read and every
    /// action it depends on is a read, by the registry's own classification.
    private static func readsOnly(_ file: AbilityStore.File, dataRoot: URL) -> Bool {
        if file.kind == .part, let own = AppActions.authored(dataRoot: dataRoot).first(where: { $0.id == "authored." + file.id }) {
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
        return capabilitiesRead && actions.allSatisfy { AppActions.action($0, dataRoot: dataRoot)?.read == true }
    }

    /// What the run came to, small enough that its trace row is never cut.
    private static func outcome(_ result: JSONValue) -> JSONValue {
        guard case .object(let fields) = result else { return result }
        return .object(fields.filter { ["status", "reason", "detail", "effects", "log", "remedy"].contains($0.key) })
    }

    /// A sense hears its wake through its resident owner, as an event.
    private static func sense(_ id: String, input: JSONValue) async throws -> JSONValue {
        let hub = SensesHub.shared
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
    private static func echo(_ part: String, _ url: URL) -> String { "part:" + part + ":" + url.standardizedFileURL.path }

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
            for watch in watches.values { retireWatch(watch) }
            watches.removeAll(); watched.removeAll()
            let failure = error as? ToolFailureError ?? AbilityStore(dataRoot: dataRoot).repairFailure(
                source: dataRoot.appendingPathComponent("abilities"), detail: error.localizedDescription)
            RepairOwed.owe(dataRoot, id: "parts-index:" + UUID().uuidString.lowercased(), kind: .run,
                operation: "parts.index", owner: failure.owner ?? dataRoot.appendingPathComponent("abilities").path,
                words: "Part wakes stopped because the catalog did not read: \(error.localizedDescription). Preserve the named source before repairing it; old wake wiring is not current authority.",
                nextCall: failure.nextCall)
            return nativeLog("[wake] part wakes stopped: abilities do not read (%@)", error.localizedDescription)
        }
        var built: [String: [AbilityStore.File]] = [:]
        for file in files { for signal in Set(file.wakes) { built[signal, default: []].append(file) } }
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
                || (wake.part.map { part in built[wake.signal]?.contains(where: { $0.id == part }) == true } ?? true)
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
        let wanted = Set(built.keys.filter { $0.hasPrefix("file.changed:") })
        for signal in Set(watches.keys).subtracting(wanted) { retireWatch(watches.removeValue(forKey: signal)) }
        guard let provider = SensesHub.shared.source as? any SenseSourceWatchingProvider else {
            if !wanted.isEmpty { nativeLog("[wake] file wakes unwatched: the senses' source is not installed") }
            return
        }
        for signal in wanted where watches[signal] == nil {
            guard let epoch = lifecycle else { return }
            let file = Self.watchedURL(signal, dataRoot: dataRoot).path
            watches[signal] = Task {
                // The watch also follows the file's folder; only this file's own change is news.
                func identity() -> [Int64] {
                    var info = stat()
                    guard lstat(file, &info) == 0 else { return [] }
                    return [Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
                }
                var last = identity()
                func news() {
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    let now = identity()
                    guard now != last else { return }
                    last = now
                    AbilityStore(dataRoot: dataRoot).signal(signal, ["path": .string(file)])
                }
                let corner = SenseCorner.fileKind(URL(fileURLWithPath: file).pathExtension.lowercased())
                while !Task.isCancelled {
                    do {
                        let stream = try await provider.changes(for: corner, address: file)
                        guard self.lifecycle == epoch, !Task.isCancelled else { return }
                        news() // Registration precedes the race-closing read.
                        for await _ in stream {
                            guard self.lifecycle == epoch, !Task.isCancelled else { return }
                            news()
                        }
                    } catch { nativeLog("[wake] %@ waits for its file: %@", signal, error.localizedDescription) }
                    // What ended the watch can be news itself: the file deleted.
                    news()
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    // Gone, or not readable yet: the path's own watch (through its
                    // ancestors) says when to look again.
                    let next = FileChangeEvents(paths: [URL(fileURLWithPath: file)], emitInitial: false)
                    var available = await next.waitUntilArmed()
                    guard self.lifecycle == epoch, !Task.isCancelled else { next.cancel(); return }
                    if available, identity() == last {
                        var events = next.stream.makeAsyncIterator()
                        available = await events.next() != nil
                    }
                    next.cancel()
                    guard self.lifecycle == epoch, !Task.isCancelled else { return }
                    if !available {
                        nativeLog("[wake] %@ file watch unavailable: observation of %@ failed", signal, file)
                        return
                    }
                }
            }
        }
    }
}
