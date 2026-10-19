import AuthoredCapabilities
import AgentConversations
import AgentWorkspace
import AppToolRuntime
import BackgroundLoops
import BackgroundWork
import ChatOrchestration
import Foundation
import Experiences
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
import TurnTrace

/// The stem delivering signals (AGENT_IS_THE_APP S4). A source that fired
/// posts `AbilityStore.signalled` after its own work (a turn's end is its
/// durable terminal row); each part whose `wake` lists the signal runs once
/// with it as input: a tool or skill through the door, the way a turn calls
/// it (a resident part keeps its context), a sense through its resident
/// owner. Nothing here polls or keeps a clock: a schedule is the part's
/// TriggerScheduler job, a declared file is the senses' own watch, the rest
/// are posted by their sources. Like every unattended runner, nothing runs
/// while the owner's Autonomy switch is off.
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
    /// Each signal's parts, rebuilt when a part changes.
    private var index: [String: [AbilityStore.File]] = [:]
    /// The files each part watches, as the self-write registry holds them.
    private var watched: [String: [URL]] = [:]
    /// `file.changed:` through the senses' watch, one per declared path.
    private var watches: [String: Task<Void, Never>] = [:]
    /// One run at a time per part, so a resident part keeps one context.
    private var runs: [String: Task<Void, Never>] = [:]
    /// The same signal already waiting for a part is the same news.
    private var waiting: Set<String> = []

    /// Once at launch, once the senses are installed and before any source fires.
    nonisolated static func start(dataRoot: URL) {
        let root = dataRoot.standardizedFileURL
        let center = NotificationCenter.default
        // A turn's end carries whose words steered it, from the turn's own taint.
        TurnTraceEvent.steer = {
            if let taint = PeerDataTaint.current, taint.isTainted { return taint.sourceDescription }
            let turn = TurnEnvelope.current(surface: "")
            guard PeerTurnEffectPolicy.isPeerBridge(surface: turn.surface), !PeerDataTaint.trustedTurn else { return nil }
            return turn.verifiedUserId.map { "peer:" + $0 } ?? "another agent"
        }
        _ = center.addObserver(forName: AbilityStore.signalled, object: nil, queue: nil) { note in
            guard note.object as? String == root.path, let signal = note.userInfo?["signal"] as? String else { return }
            let part = note.userInfo?["part"] as? String
            let payload = note.userInfo?["payload"] as? [String: JSONValue] ?? [:]
            Task { await shared.deliver(signal, only: part, payload, dataRoot: root) }
        }
        _ = center.addObserver(forName: .turnTraceTerminalPersisted, object: nil, queue: nil) { note in
            guard let info = note.userInfo, let trace = info["trace"] as? String, trace.hasPrefix(root.path + "/"),
                  let turn = info["turnId"] as? String, let kind = info["kind"] as? String else { return }
            var payload: [String: JSONValue] = ["turn_id": .string(turn), "outcome": .string(kind),
                "trace": .string("turn_traces/" + URL(fileURLWithPath: trace).lastPathComponent),
                "session_id": (info["sessionId"] as? String).map(JSONValue.string) ?? .null]
            if let steer = info["agent"] as? String { payload["agent"] = .string(steer) }
            let starter = info["part"] as? String
            Task { await shared.deliver("turn.ended", except: starter, payload, dataRoot: root) }
        }
        _ = center.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { _ in
            Task { await shared.reindex(dataRoot: root) }
        }
        Task { await shared.reindex(dataRoot: root) }
    }

    private func deliver(_ signal: String, only: String? = nil, except: String? = nil,
                         _ payload: [String: JSONValue], dataRoot: URL) async {
        reindex(dataRoot: dataRoot)
        let parts = (index[signal] ?? []).filter { (only == nil || $0.id == only) && $0.id != except }
        guard !parts.isEmpty else { return }
        guard await WorkshopBackgroundWork.unattendedWorkAllowed(dataRoot: dataRoot) else {
            return nativeLog("[wake] %@ reached no part: Autonomy is off", signal)
        }
        var input = payload
        input["signal"] = .string(signal)
        input["at"] = .string(ISO8601DateFormatter().string(from: Date()))
        let news = signal + ((try? JSONValue.object(payload).serialize(pretty: false)) ?? "")
        for file in parts {
            let key = file.id + "\u{0}" + news
            guard waiting.insert(key).inserted else { continue }
            let previous = runs[file.id]
            runs[file.id] = Task {
                await previous?.value
                self.begin(key)
                // Exactly as the part's own write left it: its echo, not news.
                if signal.hasPrefix("file.changed:"),
                   PhysiologySelfWriteRegistry.shared.isSelfWriteEcho(loopId: Self.echo(file.id, Self.watchedURL(signal))) { return }
                await Self.run(file, input: input, dataRoot: dataRoot)
            }
        }
    }

    private func begin(_ key: String) { waiting.remove(key) }

    private static func run(_ file: AbilityStore.File, input: [String: JSONValue], dataRoot: URL) async {
        let wake = "wake-" + UUID().uuidString.lowercased()
        let taint = PeerDataTaint()
        if case .string(let agent)? = input["agent"], !PeerTrust.ownerTrusts(agent, dataRoot: dataRoot) { taint.mark(peer: agent) }
        // A tainted signal reaches only a part that can do no harm with it: a
        // part that can write skips it, with a trace row and no card for the
        // person (User 10-15: a card is a decision, never weight).
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
        let result: JSONValue = await TurnTraceContext.$turnId.withValue(wake) { await SkillRunContext.$partID.withValue(file.id) { await SkillRunContext.$wrote.withValue(wrote) {
            await ChatToolSessionContext.$envelope.withValue(TurnEnvelope(surface: "chat", agent: "self",
                declaredRemote: false, workIdentity: "wake:" + file.id)) {
                await PeerDataTaint.$current.withValue(taint) {
                    do {
                        return try await NativeAgentEngine.forRoot(dataRoot).chatClient(profile: .background).withCurrentChatModel {
                        if file.kind == .sense { return try await sense(file.id, input: .object(input)) }
                        let filer = NativeAgentChatApprovalFiler(dataRoot: dataRoot)
                        let chain = makeGatedToolDispatchClient(
                            tools: NativeAgentEngine.forRoot(dataRoot).toolDispatchClient(enforceAppAutonomy: false, swarmApprovalFiler: filer),
                            fileAccess: "auto", approvalFiler: filer, dataRoot: dataRoot, verifiedSessionId: ResidentWake.session)
                        let call: [String: JSONValue] = file.kind == .skill
                            ? ["action": .string("skill.run"), "args": .object(["name": .string(file.id), "input": .object(input)])]
                            : ["action": .string("authored." + file.id), "args": .object(input)]
                        return try await chain.dispatch(tool: "app", input: call, surface: "chat")
                        }
                    } catch { return ChatToolOutcome.failure(error: error, tool: "app") }
                }
            }
        } } }
        // Every run leaves a trace, on her resident session.
        TurnTraceBus.fire(TurnTraceEvent(turnId: wake, kind: "part.wake",
            sessionId: ResidentWake.session, surface: "chat",
            payload: .object(["part": .string(file.id), "input": .object(input), "result": Self.outcome(result)])))
    }

    /// A part that reads only: every capability it declares is a read and every
    /// action it depends on is a read, by the registry's own classification.
    private static func readsOnly(_ file: AbilityStore.File, dataRoot: URL) -> Bool {
        if file.kind == .tool, let own = AppActions.authored(dataRoot: dataRoot).first(where: { $0.id == "authored." + file.id }) {
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
        guard let receiver = hub.runner as? any SenseViewEventReceiver, let source = hub.source,
              let record = try await hub.registry?.all().first(where: { $0.id == id && $0.status == .on }) else {
            throw SenseFailure(code: "unavailable", message: "Sense \(id) is off, or the senses are not installed.")
        }
        try await receiver.receiveViewEvent(input, for: record, source: source)
        return .object(["status": .string("ok")])
    }

    private static func watchedURL(_ signal: String) -> URL {
        URL(fileURLWithPath: NSString(string: String(signal.dropFirst(13))).expandingTildeInPath)
    }
    private static func echo(_ part: String, _ url: URL) -> String { "part:" + part + ":" + url.standardizedFileURL.path }

    private func reindex(dataRoot: URL) {
        let files: [AbilityStore.File]
        do { files = try AbilityStore(dataRoot: dataRoot).files(includeProposals: false) }
        catch {
            index.removeAll()
            for watch in watches.values { watch.cancel() }
            watches.removeAll(); watched.removeAll()
            let failure = error as? ToolFailureError ?? AbilityStore(dataRoot: dataRoot).repairFailure(
                source: dataRoot.appendingPathComponent("abilities"), detail: error.localizedDescription)
            RepairOwed.owe(dataRoot, id: "parts-index:" + UUID().uuidString.lowercased(), kind: .run,
                operation: "parts.index", owner: failure.owner ?? dataRoot.appendingPathComponent("abilities").path,
                words: "Part wakes stopped because the catalog did not read: \(error.localizedDescription). Preserve the named source before repairing it; old wake wiring is not current authority.",
                nextCall: failure.nextCall)
            return nativeLog("[wake] part wakes stopped: abilities do not read (%@)", error.localizedDescription)
        }
        index = [:]
        for file in files { for signal in Set(file.wakes) { index[signal, default: []].append(file) } }
        RepairOwed.settle(dataRoot, operation: "parts.index", evidence: .init(source: "abilities", id: "index-rebuilt:" + UUID().uuidString.lowercased()))
        for file in files {
            let paths = file.wakes.filter { $0.hasPrefix("file.changed:") }.map(Self.watchedURL)
            guard watched[file.id] != paths else { continue }
            watched[file.id] = paths
            for url in paths { PhysiologySelfWriteRegistry.shared.register(loopId: Self.echo(file.id, url), paths: [url]) }
        }
        let wanted = Set(index.keys.filter { $0.hasPrefix("file.changed:") })
        for signal in Set(watches.keys).subtracting(wanted) { watches.removeValue(forKey: signal)?.cancel() }
        guard let provider = SensesHub.shared.source as? any SenseSourceWatchingProvider else {
            if !wanted.isEmpty { nativeLog("[wake] file wakes unwatched: the senses' source is not installed") }
            return
        }
        for signal in wanted where watches[signal] == nil {
            let file = Self.watchedURL(signal).path
            watches[signal] = Task {
                // The watch also follows the file's folder; only this file's own change is news.
                func identity() -> [Int64] {
                    var info = stat()
                    guard lstat(file, &info) == 0 else { return [] }
                    return [Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec)]
                }
                var last = identity()
                let corner = SenseCorner.fileKind(URL(fileURLWithPath: file).pathExtension.lowercased())
                while !Task.isCancelled {
                    do {
                        for await _ in try await provider.changes(for: corner, address: file) {
                            let now = identity()
                            guard now != last else { continue }
                            last = now
                            AbilityStore(dataRoot: dataRoot).signal(signal, ["path": .string(file)])
                        }
                    } catch { nativeLog("[wake] %@ waits for its file: %@", signal, error.localizedDescription) }
                    // Gone, or not readable yet: the path's own watch (through its
                    // ancestors) says when to look again.
                    let seen = identity()
                    let next = FileChangeEvents(paths: [URL(fileURLWithPath: file)], emitInitial: false)
                    await next.waitUntilArmed()
                    if identity() == seen { for await _ in next.stream { break } }
                    next.cancel()
                }
            }
        }
    }
}
