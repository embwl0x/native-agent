import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `OwnedProgramRunner.swift` | lazy proof-scoped helper reuse across fixtures and decision replays with fresh contexts and journals; Invocation-bound selection/dependency proof shared until canonical catalog revision changes; shared program execution, resident helper leases invalidated by canonical ability changes/removal, and what a resident ability holds (`holding`, one broker per resident life) kept in the same slot, selected under the store lock, surviving a failed run's dropped helper; retirement closes admission and retains teardown through completion before replacement publication, and terminal quit (`endResidents`) removes the catalog observer and drains teardown; helper-owned one-second process-tree RSS sampling remains because no equivalent threshold event is confirmed; fresh per-call authority/journal and resume freshness; host calls carry the part and its input in SkillRunContext; `host.state.get/set` for tools and skills reaches AbilityStore's notebook by part id (scratch for preview/validation); skill resume replays saved state results then persists new state operations normally, without renewing stalled execution; authored tools receive frozen home/workspace paths and their requesting data root; rooted file calls resolve app_data/workspace before the door, retaining path-array listing compatibility through ordinary paging; `ReadContent` collects owner-declared envelope projections and content dependencies, sharing normalization with replay argument comparisons without changing replies; a ledger row for a batch call carries its receipts' effects |
/// One helper implementation, with isolated contexts. Sense subscriptions keep
/// a process through their adapter; resident tools and skills retain the same
/// transport between calls. Authority is supplied afresh on every run.
public struct OwnedProgramRunner: OwnedProgramRunning {
    public static let sourceLimit = AbilityStore.sourceLimit
    /// Script action/read caps and default I/O bounds. Abilities bypass the
    /// action/read caps; ability and turn I/O uses OwnedProgram's 4 MiB bounds.
    public static let actionLimit = 50
    public static let readLimit = 100
    public static let returnLimit = 16 * 1024
    public static let logLimit = 2 * 1024
    public static let inputLimit = 16 * 1024
    public static let stepLimit = 50
    /// The selection and dependency proof belong to the invocation. Concurrent
    /// calls share its refresh; a failed refresh stays failed until an owner changes.
    /// Invocation cancellation cancels that flight; a retired generation can
    /// never validate a newer revision, even if its refresh ignored cancellation.
    public actor Binding {
        private var revision: [String]
        private var checked: Task<Void, Error>?
        private var generation = UUID()
        public init(revision: [String]) { self.revision = revision }
        deinit { checked?.cancel() }
        public func check(_ revision: [String], refresh: @escaping @Sendable () async throws -> Void) async throws {
            try Task.checkCancellation()
            if self.revision != revision {
                checked?.cancel()
                self.revision = revision
                generation = UUID()
                checked = Task {
                    try Task.checkCancellation()
                    try await refresh()
                    try Task.checkCancellation()
                }
            }
            let generation = self.generation
            if let checked {
                try await withTaskCancellationHandler { try await checked.value } onCancel: { checked.cancel() }
            }
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
        }
    }
    public typealias SandboxProfile = @Sendable (URL) throws -> String
    private let helperURL: URL
    let dataRoot: URL
    private let sandboxProfile: SandboxProfile
    private static let residents = Residents()
    private final class Residents: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var observer: NSObjectProtocol?
        private var teardowns: [String: (id: UUID, task: Task<Void, Never>)] = [:]
        /// One resident program: its helper while it has one, and what it
        /// holds (an ability's programs and connections), which outlives a
        /// helper a failed run dropped.
        private struct Slot {
            let program: OwnedProgram
            var process: OwnedProgramProcess?
            var held: (value: AnyObject, end: @Sendable () async -> Void)?
            var busy = false
            /// Stops its helper; returns what ends what it held.
            func stop() -> (@Sendable () async -> Void)? { process?.stop(); return held?.end }
        }
        private var slots: [String: Slot] = [:] {
            didSet { for key in Array(vacancies.keys) where slots[key]?.busy != true && teardowns[key] == nil { vacancies.removeValue(forKey: key)?.forEach { $0.resume() } } }
        }
        /// The slots a wake was turned away from, busy with another call, and
        /// the wakes waiting for one to free.
        private var turnedAway: Set<String> = []
        private var vacancies: [String: [CheckedContinuation<Void, Never>]] = [:]
        init() {
            observer = NotificationCenter.default.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { [weak self] change in
                guard let key = change.object as? String, let self else { return }
                self.lock.withLock { self.retire(key) }
            }
        }
        /// Under the pool lock: remove admission before starting retained teardown.
        private func retire(_ key: String) {
            guard let slot = slots[key] else { return }
            if let end = slot.stop() {
                let id = UUID()
                teardowns[key] = (id, Task {
                    await end()
                    self.lock.withLock {
                        guard self.teardowns[key]?.id == id else { return }
                        self.teardowns.removeValue(forKey: key)
                        self.vacancies.removeValue(forKey: key)?.forEach { $0.resume() }
                    }
                })
            }
            slots.removeValue(forKey: key)
        }
        func settle(_ store: AbilityStore, program: OwnedProgram) async throws {
            try Task.checkCancellation()
            let key = store.root.appendingPathComponent(program.id).path
            while let flight = try AbilityStore.withLock({ () throws -> Task<Void, Never>? in
                // Revalidate after every teardown await before retiring or
                // publishing anything: a stale caller cannot retire its successor.
                try selected(store, program)
                return try lock.withLock {
                    guard !closed else { throw CancellationError() }
                    if let slot = slots[key], slot.program != program { retire(key) }
                    return teardowns[key]?.task
                }
            }) {
                await flight.value
                try Task.checkCancellation()
            }
        }
        private func admit(_ key: String) throws {
            guard !closed, teardowns[key] == nil else { throw CancellationError() }
        }
        /// Under the store's lock: only the selected version takes, or replaces, its slot.
        private func selected(_ store: AbilityStore, _ program: OwnedProgram) throws {
            guard let selected = try store.read(id: program.id), selected.kind == .part,
                  selected.record["codeFingerprint"] == .string(program.version), selected.bodyDigest == program.digest,
                  selected.metadata["resident"] == .bool(true),
                  [JSONValue.string("active"), .string("installed")].contains(selected.record["status"] ?? .null) else {
                throw SenseFailure(code: "state_changed", message: "The selected ability was stopped or replaced. Nothing more ran.")
            }
        }
        func holding<Held: AnyObject & Sendable>(_ store: AbilityStore, program: OwnedProgram, make: () -> Held,
                                                 end: @escaping @Sendable (Held) async -> Void) async throws -> Held {
            try await settle(store, program: program)
            return try AbilityStore.withLock {
                try selected(store, program)
                return try lock.withLock {
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key)
                    if let slot = slots[key], slot.program != program { retire(key); throw CancellationError() }
                    if slots[key] == nil { slots[key] = Slot(program: program) }
                    if let value = slots[key]?.held?.value as? Held { return value }
                    let value = make()
                    slots[key]?.held = (value, { await end(value) })
                    return value
                }
            }
        }
        func turnAway(_ key: String) { lock.withLock { _ = turnedAway.insert(key) } }
        func waitIfTurnedAway(_ key: String) async -> Bool {
            guard lock.withLock({ turnedAway.remove(key) != nil }) else { return false }
            await withCheckedContinuation { (vacancy: CheckedContinuation<Void, Never>) in
                lock.withLock { if !closed && (slots[key]?.busy == true || teardowns[key] != nil) { vacancies[key, default: []].append(vacancy) } else { vacancy.resume() } }
            }
            return true
        }
        func end() async {
            let (observer, flights) = lock.withLock {
                closed = true
                let observer = self.observer; self.observer = nil
                for key in Array(slots.keys) { retire(key) }
                for waiting in vacancies.values { waiting.forEach { $0.resume() } }
                vacancies.removeAll(); turnedAway.removeAll()
                return (observer, teardowns.values.map(\.task))
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            for flight in flights { await flight.value }
        }
        func take(_ store: AbilityStore, program: OwnedProgram, create: () throws -> OwnedProgramProcess) throws -> OwnedProgramProcess {
            // Selection and lease publication share the mutation lock, in store/pool order.
            try AbilityStore.withLock {
                try selected(store, program)
                return try lock.withLock {
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key)
                    if let slot = slots[key] {
                        guard !slot.busy else { throw SenseFailure(code: "busy", message: "Resident ability \(program.id) is already running; wait for its call to finish.") }
                        if slot.program == program, let process = slot.process, process.isRunning, process.failure == nil {
                            slots[key]?.busy = true
                            return process
                        }
                        slot.process?.stop(); slots[key]?.process = nil
                        if slot.program != program { retire(key); throw CancellationError() }
                    }
                    let process = try create()
                    slots[key, default: Slot(program: program)].process = process
                    slots[key]?.busy = true
                    return process
                }
            }
        }
        /// A resumed run's lease: its slot busy for it as for a live run, so
        /// the two never overlap on what it holds; its helper its own.
        func lease(_ store: AbilityStore, program: OwnedProgram) throws -> String {
            try AbilityStore.withLock {
                try selected(store, program)
                return try lock.withLock {
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key)
                    guard slots[key]?.busy != true else { throw SenseFailure(code: "busy", message: "Resident ability \(program.id) is already running; wait for its call to finish.") }
                    slots[key, default: Slot(program: program)].busy = true
                    return key
                }
            }
        }
        func unlease(_ key: String, program: OwnedProgram) {
            lock.withLock { if slots[key]?.program == program { slots[key]?.busy = false } }
        }
        func release(_ key: String, process: OwnedProgramProcess, keep: Bool) {
            lock.withLock {
                guard slots[key]?.process === process else { return }
                slots[key]?.busy = false
                if keep { return }
                // A failed run drops its helper and context; what it holds stays.
                process.stop(); slots[key]?.process = nil
                if slots[key]?.held == nil { slots.removeValue(forKey: key) }
            }
        }
    }
    public init(helperURL: URL = SenseHostLocator.helperURL, dataRoot: URL, sandboxProfile: @escaping SandboxProfile) {
        self.helperURL = helperURL; self.dataRoot = dataRoot; self.sandboxProfile = sandboxProfile
    }
    public init(dataRoot: URL) {
        let helper = SenseHostLocator.helperURL
        self.init(helperURL: helper, dataRoot: dataRoot) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helper, scratch: scratch,
                dataRoot: dataRoot, personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        }
    }
    /// One helper held by its caller across calls of one resident program (her
    /// turn: every step of a turn in one process). It stops when released or
    /// when a call fails.
    public final class Held: @unchecked Sendable {
        fileprivate let process: OwnedProgramProcess
        fileprivate init(_ process: OwnedProgramProcess) { self.process = process }
        deinit { process.stop() }
    }
    public func hold() throws -> Held { Held(try spawn()) }
    /// What a resident program holds beside its helper (an ability's programs
    /// and connections), in its resident slot: one for its resident life, made
    /// on its first live run of the selected version and ended with the slot,
    /// when its ability changes (off, a new version, dropped) or the app quits;
    /// never by a run, a failed one included.
    public static func holding<Held: AnyObject & Sendable>(_ program: OwnedProgram, dataRoot: URL, make: () -> Held,
                                                           end: @escaping @Sendable (Held) async -> Void) async throws -> Held {
        try await residents.holding(AbilityStore(dataRoot: dataRoot), program: program, make: make, end: end)
    }
    /// The app is quitting: every resident helper ends, and what each held.
    public static func endResidents() async { await residents.end() }
    /// Whether the wake that just ran ability `id` was turned away, its
    /// resident slot busy with another call: if so, returns true once that
    /// call ends, and the wake is admitted afresh.
    public static func waitedForSlot(_ id: String, dataRoot: URL) async -> Bool {
        await residents.waitIfTurnedAway(AbilityStore(dataRoot: dataRoot).root.appendingPathComponent(id).path)
    }
    private func spawn() throws -> OwnedProgramProcess {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("program-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do { return try OwnedProgramProcess(helper: helperURL, profile: sandboxProfile(scratch), scratch: scratch) }
        catch { try? FileManager.default.removeItem(at: scratch); throw error }
    }
    /// The host is serviced in this task's context. Cancellation claims pending
    /// replies before killing the helper, so a noncooperative late host result
    /// cannot resume JS or issue another effect. Effect owners retain their gates.
    public func run(_ program: OwnedProgram, input: JSONValue? = nil, preview: Bool = false,
                    replay: Replay? = nil, host: any OwnedProgramHostProfile) async -> JSONValue {
        await run(program, input: input, preview: preview, replay: replay, host: host, held: nil)
    }
    public func run(_ program: OwnedProgram, input: JSONValue, host: any OwnedProgramHostProfile, on held: Held) async -> JSONValue {
        await run(program, input: input, preview: false, replay: nil, host: host, held: held)
    }
    /// One proof owns one helper, started only if a fixture actually runs.
    /// Every fixture still gets a fresh journal and JavaScript context.
    public func rehearsal() -> any OwnedProgramRunning { Rehearsal(runner: self) }
    private actor Rehearsal: OwnedProgramRunning {
        let runner: OwnedProgramRunner
        var held: Held?
        init(runner: OwnedProgramRunner) { self.runner = runner }
        func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
                 replay: Replay?, host: any OwnedProgramHostProfile) async -> JSONValue {
            do {
                try Task.checkCancellation()
                if held == nil { held = try runner.hold() }
                return await runner.run(program, input: input, preview: preview, replay: replay, host: host, held: held)
            } catch {
                let failure = error as? SenseFailure
                return .object(["status": .string("failed"), "effects": .string("none"), "error": .object([
                    "reason": .string(error is CancellationError ? "cancelled" : failure?.code ?? "helper_unavailable"),
                    "detail": .string(error.localizedDescription)])])
            }
        }
    }
    /// What woke the part this run serves: its signal, time and payload. It
    /// reaches the part as `input.wake`, beside its own declared input and past
    /// every params check, and never reaches a part that part runs in turn.
    @TaskLocal public static var wake: JSONValue?
    /// Whether a run was turned away before any of it ran, its resident slot busy with another call.
    public static func turnedAway(_ receipt: JSONValue) -> Bool {
        guard case .object(let fields) = receipt, case .object(let error)? = fields["error"] else { return false }
        return error["reason"] == .string("busy") && error["origin"] == .string("runtime")
    }
    func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool, replay: Replay?,
                     host: any OwnedProgramHostProfile, held: Held?) async -> JSONValue {
        if let wake = Self.wake, program.isPart {
            var fields: [String: JSONValue] = if case .object(let fields)? = input { fields } else { [:] }
            fields["wake"] = wake
            let receipt = await Self.$wake.withValue(nil) {
                await run(program, input: .object(fields), preview: preview, replay: replay, host: host, held: held)
            }
            // A resume is no wake's delivery: none waits on its slot.
            if replay == nil, Self.turnedAway(receipt) {
                Self.residents.turnAway(AbilityStore(dataRoot: dataRoot).root.appendingPathComponent(program.id).path)
            }
            return receipt
        }
        var receipt = await execute(program, input: input, preview: preview, replay: replay, host: host, held: held)
        // An ad hoc app script is not a part: it leaves no evidence on any ability.
        if !preview, program.kind != .script, program.entry != .face, !(host is OwnedProgramFixtures) {
            receipt = await AbilityStore(dataRoot: dataRoot).settleRun(id: program.id, version: program.version,
                receipt: receipt, input: replay == nil ? input : nil)
        }
        return receipt
    }
    private func execute(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
                         replay: Replay?, host: any OwnedProgramHostProfile, held: Held?) async -> JSONValue {
        let actions = ActionTasks()
        let receipt = await executeEffect(program, input: input, preview: preview, replay: replay, host: host, held: held, actions: actions)
        // Child host calls own their settlement too. Stop can end the helper
        // immediately, but its caller waits for those children before returning.
        await settle { await actions.finish() }
        return receipt
    }
    private func executeEffect(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
                         replay: Replay?, host: any OwnedProgramHostProfile, held: Held?, actions: ActionTasks) async -> JSONValue {
        let journal = Journal(source: program.source, preview: preview, program: program,
                              replay: replay, host: host, actionsInFlight: actions, notebookRoot: dataRoot, partID: program.id)
        do {
            try program.validate()
            guard program.kind != .sense else {
                throw SenseFailure(code: "bad_input", message: "Persistent senses require their source-bound runner adapter.")
            }
            if let input {
                let limit = program.inputLimit
                guard case .object = input, try input.serializedData(pretty: false).count <= limit else {
                    throw SenseFailure(code: "invalid_input", message: "A program's input must be a JSON object of at most \(limit) bytes.")
                }
            }
            try Task.checkCancellation()
            let live = !preview && replay == nil && !(host is OwnedProgramFixtures) && held == nil
            let resident = program.isResident && live
            let store = AbilityStore(dataRoot: dataRoot)
            let key = store.root.appendingPathComponent(program.id).path
            if program.isResident, !preview, held == nil, !(host is OwnedProgramFixtures) {
                try await Self.residents.settle(store, program: program)
            }
            // A resident ability's resume replays in a helper of its own, under its slot's lease.
            let leased = program.isResident && replay != nil && !preview && held == nil && !(host is OwnedProgramFixtures)
                ? try Self.residents.lease(store, program: program) : nil
            defer { if let leased { Self.residents.unlease(leased, program: program) } }
            let process: OwnedProgramProcess
            if let held { process = held.process }
            // Only a resident program's run reaches the resident pool.
            else if resident { process = try Self.residents.take(store, program: program, create: spawn) }
            else { process = try spawn() }
            if host is OwnedProgramFixtures {
                // A new process used to supply a fresh notebook on each pass;
                // preserve that isolation while retaining the transport.
                journal.notebookRoot = process.scratch.appendingPathComponent(UUID().uuidString)
            } else if preview { journal.notebookRoot = process.scratch }
            var keep = false
            defer {
                process.end(1); actions.cancel()
                if resident { Self.residents.release(key, process: process, keep: keep) }
                else if held == nil || !keep { process.stop() }
            }
            return await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    var message: [String: JSONValue] = [
                        "id": .int(1), "type": .string("run"), "program": try .fromEncodable(program),
                        "actionIDs": .array(host.actionIDs.map(JSONValue.string)),
                    ]
                    if host is OwnedProgramFixtures { message["freshContext"] = .bool(true) }
                    if program.isPart {
                        // The helper's own HOME is its run scratch; the person's home comes from here.
                        message["home"] = .string(FileManager.default.homeDirectoryForCurrentUser.path)
                        message["workspace"] = .string(try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot).path)
                        message["dataRoot"] = .string(dataRoot.path)
                        message["measurementSystem"] = .string(Locale.autoupdatingCurrent.measurementSystem == .us ? "us" : Locale.autoupdatingCurrent.measurementSystem == .metric ? "metric" : "other")
                    }
                    if let input { message["input"] = input }
                    process.begin(id: 1, kind: program.kind, seconds: program.seconds, onFailure: { _ in actions.cancel() })
                    try process.send(.object(message))
                    var lastCallID: Int64 = 0
                    for await event in process.events {
                        try Task.checkCancellation()
                        switch event {
                        case .ended(let detail): throw SenseFailure(code: "crashed", message: detail)
                        case .line(let bytes):
                            guard case .object(let fields) = try JSONValue.parse(bytes), fields["id"] == .int(1),
                                  case .string(let type)? = fields["type"] else {
                                throw SenseFailure(code: "bad_output", message: "Program helper sent an invalid message.")
                            }
                            if type == "failed" {
                                let failure = try JSONDecoder().decode(SenseFailure.self, from: JSONEncoder().encode(fields["failure"] ?? .null))
                                // A reported failure explains the helper's exit;
                                // a latched supervision failure still wins.
                                let terminal = process.failure
                                journal.fail(terminal?.code == "crashed" ? failure : terminal ?? failure)
                                return journal.receipt()
                            }
                            if type == "program_done" {
                                try process.claimCompletion(1)
                                journal.complete(fields)
                                let receipt = journal.receipt()
                                if case .object(let result) = receipt {
                                    keep = result["status"] == .string("ok") || host is OwnedProgramFixtures
                                        && result["status"] == .string("stopped")
                                        && ["decide", "irreversible", "users_step", "would_card"].contains(result["reason"]?.stringValue ?? "")
                                }
                                return receipt
                            }
                            guard case .int(let callID)? = fields["callID"], callID > lastCallID else {
                                throw SenseFailure(code: "bad_output", message: "Program host calls require increasing callIDs.")
                            }
                            lastCallID = callID
                            if type == "script_log", case .string(let text)? = fields["text"] {
                                journal.say(text); continue
                            }
                            var reply: JSONValue
                            if type == "app_call", case .string(let kind)? = fields["kind"],
                               case .string(let id)? = fields["action"], case .string(let args)? = fields["args"],
                               case .int(let line)? = fields["line"] {
                                guard !["primitive", "state"].contains(kind) || program.isPart else {
                                    throw SenseFailure(code: "bad_output", message: "Only an ability reaches host primitives and host.state.")
                                }
                                // Host work is progress; only unaccompanied JS can stall.
                                let waitStarted = try process.suspend(1)
                                if program.kind == .turn, kind == "turn" {
                                    reply = .string(try JSONValue.object(["ok": .bool(true), "value": try await host.reach(id)])
                                        .serialize(pretty: false))
                                } else {
                                    reply = await SkillRunContext.$partID.withValue(program.id) {
                                        await SkillRunContext.$ability.withValue(program.isPart ? program.id : nil) {
                                            await SkillRunContext.$input.withValue(input) {
                                                .string(await journal.call(kind: kind, id: id, args: args, line: Int(line)))
                                            }
                                        }
                                    }
                                }
                                try process.resume(1, since: waitStarted)
                            } else { throw SenseFailure(code: "bad_output", message: "Program called an API outside its host profile.") }
                            if fields["kind"] != .string("state") { try process.renewProgress(1) }
                            try process.send(.object(["type": .string("host_reply"), "id": .int(1),
                                                      "callID": .int(callID), "value": reply]))
                        }
                    }
                    throw SenseFailure(code: "crashed", message: "Program helper ended before answering.")
                } catch {
                    journal.fail(process.failure ?? (error is CancellationError
                        ? SenseFailure(code: "cancelled", message: "Program cancelled.")
                        : (error as? SenseFailure) ?? SenseFailure(code: "crashed", message: error.localizedDescription)))
                    return journal.receipt()
                }
            } onCancel: { actions.cancel(); process.stop() }
        } catch {
            journal.fail((error as? SenseFailure) ?? SenseFailure(code: "crashed", message: error.localizedDescription))
            return journal.receipt()
        }
    }
    final class ActionTasks: @unchecked Sendable {
        private let lock = NSLock()
        private var active: (task: Task<Void, Never>, reply: CheckedContinuation<JSONValue, Never>)?
        private var cancelled = false
        private var settling: [Task<Void, Never>] = []
        var isCancelled: Bool { lock.withLock { cancelled } }
        private static let cancellation = JSONValue.object([
            "status": .string("failed"), "reason": .string("cancelled"), "not_run_status": .string("cancelled"),
            "detail": .string("The turn was stopped while this call was running."),
        ])
        func perform(_ input: [String: JSONValue], host: any OwnedProgramHostProfile) async -> JSONValue {
            await call { await host.perform(input) }
        }
        func primitive(_ operation: String, arguments: JSONValue, preview: Bool, host: any OwnedProgramHostProfile) async -> JSONValue {
            await call {
                do { return try await host.primitive(operation, arguments: arguments, preview: preview) }
                catch {
                    let failure = (error as? SenseFailure) ?? SenseFailure(code: "failed", message: error.localizedDescription)
                    return .object(["status": .string("failed"), "reason": .string(failure.code),
                                    "detail": .string(failure.message), "effects": .string("unknown")])
                }
            }
        }
        private func call(_ operation: @escaping @Sendable () async -> JSONValue) async -> JSONValue {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    guard !cancelled, !Task.isCancelled else { continuation.resume(returning: Self.cancellation); return }
                    let task = Task {
                        guard !Task.isCancelled else { return }
                        let result = await operation()
                        let reply = self.lock.withLock { () -> CheckedContinuation<JSONValue, Never>? in
                            defer { self.active = nil }
                            return self.active?.reply
                        }
                        reply?.resume(returning: result)
                    }
                    active = (task, continuation)
                }
            }
        }
        func cancel() {
            let action = lock.withLock {
                cancelled = true
                defer { active = nil }
                if let active { settling.append(active.task) }
                return active
            }
            action?.task.cancel(); action?.reply.resume(returning: Self.cancellation)
        }
        func finish() async {
            cancel()
            let tasks = lock.withLock { settling }
            for task in tasks { await task.value }
        }
    }
    /// `unclear`: a strict run's receipt that is not a clear success
    /// (`strictFault`). The script still gets the receipt; the ledger keeps
    /// the doubt, and a write's effects are then unknown.
    enum Outcome { case ok, preview, failed, stop, unclear }
    /// `strict` (a skill's run) is exact, by `strictFault`'s one rule.
    static func classify(_ receipt: JSONValue, strict: Bool = false, write: Bool = false,
                         host: any OwnedProgramHostProfile)
        -> (outcome: Outcome, reason: String, detail: String) {
        guard case .object(let fields) = receipt else {
            guard strict, write else { return (.ok, "", "") }
            return (.unclear, "not_a_receipt", "It answered with no receipt, so whether it took effect can't be told.")
        }
        let inner: [String: JSONValue] = if case .object(let result)? = fields["result"] { result } else { [:] }
        func text(_ key: String) -> String {
            [fields[key], inner[key]].lazy.compactMap { $0?.scalarText }
                .first { !$0.isEmpty } ?? ""
        }
        let detail = String(text("detail").prefix(400))
        let waiting = text("not_run_status")
        let evidence = host.evidence(receipt)
        if !waiting.isEmpty || evidence.waiting
            || host.evidence(fields["result"] ?? .null).waiting {
            return (.stop, waiting.isEmpty ? "waiting_on_user" : waiting, detail)
        }
        // A preview that would refuse classifies as that refusal would.
        if fields["status"] == .string("preview") {
            let refused = text("would_refuse")
            if fields["owner"] == .string("his") { return (.stop, refused.isEmpty ? "owners_call" : refused, detail) }
            if fields["would_card"] == .bool(true) { return (.stop, "would_card", detail) }
            return refused.isEmpty ? (.preview, "", detail) : (.failed, refused, detail)
        }
        if fields["status"] == .string("did_not_stick") { return (.failed, "did_not_stick", detail) }
        // A card only User can answer, on the glass: nothing was answered.
        if fields["status"] == .string("needs_glass") { return (.stop, "needs_glass", String(text("reason").prefix(400))) }
        if evidence.successful {
            guard strict, let fault = strictFault(fields, write: write, host: host, outer: evidence) else { return (.ok, "", detail) }
            return (.unclear, fault, detail.isEmpty ? "Its receipt is not a clear success (\(fault))." : detail)
        }
        let reason = [text("reason"), text("failure_code")].first { !$0.isEmpty && !$0.contains(" ") } ?? "failed"
        return (host.floorReasons.contains(reason) ? .stop : .failed, reason, detail)
    }
    /// A strict run's one rule, all the way down a receipt's `result`s. A
    /// write is a success only when its receipt says terminal success, and
    /// nothing under it says otherwise. A read may return any data, but no
    /// failure, status that is not final, dry run, or unknown or partial
    /// effects. Nil when it passes.
    static func strictFault(_ fields: [String: JSONValue], write: Bool, host: any OwnedProgramHostProfile, outer: OwnedProgramReceiptEvidence) -> String? {
        for (depth, at) in resultChain(fields).enumerated() {
            let evidence = depth == 0 ? outer : host.evidence(.object(at))
            let outcome = evidence.resultClass
            let status = text(at["status"]).lowercased()
            let reason = text(at["reason"])
            let effects = text(at["effects"])
            if ["failed", "refused", "timeout", "cancelled"].contains(outcome) {
                return reason.isEmpty || reason.contains(" ") ? "failed" : reason
            }
            if evidence.pending { return "status_\(status)" }
            if at["dry_run"] == .bool(true) || at["dryRun"] == .bool(true) { return "dry_run" }
            if ["unknown", "partial"].contains(effects) { return "effects_\(effects)" }
            if evidence.effectUnconfirmed {
                return "effect_unconfirmed"
            }
            guard write, outcome != "succeeded", depth == 0 || !status.isEmpty else { continue }
            return status.isEmpty ? "no_success_said" : "status_\(status)"
        }
        return nil
    }
    /// A receipt and every `result` inside it, outermost first.
    static func resultChain(_ fields: [String: JSONValue]) -> [[String: JSONValue]] {
        var chain = [fields]
        while case .object(let inner)? = chain.last?["result"] { chain.append(inner) }
        return chain
    }
    /// A call's effects from its whole receipt: unknown, then partial, then
    /// occurred outranks what an outer level said.
    package static func effects(_ fields: [String: JSONValue]) -> JSONValue? {
        let said = resultChain(fields).map { text($0["effects"]) }.filter { !$0.isEmpty }
        return (["unknown", "partial", "occurred"].first(where: said.contains) ?? said.first).map(JSONValue.string)
    }
    /// The real ids a call's receipt returned, whatever its size: the first
    /// of each name, down through objects (never lists, never its own input).
    static func returnedIDs(_ receipt: JSONValue) -> [String: JSONValue] {
        let names = ["approval_id", "message_id", "run_id", "request_id", "id", "version", "page_version"]
        var found: [String: JSONValue] = [:]
        var level: [[String: JSONValue]] = if case .object(let fields) = receipt { [fields] } else { [] }
        while !level.isEmpty {
            for fields in level {
                for name in names where found[name] == nil {
                    switch fields[name] {
                    case .string(let id)? where !id.isEmpty: found[name] = .string(id)
                    case .int(let id)?: found[name] = .int(id)
                    default: break
                    }
                }
            }
            level = level.flatMap { fields in
                fields.filter { !["underlying_call", "side_effects", "args"].contains($0.key) }.sorted { $0.key < $1.key }
                    .compactMap { if case .object(let inner) = $0.value { inner } else { nil } }
            }
        }
        return found
    }
    public struct ScriptError: Error {
        public let reason: String
        public let detail: String
        public init(reason: String, detail: String) { self.reason = reason; self.detail = detail }
    }
    /// A stopped skill run, resumed: the script runs again from the top, and
    /// each call the stopped run made is answered from `journal`, in order,
    /// without running again; the one it stopped at (its decide, or the step
    /// it handed back) returns `answer`. A call that differs from the
    /// journal's stops the run there, before it runs.
    public struct Replay: Sendable {
        public let journal: [JSONValue]
        public let answer: JSONValue
        public let recheckReads: Bool
        public init(journal: [JSONValue], answer: JSONValue, recheckReads: Bool = true) {
            self.journal = journal; self.answer = answer; self.recheckReads = recheckReads
        }
    }
    /// A read's answer without its place in the run (n, line).
    static func readValue(_ out: String) -> JSONValue {
        guard case .object(var fields)? = try? JSONValue.parse(Data(out.utf8)) else { return .string(out) }
        for key in ["n", "line"] { fields.removeValue(forKey: key) }
        return fields["value"] ?? .object(fields)
    }
    /// Result owners declare their volatile envelope here while a read runs.
    /// The journal keeps the digest and projections for later argument comparisons;
    /// the script still receives the whole result.
    public final class ReadContent: @unchecked Sendable {
        @TaskLocal public static var current: ReadContent?
        private let lock = NSLock()
        private var declarations: [(value: JSONValue, content: JSONValue)] = []
        private var dependencies: [JSONValue] = []
        public func record(_ value: JSONValue, content: JSONValue) {
            guard value != content else { return }
            lock.withLock { declarations.append((value, content)) }
        }
        public func depend(on content: JSONValue) {
            lock.withLock { dependencies.append(content) }
        }
        var projections: JSONValue {
            lock.withLock {
                .array(declarations.map { .object(["value": $0.value, "content": $0.content]) })
            }
        }
        func include(_ projections: JSONValue) {
            guard case .array(let entries) = projections else { return }
            for entry in entries {
                if case .object(let fields) = entry, let value = fields["value"], let content = fields["content"] {
                    record(value, content: content)
                }
            }
        }
        /// One owner-declared projection for read content and replay arguments.
        func normalize(_ value: JSONValue) -> JSONValue {
            lock.withLock {
                func project(_ value: JSONValue) -> JSONValue {
                    switch value {
                    case .object(var fields):
                        for declaration in declarations {
                            if case .object(let envelope) = declaration.value, case .object(let content) = declaration.content,
                               envelope.allSatisfy({ fields[$0.key] == $0.value }) {
                                for key in envelope.keys { fields[key] = content[key] }
                            }
                        }
                        return .object(fields.mapValues(project))
                    case .array(let items): return .array(items.map(project))
                    case .string(var text):
                        for declaration in declarations {
                            if case .string(let token) = declaration.value, case .string(let content) = declaration.content {
                                text = text.replacingOccurrences(of: token, with: content)
                            }
                        }
                        return .string(text)
                    default: return value
                    }
                }
                return project(value)
            }
        }
        func digest(_ value: JSONValue) -> String {
            let dependencies = lock.withLock { self.dependencies }
            let content: JSONValue = if case .object(let fields) = value, let version = fields["version"] {
                .object(["version": version])
            } else { normalize(value) }
            return JSONValue.array([content, .array(dependencies.map(normalize))]).digest
        }
    }
    /// The versions a strict run's own calls returned, in order, from its
    /// journal: each read's version and each write's page_version.
    public static func ownVersions(_ journal: [JSONValue]) -> [String] {
        journal.compactMap { entry -> String? in
            guard case .object(let fields) = entry, case .array(let call)? = fields["call"], let kind = call.first,
                  case .string(let out)? = fields["out"], case .object(let value) = readValue(out) else { return nil }
            return (kind == .string("read") ? value["version"] : value["page_version"])?.scalarText
        }
    }
    /// What a journaled call reads or writes: its page, and the item it names.
    static func target(_ entry: JSONValue, host: any OwnedProgramHostProfile) -> (page: String, item: String?, write: Bool)? {
        guard case .object(let fields) = entry, case .array(let call)? = fields["call"], call.count > 2,
              case .string(let kind) = call[0], case .string(let id) = call[1], case .string(let raw) = call[2] else { return nil }
        let given: [JSONValue] = if case .array(let list)? = try? JSONValue.parse(Data(raw.utf8)) { list } else { [] }
        func lower(_ value: JSONValue?) -> String? { value?.scalarText?.lowercased() }
        if kind == "read", let page = lower(given.first) { return (page, given.count > 1 ? lower(given[1]) : nil, false) }
        guard ["action", "primitive"].contains(kind),
              let action = kind == "primitive" ? host.primitiveAction(id) : host.action(id) else { return nil }
        let args: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
        guard let page = action.page == "*" ? lower(args["page"]) : action.page.lowercased() else { return nil }
        return (page, lower(args["handle"]) ?? lower(args["id"]) ?? lower(args["item"]), !action.readOnly(args))
    }
    /// A version's page or page/item.
    public static func versionScope(_ version: String) -> String {
        version.split(separator: "@", maxSplits: 1).first.map(String.init) ?? version
    }
    /// A read's answer, short: its version when it has one.
    static func brief(_ out: String) -> JSONValue {
        let value = readValue(out)
        if case .object(let fields) = value, let version = fields["version"] { return version }
        return .string(String(((try? value.serialize(pretty: false)) ?? out).prefix(300)))
    }
}
