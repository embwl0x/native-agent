import AuthoredCapabilities
import Darwin
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `OwnedProgramRunner.swift` | `holding`, `endResidents`, `host.state.get/set`, `ReadContent`: resident leases, replay and receipts |
/// Reuse helper transport with isolated contexts and fresh authority on every run.
public struct OwnedProgramRunner: OwnedProgramRunning {
    public static let sourceLimit = AbilityStore.sourceLimit
    /// Abilities bypass script action/read caps but retain OwnedProgram's 4 MiB I/O bounds.
    public static let actionLimit = 50
    public static let readLimit = 100
    public static let logLimit = 2 * 1024
    public static let inputLimit = 16 * 1024
    public static let stepLimit = 50
    /// Share dependency refresh within an invocation; failure lasts until owner change, and retired generations cannot validate newer revisions.
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
    private static let turnHelpers = TurnHelpers()
    /// Only idle programs may be pooled; active leases are exclusive and exact source, version and limits must match before reusing the body and realm.
    private final class TurnHelpers: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var idle: [String: (OwnedProgram, OwnedProgramProcess)] = [:]
        func take(_ key: String, program: OwnedProgram, create: () throws -> OwnedProgramProcess) throws -> Held {
            let kept = try lock.withLock {
                guard !closed else { throw CancellationError() }
                return idle.removeValue(forKey: key)
            }
            let reused = kept.map { $0.0 == program && $0.1.isRunning && $0.1.failure == nil } ?? false
            let process: OwnedProgramProcess
            if reused, let kept { process = kept.1 }
            else { kept?.1.stop(); process = try create() }
            guard lock.withLock({ !closed }) else { process.stop(); throw CancellationError() }
            return Held(process, reused: reused) { [self] process in
                lock.withLock {
                    guard !closed, process.isRunning, process.failure == nil else { process.stop(); return }
                    idle.removeValue(forKey: key)?.1.stop()
                    // Bound retained helpers across roots without expiring them by age.
                    if idle.count >= 4, let first = idle.keys.sorted().first { idle.removeValue(forKey: first)?.1.stop() }
                    idle[key] = (program, process)
                }
            }
        }
        func end() { lock.withLock { closed = true; idle.values.forEach { $0.1.stop() }; idle.removeAll() } }
    }
    private final class Residents: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private var observer: NSObjectProtocol?
        private var teardowns: [String: (id: UUID, task: Task<Void, Never>)] = [:]
        /// Resident holdings must outlive helpers dropped by failed runs.
        private struct Slot {
            let program: OwnedProgram
            var process: OwnedProgramProcess?
            var held: (value: AnyObject, end: @Sendable () async -> Void)?
            var busy = false
            func stop() -> (@Sendable () async -> Void)? { process?.stop(); return held?.end }
        }
        private var slots: [String: Slot] = [:] {
            didSet {
                for key in Array(vacancies.keys) where slots[key]?.busy != true && teardowns[key] == nil {
                    vacancies.removeValue(forKey: key)?.forEach { $0.resume() }
                }
            }
        }
        private var turnedAway: Set<String> = []
        private var vacancies: [String: [ScopedWaiter]] = [:]
        init() {
            observer = NotificationCenter.default.addObserver(forName: AbilityStore.didChange, object: nil, queue: nil) { [weak self] change in
                guard let key = change.object as? String, let self else { return }
                self.lock.withLock { self.retire(key) }
            }
        }
        /// Under the pool lock, remove admission before starting retained teardown.
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
                // Revalidate after teardown awaits so stale callers cannot retire or replace their successors.
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
        /// Only the selected version may take or replace its slot under the store lock.
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
        func waitIfTurnedAway(_ key: String, deadline: ContinuousClock.Instant?) async -> Bool {
            guard lock.withLock({ turnedAway.remove(key) != nil }) else { return false }
            let vacancy = ScopedWaiter()
            lock.withLock {
                if !closed && (slots[key]?.busy == true || teardowns[key] != nil) { vacancies[key, default: []].append(vacancy) }
                else { vacancy.resume() }
            }
            await vacancy.park(budget: .init(deadline: deadline))
            lock.withLock {
                vacancies[key]?.removeAll { $0 === vacancy }
                if vacancies[key]?.isEmpty == true { vacancies.removeValue(forKey: key) }
            }
            if Task.isCancelled { ModuleLog.app("[resident] cancelled vacancy wait released: %@", URL(fileURLWithPath: key).lastPathComponent) }
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
            // Selection and lease publication share the mutation lock in store/pool order.
            try AbilityStore.withLock {
                try selected(store, program)
                return try lock.withLock {
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key)
                    if let slot = slots[key] {
                        guard !slot.busy else {
                            throw SenseFailure(code: "busy", message: "Resident ability \(program.id) is already running; wait for its call to finish.")
                        }
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
        /// Resume takes the resident slot's exclusive lease so live calls cannot overlap its holdings.
        func lease(_ store: AbilityStore, program: OwnedProgram) throws -> String {
            try AbilityStore.withLock {
                try selected(store, program)
                return try lock.withLock {
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key)
                    guard slots[key]?.busy != true else {
                        throw SenseFailure(code: "busy", message: "Resident ability \(program.id) is already running; wait for its call to finish.")
                    }
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
                // A failed run drops its helper and context without releasing resident holdings.
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
    /// Ordinary holds stop on release; healthy turn leases return to the source-bound idle pool. Any failed call stops its helper.
    public final class Held: @unchecked Sendable {
        fileprivate let process: OwnedProgramProcess
        public let reused: Bool
        private let release: (@Sendable (OwnedProgramProcess) -> Void)?
        fileprivate init(_ process: OwnedProgramProcess, reused: Bool = false,
                         release: (@Sendable (OwnedProgramProcess) -> Void)? = nil) {
            self.process = process; self.reused = reused; self.release = release
        }
        deinit { if let release { release(process) } else { process.stop() } }
    }
    public func hold() throws -> Held { Held(try spawn()) }
    /// Attempt admission once without capacity waits so callers can end accepted turns even if helper resources never become available.
    public func holdTurn(_ program: OwnedProgram) throws -> Held {
        try Task.checkCancellation()
        guard program.kind == .turn, program.isResident else {
            throw SenseFailure(code: "bad_input", message: "Only a resident turn program can lease a turn helper.")
        }
        do {
            return try Self.turnHelpers.take(dataRoot.standardizedFileURL.path, program: program, create: spawn)
        } catch let failure as SenseFailure where failure.code == "spawn_busy" {
            throw SenseFailure(code: "resource_unavailable",
                message: "Turn helper admission could not obtain process resources; no retry was started. \(failure.message)",
                remedy: failure.remedy)
        }
    }
    /// Keep holdings for the selected resident lifetime, ending only with selection changes or app quit, never with a completed or failed run.
    public static func holding<Held: AnyObject & Sendable>(_ program: OwnedProgram, dataRoot: URL, make: () -> Held,
                                                           end: @escaping @Sendable (Held) async -> Void) async throws -> Held {
        try await residents.holding(AbilityStore(dataRoot: dataRoot), program: program, make: make, end: end)
    }
    public static func endResidents() async { turnHelpers.end(); await residents.end() }
    /// Wait only for release, cancellation or the supplied deadline; wake is not proof of vacancy, so revalidate admission afterward.
    public static func waitedForSlot(_ id: String, dataRoot: URL, deadline: ContinuousClock.Instant?) async -> Bool {
        await residents.waitIfTurnedAway(AbilityStore(dataRoot: dataRoot).root.appendingPathComponent(id).path, deadline: deadline)
    }
    private func spawn() throws -> OwnedProgramProcess {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("program-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do { return try OwnedProgramProcess(helper: helperURL, profile: sandboxProfile(scratch), scratch: scratch) }
        catch { try? FileManager.default.removeItem(at: scratch); throw error }
    }
    /// Stop kills the helper and cancels host work; join the host's actual result into the journal before returning without resuming the helper.
    public func run(_ program: OwnedProgram, input: JSONValue? = nil, preview: Bool = false,
                    replay: Replay? = nil, host: any OwnedProgramHostProfile, execution: OwnedProgramExecution) async -> JSONValue {
        await run(program, input: input, preview: preview, replay: replay, host: host, execution: execution, held: nil)
    }
    public func run(_ program: OwnedProgram, input: JSONValue, host: any OwnedProgramHostProfile, execution: OwnedProgramExecution,
        on held: Held) async -> JSONValue {
        await run(program, input: input, preview: false, replay: nil, host: host, execution: execution, held: held)
    }
    /// A proof may reuse its lazily opened helper, but every fixture needs a fresh journal and context.
    public func rehearsal() -> any OwnedProgramRunning { Rehearsal(runner: self) }
    private actor Rehearsal: OwnedProgramRunning {
        let runner: OwnedProgramRunner
        var held: Held?
        init(runner: OwnedProgramRunner) { self.runner = runner }
        func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
                 replay: Replay?, host: any OwnedProgramHostProfile, execution: OwnedProgramExecution) async -> JSONValue {
            do {
                try Task.checkCancellation()
                if held == nil { held = try runner.hold() }
                return await runner.run(program, input: input, preview: preview, replay: replay, host: host, execution: execution, held: held)
            } catch {
                let failure = error as? SenseFailure
                return .object(["status": .string("failed"), "effects": .string("none"), "error": .object([
                    "reason": .string(error is CancellationError ? "cancelled" : failure?.code ?? "helper_unavailable"),
                    "detail": .string(error.localizedDescription)])])
            }
        }
    }
    public static func turnedAway(_ receipt: JSONValue) -> Bool {
        guard case .object(let fields) = receipt, case .object(let error)? = fields["error"] else { return false }
        return error["reason"] == .string("busy") && error["origin"] == .string("runtime")
    }
    func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool, replay: Replay?,
                     host: any OwnedProgramHostProfile, execution: OwnedProgramExecution, held: Held?) async -> JSONValue {
        if let wake = execution.wake, program.isPart {
            var fields: [String: JSONValue] = if case .object(let fields)? = input { fields } else { [:] }
            fields["wake"] = wake
            var next = execution
            next.wake = nil
            let receipt = await run(program, input: .object(fields), preview: preview, replay: replay, host: host, execution: next, held: held)
            // Resume does not deliver a wake, so no wake waits on its slot.
            if replay == nil, Self.turnedAway(receipt) {
                Self.residents.turnAway(AbilityStore(dataRoot: dataRoot).root.appendingPathComponent(program.id).path)
            }
            return receipt
        }
        let startedAt = Date()
        var receipt = await execute(program, input: input, preview: preview, replay: replay, host: host, execution: execution, held: held)
        // Ad hoc scripts must not leave ability evidence because they are not parts.
        if !preview, !program.isPart, program.kind != .script, program.entry != .face, !(host is OwnedProgramFixtures) {
            let observed = execution.dependencySnapshot
            receipt = await AbilityStore(dataRoot: dataRoot).settleRun(id: program.id, version: program.version,
                receipt: receipt, input: replay == nil ? input : nil,
                dependencySnapshot: observed?.id == program.id && observed?.version == program.version ? observed?.shapes : nil,
                turn: execution.turn, at: startedAt)
        }
        return receipt
    }
    private func execute(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
                         replay: Replay?, host: any OwnedProgramHostProfile, execution: OwnedProgramExecution, held: Held?) async -> JSONValue {
        let actions = ActionTasks()
        let receipt = await executeEffect(program, input: input, preview: preview, replay: replay, host: host, execution: execution, held: held,
            actions: actions)
        // Wait for child host settlement before returning even when Stop has already ended the helper.
        await settle { await actions.finish() }
        return receipt
    }
    private func executeEffect(_ program: OwnedProgram, input: JSONValue?, preview: Bool,
                         replay: Replay?, host: any OwnedProgramHostProfile, execution: OwnedProgramExecution, held: Held?,
                             actions: ActionTasks) async -> JSONValue {
        let execution: OwnedProgramExecution = {
            var held = execution
            held.input = input; held.preview = preview
            if var turn = held.turn {
                turn.partID = program.id; turn.abilityID = program.isPart ? program.id : nil
                held.turn = turn
            }
            return held
        }()
        let journal = Journal(source: program.source, preview: preview, program: program,
                              replay: replay, host: host, execution: execution, actionsInFlight: actions, notebookRoot: dataRoot, partID: program.id)
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
            // Resume must use its own helper under the resident slot's lease.
            let leased = program.isResident && replay != nil && !preview && held == nil && !(host is OwnedProgramFixtures)
                ? try Self.residents.lease(store, program: program) : nil
            defer { if let leased { Self.residents.unlease(leased, program: program) } }
            let process: OwnedProgramProcess
            if let held { process = held.process }
            else if resident { process = try Self.residents.take(store, program: program, create: spawn) }
            else { process = try spawn() }
            if host is OwnedProgramFixtures {
                // Reset the notebook on each pass to preserve isolation while retaining transport.
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
                        "actionIDs": .array(try host.actionIDs.map(JSONValue.string)),
                    ]
                    if host is OwnedProgramFixtures { message["freshContext"] = .bool(true) }
                    if program.isPart {
                        // The helper's HOME is scratch; supply the person's home separately.
                        message["home"] = .string(FileManager.default.homeDirectoryForCurrentUser.path)
                        message["workspace"] = .string(try NativeAgentWorkspaceRoot.prepare(dataRoot: dataRoot).path)
                        message["dataRoot"] = .string(dataRoot.path)
                        message["measurementSystem"] = .string(Locale.autoupdatingCurrent.measurementSystem == .us
                            ? "us"
                            : Locale.autoupdatingCurrent.measurementSystem == .metric ? "metric" : "other")
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
                                // A latched supervision failure takes precedence over a helper's reported exit cause.
                                let terminal = process.failure
                                journal.fail(terminal?.code == "crashed" ? failure : terminal ?? failure)
                                return journal.receipt()
                            }
                            if type == "program_done" {
                                try process.claimCompletion(1)
                                journal.complete(fields)
                                var receipt = journal.receipt()
                                if case .object(var result) = receipt {
                                    keep = result["status"] == .string("ok") || host is OwnedProgramFixtures
                                        && result["status"] == .string("stopped")
                                        && ["decide", "irreversible", "users_step", "would_card"].contains(result["reason"]?.stringValue ?? "")
                                    if program.kind == .turn {
                                        result["programReused"] = fields["programReused"]
                                        receipt = .object(result)
                                    }
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
                                // Host work counts as progress; only unaccompanied JavaScript may stall.
                                let waitStarted = try process.suspend(1)
                                if program.kind == .turn, kind == "turn" {
                                    reply = .string(try JSONValue.object(["ok": .bool(true), "value": try await host.reach(id, execution: execution)])
                                        .serialize(pretty: false))
                                } else {
                                    reply = .string(await journal.call(kind: kind, id: id, args: args, line: Int(line)))
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
        func perform(_ input: [String: JSONValue], host: any OwnedProgramHostProfile, execution: OwnedProgramExecution) async -> JSONValue {
            await call { await host.perform(input, execution: execution) }
        }
        func primitive(_ operation: String, arguments: JSONValue, preview: Bool, host: any OwnedProgramHostProfile,
            execution: OwnedProgramExecution) async -> JSONValue {
            await call {
                do { return try await host.primitive(operation, arguments: arguments, preview: preview, execution: execution) }
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
                        let result = if Task.isCancelled { Self.cancellation } else { await operation() }
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
            let action: Task<Void, Never>? = lock.withLock {
                guard !cancelled else { return nil }
                cancelled = true
                if let active { settling.append(active.task) }
                return active?.task
            }
            // Keep the continuation until the host actually answers so its result can be journaled after the helper stops.
            action?.cancel()
        }
        func finish() async {
            cancel()
            let tasks = lock.withLock { settling }
            for task in tasks { await task.value }
        }
    }
    /// Unclear strict receipts remain visible to the script and retain unknown write effects in the ledger.
    enum Outcome { case ok, preview, failed, stop, unclear }
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
        if fields["status"] == .string("preview") {
            let refused = text("would_refuse")
            if fields["owner"] == .string("person") { return (.stop, refused.isEmpty ? "owners_call" : refused, detail) }
            if fields["would_card"] == .bool(true) { return (.stop, "would_card", detail) }
            return refused.isEmpty ? (.preview, "", detail) : (.failed, refused, detail)
        }
        if fields["status"] == .string("did_not_stick") { return (.failed, "did_not_stick", detail) }
        // An unanswered on-screen card requires the person; it is not a completed decision.
        if fields["status"] == .string("needs_glass") { return (.stop, "needs_glass", String(text("reason").prefix(400))) }
        if evidence.successful {
            guard strict, let fault = strictFault(fields, write: write, host: host, outer: evidence) else { return (.ok, "", detail) }
            return (.unclear, fault, detail.isEmpty ? "Its receipt is not a clear success (\(fault))." : detail)
        }
        let reason = [text("reason"), text("failure_code")].first { !$0.isEmpty && !$0.contains(" ") } ?? "failed"
        return (host.floorReasons.contains(reason) ? .stop : .failed, reason, detail)
    }
    /// Judge strict success through every nested result: writes require terminal success, and reads reject failures, nonfinal status, previews and partial or
    /// unknown effects.
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
    static func resultChain(_ fields: [String: JSONValue]) -> [[String: JSONValue]] {
        var chain = [fields]
        while case .object(let inner)? = chain.last?["result"] { chain.append(inner) }
        return chain
    }
    /// Aggregate nested effects with unknown over partial over occurred, regardless of the outer receipt.
    package static func effects(_ fields: [String: JSONValue]) -> JSONValue? {
        let said = resultChain(fields).map { text($0["effects"]) }.filter { !$0.isEmpty }
        return (["unknown", "partial", "occurred"].first(where: said.contains) ?? said.first).map(JSONValue.string)
    }
    /// Retain real ids through nested objects regardless of result size; lists and input echoes do not supply them.
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
        public let tryInstead: JSONValue?
        public init(reason: String, detail: String, tryInstead: JSONValue? = nil) {
            self.reason = reason; self.detail = detail; self.tryInstead = tryInstead
        }
    }
    /// Resume replays calls from the journal without executing them, answers the stop point, and refuses any divergent call before dispatch.
    public struct Replay: Sendable {
        public let journal: [JSONValue]
        public let answer: JSONValue
        public let recheckReads: Bool
        public init(journal: [JSONValue], answer: JSONValue, recheckReads: Bool = true) {
            self.journal = journal; self.answer = answer; self.recheckReads = recheckReads
        }
    }
    static func readValue(_ out: String) -> JSONValue {
        guard case .object(var fields)? = try? JSONValue.parse(Data(out.utf8)) else { return .string(out) }
        for key in ["n", "line"] { fields.removeValue(forKey: key) }
        return fields["value"] ?? .object(fields)
    }
    /// Use owner-declared volatile projections for journal comparisons while returning the complete result to the script.
    public final class ReadContent: @unchecked Sendable {
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
        func digest(_ value: JSONValue) throws -> String {
            let dependencies = lock.withLock { self.dependencies }
            let content: JSONValue = if case .object(let fields) = value, let version = fields["version"] {
                .object(["version": version])
            } else { normalize(value) }
            return try JSONValue.array([content, .array(dependencies.map(normalize))]).digest
        }
    }
    /// Read and write versions must come from the run's own ordered journal.
    public static func ownVersions(_ journal: [JSONValue]) -> [String] {
        journal.compactMap { entry -> String? in
            guard case .object(let fields) = entry, case .array(let call)? = fields["call"], let kind = call.first,
                  case .string(let out)? = fields["out"], case .object(let value) = readValue(out) else { return nil }
            return (kind == .string("read") ? value["version"] : value["page_version"])?.scalarText
        }
    }
    static func target(_ entry: JSONValue, host: any OwnedProgramHostProfile) throws -> (page: String, item: String?, write: Bool)? {
        guard case .object(let fields) = entry, case .array(let call)? = fields["call"], call.count > 2,
              case .string(let kind) = call[0], case .string(let id) = call[1], case .string(let raw) = call[2] else { return nil }
        guard case .array(let given)? = try? JSONValue.parse(Data(raw.utf8)) else { return nil }
        func lower(_ value: JSONValue?) -> String? { value?.scalarText?.lowercased() }
        if kind == "read", let page = lower(given.first) { return (page, given.count > 1 ? lower(given[1]) : nil, false) }
        guard ["action", "primitive"].contains(kind),
              let action = try kind == "primitive" ? host.primitiveAction(id) : host.action(id) else { return nil }
        let args: [String: JSONValue] = if case .object(let named)? = given.first { named } else { [:] }
        guard let page = action.page == "*" ? lower(args["page"]) : action.page.lowercased() else { return nil }
        return (page, lower(args["handle"]) ?? lower(args["id"]) ?? lower(args["item"]), !action.readOnly(args))
    }
    public static func versionScope(_ version: String) -> String {
        version.split(separator: "@", maxSplits: 1).first.map(String.init) ?? version
    }
    /// A changed read is named by its version, else by its value's measured identity (size and digest), never by its text.
    static func brief(_ out: String) -> JSONValue {
        let value = readValue(out)
        if case .object(let fields) = value, let version = fields["version"] { return version }
        return (try? CallLedger.measured(value)).map(JSONValue.object) ?? .object(["result_bytes": .null])
    }
}
