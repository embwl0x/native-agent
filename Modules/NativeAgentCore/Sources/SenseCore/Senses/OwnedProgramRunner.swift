import Dispatch
import Synchronization
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
    private final class CachedAnalysis: NSObject {
        let value: OwnedProgram.Analysis
        init(_ value: OwnedProgram.Analysis) { self.value = value }
    }
    private static let analyses: Mutex<NSCache<NSString, CachedAnalysis>> = {
        let values = NSCache<NSString, CachedAnalysis>()
        values.totalCostLimit = 16 * 1024 * 1024
        return Mutex(values)
    }()
    private static let helpers = HelperSupervisor()
    private var profileIdentity: UUID?
    private struct Domain: Equatable, Sendable {
        let root: URL
        let helper: URL
        let profile: UUID?
    }
    private var domain: Domain { Domain(root: dataRoot.standardizedFileURL, helper: helperURL, profile: profileIdentity) }

    private final class HelperSupervisor: Sendable {
        private struct State {
            var closed = false
            var filling = 0
            var standby: [(Domain, OwnedProgramProcess)] = []
            var idle: [(Domain, OwnedProgram?, OwnedProgramProcess)] = []
        }
        private let state = Mutex(State())

        func warm(_ runner: OwnedProgramRunner) {
            let slots = state.withLock { state in
                let slots = state.closed ? 0 : max(0, 2 - state.standby.count - state.filling)
                state.filling += slots
                return slots
            }
            for _ in 0..<slots {
                DispatchQueue.global(qos: .utility).async { [self] in
                    do {
                        let process = try runner.spawn { [weak self] process in
                            guard let self else { return }
                            let lost = state.withLock { state in
                                guard let i = state.standby.firstIndex(where: { $0.1 === process }) else { return false }
                                state.standby.remove(at: i)
                                return true
                            }
                            if lost { warm(runner) }
                        }
                        let exited = state.withLock { state in
                            state.filling -= 1
                            if state.closed { process.stop() }
                            else if !process.isRunning { return true }
                            else { state.standby.append((runner.domain, process)) }
                            return false
                        }
                        if exited { warm(runner) }
                    } catch {
                        state.withLock { state in state.filling -= 1 }
                        ModuleLog.app("[program] standby launch failed: %@", error.localizedDescription)
                    }
                }
            }
        }

        func pristine(_ runner: OwnedProgramRunner) throws -> OwnedProgramProcess {
            let kept: OwnedProgramProcess? = try state.withLock { state in
                guard !state.closed else { throw CancellationError() }
                guard let i = state.standby.firstIndex(where: { $0.0 == runner.domain && $0.1.isReady }) else {
                    if state.standby.count == 2, let other = state.standby.firstIndex(where: { $0.0 != runner.domain }) {
                        state.standby.remove(at: other).1.stop()
                    }
                    return nil
                }
                return state.standby.remove(at: i).1
            }
            defer { warm(runner) }
            let process = try kept ?? runner.spawn()
            guard state.withLock({ !$0.closed }) else { process.stop(); throw CancellationError() }
            return process
        }

        func take(_ runner: OwnedProgramRunner, program: OwnedProgram?) throws -> Held {
            let domain = runner.domain
            let kept: OwnedProgramProcess? = try state.withLock { state in
                guard !state.closed else { throw CancellationError() }
                state.idle.removeAll { !$0.2.isRunning }
                guard let i = state.idle.lastIndex(where: { $0.0 == domain && $0.1 == program }) else { return nil }
                return state.idle.remove(at: i).2
            }
            let process = try kept ?? pristine(runner)
            return Held(process, reused: kept != nil) { [self] process in
                state.withLock { state in
                    guard !state.closed, process.isRunning else { process.stop(); return }
                    if state.idle.count == 8 { state.idle.removeFirst().2.stop() }
                    state.idle.append((domain, program, process))
                }
            }
        }

        func end() {
            state.withLock { state in
                state.closed = true
                state.standby.forEach { $0.1.stop() }
                state.idle.forEach { $0.2.stop() }
                state.standby.removeAll()
                state.idle.removeAll()
            }
        }
    }
    private final class Residents: Sendable {
        /// Resident holdings must outlive helpers dropped by failed runs.
        private struct Slot {
            let program: OwnedProgram
            var process: OwnedProgramProcess?
            var held: (value: any AnyObject & Sendable, end: @Sendable () async -> Void)?
            var busy = false
            func stop() -> (@Sendable () async -> Void)? { process?.stop(); return held?.end }
        }
        private struct State {
            var closed = false
            var teardowns: [String: (id: UUID, task: Task<Void, Never>)] = [:]
            var slots: [String: Slot] = [:] {
                didSet {
                    for key in Array(vacancies.keys) where slots[key]?.busy != true && teardowns[key] == nil {
                        vacancies.removeValue(forKey: key)?.forEach { $0.resume() }
                    }
                }
            }
            var turnedAway: Set<String> = []
            var vacancies: [String: [ScopedWaiter]] = [:]
        }
        private let state = Mutex(State())
        private let observer = Mutex<HeldHandle<NSObjectProtocol>?>(nil)
        init() {
            let token = NotificationCenter.default.observeSynchronously(for: AbilityStore.DidChange.self) { [weak self] change in
                guard let self else { return }
                self.state.withLock { self.retire(change.path, in: &$0) }
            }
            let held = HeldHandle(token)
            observer.withLock { $0 = held }
        }
        /// Under the pool lock, remove admission before starting retained teardown.
        private func retire(_ key: String, in pool: inout State) {
            guard let slot = pool.slots[key] else { return }
            if let end = slot.stop() {
                let id = UUID()
                pool.teardowns[key] = (id, Task {
                    await end()
                    self.state.withLock { pool in
                        guard pool.teardowns[key]?.id == id else { return }
                        pool.teardowns.removeValue(forKey: key)
                        pool.vacancies.removeValue(forKey: key)?.forEach { $0.resume() }
                    }
                })
            }
            pool.slots.removeValue(forKey: key)
        }
        func settle(_ store: AbilityStore, program: OwnedProgram) async throws {
            try Task.checkCancellation()
            let key = store.root.appendingPathComponent(program.id).path
            while let flight = try AbilityStore.withLock({ () throws -> Task<Void, Never>? in
                // Revalidate after teardown awaits so stale callers cannot retire or replace their successors.
                try selected(store, program)
                return try state.withLock { pool in
                    guard !pool.closed else { throw CancellationError() }
                    if let slot = pool.slots[key], slot.program != program { retire(key, in: &pool) }
                    return pool.teardowns[key]?.task
                }
            }) {
                await flight.value
                try Task.checkCancellation()
            }
        }
        private func admit(_ key: String, in pool: borrowing State) throws {
            guard !pool.closed, pool.teardowns[key] == nil else { throw CancellationError() }
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
                return try state.withLock { pool in
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key, in: pool)
                    if let slot = pool.slots[key], slot.program != program { retire(key, in: &pool); throw CancellationError() }
                    if pool.slots[key] == nil { pool.slots[key] = Slot(program: program) }
                    if let value = pool.slots[key]?.held?.value as? Held { return value }
                    let value = make()
                    pool.slots[key]?.held = (value, { await end(value) })
                    return value
                }
            }
        }
        func turnAway(_ key: String) { state.withLock { pool in _ = pool.turnedAway.insert(key) } }
        func waitIfTurnedAway(_ key: String, deadline: ContinuousClock.Instant?) async -> Bool {
            guard state.withLock({ $0.turnedAway.remove(key) != nil }) else { return false }
            let vacancy = ScopedWaiter()
            state.withLock { pool in
                if !pool.closed && (pool.slots[key]?.busy == true || pool.teardowns[key] != nil) { pool.vacancies[key, default: []].append(vacancy) }
                else { vacancy.resume() }
            }
            await vacancy.park(budget: .init(deadline: deadline))
            state.withLock { pool in
                pool.vacancies[key]?.removeAll { $0 === vacancy }
                if pool.vacancies[key]?.isEmpty == true { pool.vacancies.removeValue(forKey: key) }
            }
            if Task.isCancelled { ModuleLog.app("[resident] cancelled vacancy wait released: %@", URL(fileURLWithPath: key).lastPathComponent) }
            return true
        }
        func end() async {
            let flights = state.withLock { pool in
                pool.closed = true
                for key in Array(pool.slots.keys) { retire(key, in: &pool) }
                for waiting in pool.vacancies.values { waiting.forEach { $0.resume() } }
                pool.vacancies.removeAll(); pool.turnedAway.removeAll()
                return pool.teardowns.values.map(\.task)
            }
            observer.withLock { token in
                if let token { NotificationCenter.default.removeObserver(token.value) }
                token = nil
            }
            for flight in flights { await flight.value }
        }
        func take(_ store: AbilityStore, program: OwnedProgram, create: () throws -> OwnedProgramProcess) throws -> OwnedProgramProcess {
            // Selection and lease publication share the mutation lock in store/pool order.
            try AbilityStore.withLock {
                try selected(store, program)
                return try state.withLock { pool in
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key, in: pool)
                    if let slot = pool.slots[key] {
                        guard !slot.busy else {
                            throw SenseFailure(code: "busy", message: "Resident ability \(program.id) is already running; wait for its call to finish.")
                        }
                        if slot.program == program, let process = slot.process, process.isRunning, process.failure == nil {
                            pool.slots[key]?.busy = true
                            return process
                        }
                        slot.process?.stop(); pool.slots[key]?.process = nil
                        if slot.program != program { retire(key, in: &pool); throw CancellationError() }
                    }
                    let process = try create()
                    pool.slots[key, default: Slot(program: program)].process = process
                    pool.slots[key]?.busy = true
                    return process
                }
            }
        }
        /// Resume takes the resident slot's exclusive lease so live calls cannot overlap its holdings.
        func lease(_ store: AbilityStore, program: OwnedProgram) throws -> String {
            try AbilityStore.withLock {
                try selected(store, program)
                return try state.withLock { pool in
                    let key = store.root.appendingPathComponent(program.id).path
                    try admit(key, in: pool)
                    guard pool.slots[key]?.busy != true else {
                        throw SenseFailure(code: "busy", message: "Resident ability \(program.id) is already running; wait for its call to finish.")
                    }
                    pool.slots[key, default: Slot(program: program)].busy = true
                    return key
                }
            }
        }
        func unlease(_ key: String, program: OwnedProgram) {
            state.withLock { pool in if pool.slots[key]?.program == program { pool.slots[key]?.busy = false } }
        }
        func release(_ key: String, process: OwnedProgramProcess, keep: Bool) {
            state.withLock { pool in
                guard pool.slots[key]?.process === process else { return }
                pool.slots[key]?.busy = false
                if keep { return }
                // A failed run drops its helper and context without releasing resident holdings.
                process.stop(); pool.slots[key]?.process = nil
                if pool.slots[key]?.held == nil { pool.slots.removeValue(forKey: key) }
            }
        }
    }
    public init(helperURL: URL = SenseHostLocator.helperURL, dataRoot: URL, sandboxProfile: @escaping SandboxProfile) {
        self.profileIdentity = UUID()
        self.helperURL = helperURL; self.dataRoot = dataRoot; self.sandboxProfile = sandboxProfile
    }
    public init(dataRoot: URL) {
        let helper = SenseHostLocator.helperURL
        self.init(helperURL: helper, dataRoot: dataRoot) { scratch in
            try SenseSandboxProfile.build(reach: SenseReach(), helperURL: helper, scratch: scratch,
                dataRoot: dataRoot, personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        }
        profileIdentity = nil
    }
    public func warmHelpers() { Self.helpers.warm(self) }
    public final class Held: Sendable {
        fileprivate let process: OwnedProgramProcess
        public let reused: Bool
        private let release: (@Sendable (OwnedProgramProcess) -> Void)?
        fileprivate init(_ process: OwnedProgramProcess, reused: Bool = false,
                         release: (@Sendable (OwnedProgramProcess) -> Void)? = nil) {
            self.process = process; self.reused = reused; self.release = release
        }
        deinit { if let release { release(process) } else { process.stop() } }
    }
    public func hold() throws -> Held { Held(try Self.helpers.pristine(self)) }
    /// Attempt admission once without capacity waits so callers can end accepted turns even if helper resources never become available.
    public func holdTurn(_ program: OwnedProgram) throws -> Held {
        try Task.checkCancellation()
        guard program.kind == .turn, program.isResident else {
            throw SenseFailure(code: "bad_input", message: "Only a resident turn program can lease a turn helper.")
        }
        do {
            return try Self.helpers.take(self, program: program)
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
    public static func endResidents() async { helpers.end(); await residents.end() }
    /// Wait only for release, cancellation or the supplied deadline; wake is not proof of vacancy, so revalidate admission afterward.
    public static func waitedForSlot(_ id: String, dataRoot: URL, deadline: ContinuousClock.Instant?) async -> Bool {
        await residents.waitIfTurnedAway(AbilityStore(dataRoot: dataRoot).root.appendingPathComponent(id).path, deadline: deadline)
    }
    private func spawn(onExit: @escaping @Sendable (OwnedProgramProcess) -> Void = { _ in }) throws -> OwnedProgramProcess {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("program-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do { return try OwnedProgramProcess(helper: helperURL, profile: sandboxProfile(scratch), scratch: scratch, onExit: onExit) }
        catch { try? FileManager.default.removeItem(at: scratch); throw error }
    }
    public func analyze(_ program: OwnedProgram) async throws -> OwnedProgram.Analysis {
        if let analysis = program.analysis { return analysis }
        return try await analyze(program.source)
    }
    @concurrent public func analyze(_ source: String) async throws -> OwnedProgram.Analysis {
        guard source.utf8.count <= Self.sourceLimit else {
            throw SenseFailure(code: "input_limit", message: "Program source exceeds \(Self.sourceLimit) bytes.")
        }
        try Task.checkCancellation()
        let digest = SHA256Hex.of(utf8: source)
        if let cached = Self.analyses.withLock({ $0.object(forKey: digest as NSString)?.value }) { return cached }
        let parser = OwnedProgramRunner(dataRoot: dataRoot)
        let held = try Self.helpers.take(parser, program: nil)
        defer { withExtendedLifetime(held) {} }
        let process = held.process
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                process.begin(id: 1, seconds: nil)
                try process.send(.object(["id": .int(1), "type": .string("analyze"), "source": .string(source)]))
                for await event in process.events {
                    try Task.checkCancellation()
                    switch event {
                    case .ended(let detail): throw process.failure ?? SenseFailure(code: "crashed", message: detail)
                    case .frame(let frame):
                        guard frame.flags == 0, case .object(let fields) = try JSONValue.parse(frame.header), fields["id"] == .int(1) else {
                            throw SenseFailure(code: "bad_output", message: "Invalid analyzer reply.")
                        }
                        if fields["type"] == .string("failed"), let failure = fields["failure"] {
                            throw try JSONDecoder().decode(SenseFailure.self, from: JSONEncoder().encode(failure))
                        }
                        guard fields["type"] == .string("analysis"), let json = fields["facts"]?.stringValue else {
                            throw SenseFailure(code: "bad_output", message: "Expected exact-source analysis.")
                        }
                        try process.claimCompletion(1)
                        let analysis = try OwnedProgram.Analysis(data: Data(json.utf8), source: source)
                        Self.analyses.withLock { $0.setObject(CachedAnalysis(analysis), forKey: digest as NSString, cost: json.utf8.count + source.utf8.count) }
                        return analysis
                    }
                }
                try Task.checkCancellation()
                throw process.failure ?? SenseFailure(code: "crashed", message: "Sense helper closed before returning its analysis.")
            } onCancel: { process.stop() }
        } catch {
            process.stop()
            throw error
        }
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
    @concurrent func run(_ program: OwnedProgram, input: JSONValue?, preview: Bool, replay: Replay?,
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
    private func executeEffect(_ selected: OwnedProgram, input: JSONValue?, preview: Bool,
                         replay: Replay?, host: any OwnedProgramHostProfile, execution: OwnedProgramExecution, held: Held?,
                             actions: ActionTasks) async -> JSONValue {
        let execution: OwnedProgramExecution = {
            var held = execution
            held.input = input; held.preview = preview
            if var turn = held.turn {
                turn.partID = selected.id; turn.abilityID = selected.isPart ? selected.id : nil
                held.turn = turn
            }
            return held
        }()
        let journal = Journal(source: selected.source, preview: preview, program: selected,
                              replay: replay, host: host, execution: execution, actionsInFlight: actions, notebookRoot: dataRoot, partID: selected.id)
        do {
            var analyzed = selected
            if analyzed.isPart && analyzed.analysis == nil { analyzed.analysis = try await analyze(selected.source) }
            let program = analyzed
            journal.strict = program.isStrict
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
            let pooled = live && !resident && (program.isPart || program.entry == .face)
                ? try Self.helpers.take(self, program: program) : nil
            let process: OwnedProgramProcess
            if let held { process = held.process }
            else if resident { process = try Self.residents.take(store, program: program, create: { try Self.helpers.pristine(self) }) }
            else if let pooled { process = pooled.process }
            else { process = try Self.helpers.pristine(self) }
            if let fixture = host as? OwnedProgramFixtures {
                // All passes of one fixture share its notebook; other fixtures on this helper have their own.
                journal.notebookRoot = process.scratch.appendingPathComponent(fixture.notebookID)
            } else if preview { journal.notebookRoot = process.scratch }
            var keep = false
            defer {
                process.end(1); actions.cancel()
                if resident { Self.residents.release(key, process: process, keep: keep) }
                else if (held == nil && pooled == nil) || !keep { process.stop() }
                withExtendedLifetime(pooled) {}
            }
            return await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    var message: [String: JSONValue] = [
                        "id": .int(1), "type": .string("run"), "program": try .fromEncodable(program),
                    ]
                    message["freshContext"] = .bool(!resident)
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
                    process.begin(id: 1, seconds: program.seconds, onFailure: { _ in actions.cancel() })
                    try process.send(.object(message))
                    var lastCallID: Int64 = 0
                    var admittedNames: [String]?
                    for await event in process.events {
                        try Task.checkCancellation()
                        switch event {
                        case .ended(let detail): throw SenseFailure(code: "crashed", message: detail)
                        case .frame(let frame):
                            guard case .object(let fields) = try JSONValue.parse(frame.header), fields["id"] == .int(1),
                                  case .string(let type)? = fields["type"], frame.flags == (type == "app_call" ? 2 : 0) else {
                                throw SenseFailure(code: "bad_output", message: "Program helper sent an invalid message.")
                            }
                            if type == "failed" {
                                let failure = try JSONDecoder().decode(SenseFailure.self, from: JSONEncoder().encode(fields["failure"] ?? .null))
                                journal.fail(failure)
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
                            if type == "binding_names", case .string(let space)? = fields["space"] {
                                let started = try process.suspend(1)
                                let names = try admittedNames ?? host.actionIDs
                                admittedNames = names
                                let selected = space.isEmpty ? names : names.filter { $0 == space || $0.hasPrefix(space + ".") }
                                try process.resume(1, since: started)
                                try process.send(.object(["id": .int(1), "type": .string("binding_reply"),
                                    "callID": .int(callID), "names": .array(selected.map(JSONValue.string))]))
                                continue
                            }
                            if type == "script_log", case .string(let text)? = fields["text"] {
                                journal.say(text); continue
                            }
                            var reply: String
                            if type == "app_call", case .string(let kind)? = fields["kind"],
                               case .string(let id)? = fields["action"],
                               case .int(let line)? = fields["line"] {
                                guard !["primitive", "state"].contains(kind) || program.isPart else {
                                    throw SenseFailure(code: "bad_output", message: "Only an ability reaches host primitives and host.state.")
                                }
                                // Host work counts as progress; only unaccompanied JavaScript may stall.
                                let waitStarted = try process.suspend(1)
                                if program.kind == .turn, kind == "turn" {
                                    reply = try JSONValue.object(["ok": .bool(true), "value": try await host.reach(id, execution: execution)])
                                        .serialize(pretty: false)
                                } else {
                                    reply = await journal.call(kind: kind, id: id, args: frame.payload, line: Int(line))
                                }
                                try process.resume(1, since: waitStarted)
                            } else { throw SenseFailure(code: "bad_output", message: "Program called an API outside its host profile.") }
                            if fields["kind"] != .string("state") { try process.renewProgress(1) }
                            try process.send(.object(["type": .string("host_reply"), "id": .int(1),
                                                      "callID": .int(callID)]), flags: 2, payload: Data(reply.utf8))
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
    final class ActionTasks: Sendable {
        private struct State {
            var active: (task: Task<Void, Never>, reply: CheckedContinuation<JSONValue, Never>)?
            var cancelled = false
            var settling: [Task<Void, Never>] = []
        }
        private let state = Mutex(State())
        var isCancelled: Bool { state.withLock { $0.cancelled } }
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
                state.withLock { state in
                    guard !state.cancelled, !Task.isCancelled else { continuation.resume(returning: Self.cancellation); return }
                    let task = Task {
                        let result = if Task.isCancelled { Self.cancellation } else { await operation() }
                        let reply = self.state.withLock { state in
                            defer { state.active = nil }
                            return state.active?.reply
                        }
                        reply?.resume(returning: result)
                    }
                    state.active = (task, continuation)
                }
            }
        }
        func cancel() {
            let action: Task<Void, Never>? = state.withLock { state in
                guard !state.cancelled else { return nil }
                state.cancelled = true
                if let active = state.active { state.settling.append(active.task) }
                return state.active?.task
            }
            // Keep the continuation until the host actually answers so its result can be journaled after the helper stops.
            action?.cancel()
        }
        func finish() async {
            cancel()
            let tasks = state.withLock { $0.settling }
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
        let detail = String([text("detail"), text("message")].first { !$0.isEmpty }?.prefix(400) ?? "")
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
            let status = JSONValue.trimmedScalarTextOrEmpty(at["status"]).lowercased()
            let reason = JSONValue.trimmedScalarTextOrEmpty(at["reason"])
            let effects = JSONValue.trimmedScalarTextOrEmpty(at["effects"])
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
        let said = resultChain(fields).map { JSONValue.trimmedScalarTextOrEmpty($0["effects"]) }.filter { !$0.isEmpty }
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
    public final class ReadContent: Sendable {
        private let declarations = Mutex<[(value: JSONValue, content: JSONValue)]>([])
        private let dependencies = Mutex<[JSONValue]>([])
        public func record(_ value: JSONValue, content: JSONValue) {
            guard value != content else { return }
            declarations.withLock { $0.append((value, content)) }
        }
        public func depend(on content: JSONValue) {
            dependencies.withLock { $0.append(content) }
        }
        var projections: JSONValue {
            declarations.withLock { declarations in
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
            let declarations = self.declarations.withLock { $0 }
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
        func digest(_ value: JSONValue) throws -> String {
            let dependencies = self.dependencies.withLock { $0 }
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
