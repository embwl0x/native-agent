import AuthoredCapabilities
import Foundation
import CryptoKit
import Darwin
import PersistenceCore
import NativeAgentCore
// Blueprint: | `HelperSenseRunner.swift` | Isolated plug supervision with validated progress-based stall detection excluding app-served reply waits, read-to-watch idle holds, subscription-owned lifetime and restarts; source callbacks keep newest material and signal EnginePartWake for unattended interpretation, fenced by helper generation; canonical sense disable/replacement retires only that selected lifetime's passive helpers (including unattended on-call wakes) and pending admissions; late retirement and failure reporting cannot affect a replacement, and availability reports rejected by the registry post no news, while sense-identified accepted human on-call work settles with its requesting owner; notebook access delegates to AbilityStore; versioned use and visible live failure news, sealed view events, detached site following and app change deduplication/news; app reads use assembly's Trust-admitted read closure |

/// One sandboxed helper per live sense/source; on-call helpers are discarded after
/// their answer. Only a caller's act request can reach the installed door.
public actor HelperSenseRunner: SenseRunner, SenseViewEventReceiver {
    public typealias SandboxProfile = @Sendable (SenseRecord, URL, URL) throws -> String

    public struct Limits: Sendable {
        /// Stall window, renewed only by accepted progress; never an execution cap.
        public var requestSeconds: TimeInterval = 30
        public var idleSeconds: TimeInterval = 300
        public var memoryBytes: UInt64 = 256 * 1_024 * 1_024
        public init() {}
    }

    private struct Live {
        let record: SenseRecord
        let selection: String
        var source: any SenseSourceProvider
        var process: SenseHelperProcess?
        var generation: UUID
        var failures: Set<String> = []
        var address: String?
        var following = false
        var idleAt: Date
        var idle: Task<Void, Never>?
    }

    private let dataRoot: URL
    private let fileRegistry: FileSenseRegistry
    private let helperURL: URL
    private let profile: SandboxProfile
    private let limits: Limits
    private let apps: (@Sendable (JSONValue, [String: String]) async throws -> JSONValue)?
    private var live: [String: Live] = [:]
    private struct Call {
        let selection: String
        let passive: Bool
        let process: SenseHelperProcess
    }
    private var onCall: [UUID: Call] = [:]
    private var admissions: [UUID: String] = [:]
    private var viewAddresses: [String: (selection: String, address: String?)] = [:]
    private var shutDown = false

    public init(dataRoot: URL, helperURL: URL, sandboxProfile: @escaping SandboxProfile,
                limits: Limits = Limits(), apps: (@Sendable (JSONValue, [String: String]) async throws -> JSONValue)? = nil) {
        self.dataRoot = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.fileRegistry = FileSenseRegistry(dataRoot: dataRoot)
        self.helperURL = helperURL
        self.profile = sandboxProfile
        self.limits = limits
        self.apps = apps
    }

    public func run(_ record: SenseRecord, request: SenseRequest,
                    source: any SenseSourceProvider) async -> SenseOutcome {
        if request == .watch, !SensesHub.passiveObservation {
            return await SensesHub.$passiveObservation.withValue(true) {
                await run(record, request: request, source: source)
            }
        }
        let provenance = SenseProvenance(record: record)
        if case .act = request, !record.verbsEnabled || SenseActionContext.perform == nil {
            return .failed(SenseFailure(code: "act_denied", message: "Sense actions require enabled verbs and an active app door.", provenance: provenance))
        }
        guard !shutDown else {
            return .failed(SenseFailure(code: "unavailable", message: "Sense runner has shut down.", provenance: provenance))
        }
        if record.status == .off {
            return .failed(SenseFailure(code: "disabled", message: "Sense is off.", provenance: provenance))
        }
        if record.status == .unavailable {
            return .failed(SenseFailure(code: "sense_unavailable", message: record.unavailableReason ?? "Sense is unavailable; repair it and switch it on to retry.", provenance: provenance))
        }
        guard limits.requestSeconds.isFinite, limits.requestSeconds > 0,
              limits.idleSeconds.isFinite, limits.idleSeconds >= limits.requestSeconds,
              limits.memoryBytes > 0 else {
            return .failed(SenseFailure(code: "bad_limits", message: "Sense runner limits are invalid.", provenance: provenance))
        }
        guard !Task.isCancelled else {
            return .failed(SenseFailure(code: "cancelled", message: "Sense request cancelled.", provenance: provenance))
        }
        if record.language == .native {
            guard let sense = NativeSenseCatalog.shared.sense(id: record.id) else {
                return .failed(SenseFailure(code: "unsupported", message: "Native sense is not registered.", provenance: provenance))
            }
            let perform: SenseActionContext.Perform? = if case .act = request { SenseActionContext.perform } else { nil }
            let outcome = await SenseActionContext.$perform.withValue(perform) {
                await sense.run(request, source: source)
            }
            return await complete(outcome, record: record, request: request)
        }
        var selected: String?
        do {
            let selection = try fileRegistry.helperSelection(record)
            selected = selection
            try requireHelper()
            let process: SenseHelperProcess
            let callID = UUID()
            admissions[callID] = selection
            defer { admissions.removeValue(forKey: callID) }
            let address: String? = switch request {
            case .read(let address): address
            case .act(_, let address, _): address
            case .watch: nil
            }
            let key = try await slotKey(record, selection: selection, source: source, address: address)
            if record.status == .on, let registry = SensesHub.shared.registry {
                guard let current = try await registry.sense(for: record.corner),
                      current.status == .on, try fileRegistry.helperSelection(current) == selection else {
                    throw CancellationError()
                }
            }
            try requireRunning()
            try Task.checkCancellation()
            guard admissions[callID] == selection else { throw CancellationError() }
            let generation: UUID
            if record.mode == .live {
                if let slot = live[key], let existing = slot.process {
                    generation = slot.generation
                    if case .site = record.corner {
                        if case .read = request {
                            live[key]?.address = address
                            live[key]?.source = source
                        }
                    } else { live[key]?.address = address }
                    armIdle(key)
                    process = existing
                } else {
                    generation = UUID()
                    let created = try makeProcess(record, key: key, generation: generation, address: address)
                    live[key] = Live(record: record, selection: selection, source: source, process: created,
                        generation: generation, failures: live[key]?.failures ?? [], address: address, idleAt: Date().addingTimeInterval(limits.idleSeconds))
                    armIdle(key)
                    process = created
                }
            } else {
                generation = UUID()
                process = try makeProcess(record, key: key, generation: generation, address: address)
                onCall[callID] = Call(selection: selection, passive: SensesHub.passiveObservation, process: process)
            }
            let outcome: SenseOutcome
            if record.mode == .live, request != .watch {
                let result = await process.requestFollowing(request, source: source, perform: SenseActionContext.perform)
                outcome = result.outcome
                if live[key]?.generation == generation {
                    live[key]?.following = result.following
                    armIdle(key)
                }
                if let failure = result.watchFailure, !shutDown, admissions[callID] == selection {
                    _ = await complete(.failed(failure), record: record, request: .watch, selection: selection)
                    if record.status == .on {
                        await SenseNewsBoard.shared.post(SenseNews(senseID: record.id, version: record.version,
                            address: address ?? record.corner.key,
                            summary: "Live updates could not start: \(ContextSecretContentPolicy.redactedFragment(failure.message))\n\(provenance.line(now: Date()))", at: Date()))
                    }
                }
            } else {
                outcome = await process.request(request, source: source, perform: SenseActionContext.perform)
            }
            if record.mode == .onCall {
                await process.stop()
                onCall.removeValue(forKey: callID)
            }
            if let view = await SenseNewsBoard.shared.interactiveView(), view.senseID == record.id, view.version == record.version {
                if !shutDown, !Task.isCancelled, admissions[callID] == selection {
                    viewAddresses[record.id] = (selection, address)
                }
            }
            return await complete(outcome, record: record, request: request, selection: selection)
        } catch {
            return await complete(.failed(Self.failure(error, provenance: provenance)), record: record, request: request, selection: selected)
        }
    }

    private func complete(_ outcome: SenseOutcome, record: SenseRecord, request: SenseRequest, selection: String? = nil) async -> SenseOutcome {
        guard !Task.isCancelled else {
            return .failed(SenseFailure(code: "cancelled", message: "Sense request cancelled.", provenance: SenseProvenance(record: record)))
        }
        guard !shutDown else {
            return .failed(SenseFailure(code: "unavailable", message: "Sense runner has shut down.", provenance: SenseProvenance(record: record)))
        }
        var outcome = Self.attributed(outcome, to: record)
        if let selection, case .failed(let failure) = outcome,
           ["helper_missing", "helper_not_executable", "spawn_failed"].contains(failure.code)
            || (record.mode == .onCall && ["crashed", "resource_limit", "timeout", "bad_output"].contains(failure.code)) {
            await unavailable(record, selection: selection, failure: failure)
        }
        if case .page(var page, var provenance) = outcome {
            guard page.text.utf8.count <= NativePage.maximumTextBytes else {
                return await complete(.failed(SenseFailure(code: "bad_output", message: "Sense page exceeds the text ceiling; fold it and offer more.")), record: record, request: request, selection: selection)
            }
            if record.status == .on, !record.verbsEnabled { for i in page.things.indices { page.things[i].verbs = [] } }
            if case .read = request, record.status == .on, let registry = SensesHub.shared.registry,
               (try? AbilityStore(dataRoot: dataRoot).read(id: record.id)) == nil {
                do { try await registry.recordUse(senseID: record.id, version: record.version) }
                catch { return .failed(Self.failure(error, provenance: provenance)) }
                provenance.uses += 1
            }
            outcome = .page(page, provenance)
        }
        return outcome
    }

    public func receiveViewEvent(_ event: JSONValue, for record: SenseRecord,
                                 source: any SenseSourceProvider) async throws {
        var selected: String?
        do {
            let unavailable = SenseFailure(code: "view_unavailable", message: "Sense view is no longer enabled or its event is too large.")
            let selection = try fileRegistry.helperSelection(record)
            selected = selection
            let token = UUID()
            admissions[token] = selection
            defer { admissions.removeValue(forKey: token) }
            guard !shutDown, record.language != .native, let registry = SensesHub.shared.registry else { throw unavailable }
            guard let current = try await registry.sense(for: record.corner), !shutDown,
                  current.status == .on, try fileRegistry.helperSelection(current) == selection,
                  try JSONEncoder().encode(event).count <= 16_384 else {
                throw unavailable
            }
            try requireHelper()
            let process: SenseHelperProcess
            let address = viewAddresses[record.id].flatMap { $0.selection == selection ? $0.address : nil }
            let key = try await slotKey(record, selection: selection, source: source, address: address)
            try requireRunning()
            try Task.checkCancellation()
            guard admissions[token] == selection else { throw CancellationError() }
            if let existing = live[key]?.process {
                process = existing
            } else if record.mode == .live {
                // A resident sense keeps the slot an event wakes, with its context.
                live[key]?.idle?.cancel()
                let generation = UUID()
                process = try makeProcess(record, key: key, generation: generation, address: address)
                live[key] = Live(record: record, selection: selection, source: source, process: process, generation: generation,
                                 failures: [], address: address, idleAt: Date().addingTimeInterval(limits.idleSeconds))
                armIdle(key)
            } else {
                process = try makeProcess(record, key: key, generation: UUID(), address: address)
                onCall[token] = Call(selection: selection, passive: SensesHub.passiveObservation, process: process)
            }
            let outcome = await SenseActionContext.$perform.withValue(nil) {
                await process.viewEvent(event, source: source)
            }
            if onCall[token] != nil { await process.stop(); onCall.removeValue(forKey: token) }
            if case .failed(let failure) = outcome { throw failure }
        } catch {
            let outcome = await complete(.failed(Self.failure(error, provenance: SenseProvenance(record: record))), record: record, request: .watch, selection: selected)
            if case .failed(let failure) = outcome { throw failure }
        }
    }

    func retire(selection: String) async {
        admissions = admissions.filter { $0.value != selection }
        viewAddresses = viewAddresses.filter { $0.value.selection != selection }
        // Close admission and detach all passive resources before the first await.
        let slots = live.filter { $0.value.selection == selection }
        for (key, slot) in slots { live.removeValue(forKey: key); slot.idle?.cancel() }
        let calls = onCall.filter { $0.value.selection == selection && $0.value.passive }
        for (id, _) in calls { onCall.removeValue(forKey: id) }
        // Accepted human reads/actions keep their call-owned helper until settlement.
        for slot in slots.values { await slot.process?.stop() }
        for call in calls.values { await call.process.stop() }
    }

    private func stopSlot(_ key: String) async {
        guard let slot = live.removeValue(forKey: key) else { return }
        slot.idle?.cancel()
        await slot.process?.stop()
    }

    public func shutdown() async {
        shutDown = true
        admissions.removeAll()
        viewAddresses.removeAll()
        for key in Array(live.keys) { await stopSlot(key) }
        let active = Array(onCall.values)
        onCall.removeAll()
        for call in active { await call.process.stop() }
    }

    private func requireRunning() throws {
        guard !shutDown else { throw SenseFailure(code: "unavailable", message: "Sense runner has shut down.") }
    }

    private func slotKey(_ record: SenseRecord, selection: String, source: any SenseSourceProvider, address: String?) async throws -> String {
        let identity: String
        if case .fileKind = record.corner, case .file(let path, _, _) = try await source.material(for: record.corner, address: address) {
            identity = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        } else { identity = record.corner.key }
        return record.id + "\0" + selection + "\0" + identity
    }

    private func makeProcess(_ record: SenseRecord, key: String, generation: UUID, address: String? = nil) throws -> SenseHelperProcess {
        // Shutdown is terminal; this actor check and helper publication never suspend.
        try requireRunning()
        try requireHelper()
        guard record.language == .javascript else {
            throw SenseFailure(code: "unsupported", message: "Authored senses require JavaScript. Convert this historical Swift sense before enabling it.")
        }
        guard !record.id.isEmpty, record.id != ".", record.id != "..",
              !record.id.contains("/"), !record.id.contains("\\"), record.version > 0,
              let entry = record.entry, !entry.isEmpty, !entry.hasPrefix("/") else {
            throw SenseFailure(code: "bad_entry", message: "Sense entry must stay inside its version folder.")
        }
        let registry = FileSenseRegistry(dataRoot: dataRoot)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sense-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        do {
            guard let code = try registry.sourceFiles(record)[entry], code.count <= AbilityStore.sourceLimit,
                  let script = String(data: code, encoding: .utf8) else {
                throw SenseFailure(code: "bad_entry", message: "Sense source must be UTF-8 and at most 512 KiB.")
            }
            let notebook = record.status == .draft ? scratch.appendingPathComponent("state.json") : AbilityStore.notebookPath(dataRoot: dataRoot, id: record.id)
            return try SenseHelperProcess(record: record, dataRoot: dataRoot, script: script, notebook: notebook,
                scratch: scratch, helper: helperURL, profile: profile(record, registry.root, scratch), limits: limits,
                initialAddress: address, apps: apps,
                onSourceChange: { [dataRoot] in
                    AbilityStore(dataRoot: dataRoot).signal("sense.source.changed", part: record.id,
                        ["slot": .string(key), "generation": .string(generation.uuidString)])
                },
                onSettled: { [weak self] in
                    await self?.settled(key, generation: generation)
                },
                onExit: { [weak self] failure in
                    await self?.crashed(key, generation: generation, failure: failure)
                })
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// Only EnginePartWake admits unattended interpretation. Material stays in
    /// the source-bound helper; a retired generation can never consume it.
    public func sourceChanged(slot key: String, generation: UUID) async {
        guard !shutDown, let slot = live[key], slot.generation == generation else { return }
        await slot.process?.drainChange()
    }

    private func requireHelper() throws {
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw SenseFailure(code: "helper_missing", message: "Tell the person: this copy of NativeAgent is missing its sense helper at \(helperURL.path).")
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw SenseFailure(code: "helper_not_executable", message: "Tell the person: NativeAgent's sense helper is not executable at \(helperURL.path).")
        }
    }

    private func armIdle(_ id: String) {
        guard var slot = live[id] else { return }
        slot.idle?.cancel()
        if slot.following { slot.idle = nil; live[id] = slot; return }
        slot.idleAt = Date().addingTimeInterval(limits.idleSeconds)
        let deadline = slot.idleAt
        slot.idle = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            await self?.expireIdle(id, deadline: deadline)
        }
        live[id] = slot
    }

    private func expireIdle(_ id: String, deadline: Date) async {
        guard let slot = live[id], slot.idleAt == deadline, !slot.following else { return }
        // Idle retention is not an entry limit. Settlement will revisit this
        // deadline if an entry is still running when it crosses.
        if let process = slot.process, !(await process.stopIfIdle()) { return }
        guard live[id]?.idleAt == deadline, live[id]?.generation == slot.generation else { return }
        await stopSlot(id)
    }

    private func settled(_ id: String, generation: UUID) async {
        guard let slot = live[id], slot.generation == generation, slot.idleAt <= Date() else { return }
        await expireIdle(id, deadline: slot.idleAt)
    }

    private func crashed(_ id: String, generation: UUID, failure: SenseFailure?) async {
        guard var slot = live[id], slot.generation == generation else { return }
        slot.process = nil
        guard let failure else { live.removeValue(forKey: id); return }
        let cause = ["timeout", "resource_limit", "bad_output", "output_limit", "registry_failure"].contains(failure.code) ? failure.code : "crashed"
        if !slot.failures.insert(cause).inserted {
            live.removeValue(forKey: id)?.idle?.cancel()
            await unavailable(slot.record, selection: slot.selection, failure: failure)
            return
        }
        live[id] = slot
        await restart(id, generation: generation)
    }

    private func restart(_ id: String, generation: UUID) async {
        guard var slot = live[id], slot.generation == generation, slot.following || slot.idleAt > Date() else { return }
        do {
            if let registry = SensesHub.shared.registry {
                guard let current = try await registry.sense(for: slot.record.corner), current.status == .on,
                      try fileRegistry.helperSelection(current) == slot.selection else { await stopSlot(id); return }
                guard let refreshed = live[id], refreshed.generation == generation else { return }
                slot = refreshed
            }
            let next = UUID()
            let process = try makeProcess(slot.record, key: id, generation: next, address: slot.address)
            slot.process = process; slot.generation = next
            live[id] = slot
            _ = await process.startWatching(source: slot.source)
        } catch {
            guard live[id]?.generation == generation else { return }
            live.removeValue(forKey: id)?.idle?.cancel()
            await unavailable(slot.record, selection: slot.selection, failure: Self.failure(error, provenance: SenseProvenance(record: slot.record)))
        }
    }

    private func unavailable(_ record: SenseRecord, selection: String, failure: SenseFailure) async {
        guard record.status == .on else { return }
        var reason = "Sense helper at \(helperURL.path): \(failure.code): \(failure.message)"
        var announce = true
        do {
            if let registry = SensesHub.shared.registry as? any SenseRegistryManaging {
                announce = try await registry.markUnavailable(id: record.id, selection: selection, reason: reason)
            }
        } catch { reason += "\n\(error.localizedDescription)" }
        await retire(selection: selection)
        if announce {
            await SenseNewsBoard.shared.post(SenseNews(senseID: record.id, version: record.version,
                address: record.corner.key, summary: "Sense unavailable: \(ContextSecretContentPolicy.redactedFragment(reason))", at: Date()))
        }
    }

    private static func attributed(_ outcome: SenseOutcome, to record: SenseRecord) -> SenseOutcome {
        let provenance = SenseProvenance(record: record)
        switch outcome {
        case .page(let page, _): return .page(page, provenance)
        case .acted(let result, _): return .acted(result, provenance)
        case .failed(var failure): failure.provenance = provenance; return .failed(failure)
        }
    }

    fileprivate static func failure(_ error: Error, provenance: SenseProvenance) -> SenseFailure {
        if error is CancellationError {
            return SenseFailure(code: "cancelled", message: "Sense request cancelled.", provenance: provenance)
        }
        var failure = SenseFailure(error)
        failure.provenance = provenance
        return failure
    }
}

private actor SenseHelperProcess {
    private struct Pending {
        let id: Int
        let events: AsyncThrowingStream<JSONValue, Error>.Continuation
        let result: CheckedContinuation<SenseOutcome, Never>
        let stallWindow: TimeInterval
        var worker: Task<Void, Never>?
    }
    private let record: SenseRecord
    private let dataRoot: URL
    private let script: String
    private let notebook: URL
    private let scratch: URL
    private let limits: HelperSenseRunner.Limits
    private let apps: (@Sendable (JSONValue, [String: String]) async throws -> JSONValue)?
    private let transport: OwnedProgramProcess
    private let onExit: @Sendable (SenseFailure?) async -> Void
    private let onSettled: @Sendable () async -> Void
    private let onSourceChange: @Sendable () -> Void
    private var nextID = 0
    private var pending: Pending?
    private var stopped = false
    private var watching = false
    private var lastAppObservation: JSONValue?
    private var newsGeneration = 0
    private var sourceAddress: String?
    private var sourceFile: String?
    private var sourceTab: String?
    private var observation: Task<Void, Never>?
    private var pendingChange: SenseMaterial?
    private var observedSource: (any SenseSourceProvider)?
    private var observationGeneration = UUID()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var reader: Task<Void, Never>?
    private var idleHolds = 0

    init(record: SenseRecord, dataRoot: URL, script: String, notebook: URL, scratch: URL, helper: URL,
         profile: String, limits: HelperSenseRunner.Limits, initialAddress: String?, apps: (@Sendable (JSONValue, [String: String]) async throws -> JSONValue)?,
         onSourceChange: @escaping @Sendable () -> Void,
         onSettled: @escaping @Sendable () async -> Void,
         onExit: @escaping @Sendable (SenseFailure?) async -> Void) throws {
        self.record = record; self.dataRoot = dataRoot; self.script = script; self.notebook = notebook; self.scratch = scratch
        self.limits = limits; self.onExit = onExit; self.onSettled = onSettled
        self.onSourceChange = onSourceChange
        self.sourceAddress = initialAddress
        self.apps = apps
        transport = try OwnedProgramProcess(helper: helper, profile: profile, scratch: scratch, memoryBytes: limits.memoryBytes)
    }

    private var isSite: Bool { if case .site = record.corner { true } else { false } }

    func startWatching(source: any SenseSourceProvider) async -> SenseOutcome {
        if watching { return .acted(.null, SenseProvenance(record: record)) }
        return await request(.watch, source: source, perform: nil)
    }

    func requestFollowing(_ request: SenseRequest, source: any SenseSourceProvider,
                          perform: SenseActionContext.Perform?) async -> (outcome: SenseOutcome, watchFailure: SenseFailure?, following: Bool) {
        // The hold covers settlement and actor hops between the read and watch.
        // It cannot suppress cancellation, stalls, crashes or explicit stops.
        idleHolds += 1
        let outcome = await self.request(request, source: source, perform: perform)
        var watchFailure: SenseFailure?
        if case .page = outcome {
            // Reads admit following; actions are never replayed by supervision.
            if case .failed(let failure) = await startWatching(source: source) { watchFailure = failure }
        }
        idleHolds -= 1
        Task { await onSettled() }
        return (outcome, watchFailure, watching && observation != nil)
    }

    func viewEvent(_ event: JSONValue, source: any SenseSourceProvider) async -> SenseOutcome {
        await request(.watch, source: source, perform: nil, event: event)
    }

    func request(_ request: SenseRequest, source: any SenseSourceProvider,
                 perform: SenseActionContext.Perform?, event: JSONValue? = nil,
                 changed: SenseMaterial? = nil) async -> SenseOutcome {
        if request == .watch, !SensesHub.passiveObservation {
            return await SensesHub.$passiveObservation.withValue(true) {
                await self.request(request, source: source, perform: perform, event: event, changed: changed)
            }
        }
        while !stopped, pending != nil, !Task.isCancelled {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { waiters[waiterID] = continuation }
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
        }
        guard !stopped, !Task.isCancelled else {
            return .failed(SenseFailure(code: stopped ? "crashed" : "busy", message: "Sense helper is unavailable or already answering."))
        }
        if reader == nil { startReader() }
        if isSite, case .read = request {
            // Every served read establishes the current source/tab. A prior
            // subscription must not keep a closed tab or a turn's source alive.
            resetSiteObservation()
        }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (stream, events) = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
                pending = Pending(id: id, events: events, result: continuation,
                    stallWindow: limits.requestSeconds)
                // Born in the requesting task, so its door calls retain that
                // turn's TaskLocal Trust, origin, tool and cancellation context.
                pending?.worker = Task {
                    do {
                        let address: String?
                        switch request {
                        case .read(let a): address = a
                        case .act(_, let a, _): address = a
                        case .watch: address = sourceAddress
                        }
                        var wire: JSONValue = .null
                        if event == nil {
                            let material: SenseMaterial
                            if let changed { material = changed }
                            else { material = try await source.material(for: record.corner, address: address) }
                            try Task.checkCancellation()
                            if !isSite || request == .watch {
                                sourceAddress = address
                            } else if case .read = request { sourceAddress = address }
                            if case .file(let path, _, _) = material {
                                sourceFile = path
                                if sourceAddress == nil { sourceAddress = path }
                            }
                            if case .pageSnapshot(.object(let fields)) = material,
                               case .int(let tab)? = fields["tabId"] { sourceTab = String(tab) }
                            wire = try await Self.materialWire(material, dataRoot: dataRoot, source: source)
                            if case .read = request, case .fileKind = record.corner, let address,
                               !address.hasPrefix("/"), !address.hasPrefix("~"),
                               let query = address.split(separator: "?", maxSplits: 1).dropFirst().first,
                               let items = URLComponents(string: "?" + String(query))?.queryItems,
                               case .object(let fields) = wire,
                               items.first(where: { $0.name == "version" })?.value.map(JSONValue.string) != fields["version"] {
                                throw SenseFailure(code: "file_changed", message: "The file changed; read from the start.")
                            }
                        }
                        try Task.checkCancellation()
                        if changed != nil {
                            try send(.object(["id": .int(Int64(id)), "type": .string("changed"),
                                "timeoutSeconds": .double(pending?.stallWindow ?? limits.requestSeconds), "material": wire]))
                        } else {
                            var run: [String: JSONValue] = ["id": .int(Int64(id)), "type": .string("run"),
                                "sense": try JSONValue.fromEncodable(record),
                                "request": event.map { .object(["type": .string("event"), "event": $0]) } ?? Self.requestWire(request),
                                "timeoutSeconds": .double(pending?.stallWindow ?? limits.requestSeconds), "material": wire]
                            run["program"] = try .fromEncodable(OwnedProgram(kind: .sense, id: record.id,
                                version: String(record.version), source: script, entry: .sense,
                                reach: record.reach, seconds: limits.requestSeconds))
                            try send(.object(run))
                        }
                        transport.begin(id: id, kind: .sense, seconds: pending?.stallWindow ?? limits.requestSeconds)
                        var progress = SenseEntryProgress()
                        // JS caches material at the request address (nil for watch/change/event).
                        let entryAddress = changed != nil || event != nil || request == .watch ? nil : address
                        var page: NativePage?
                        var acted: JSONValue?
                        var actFailure: SenseFailure?
                        var lastCallID: Int64 = 0
                        var logBytes = 0
                        var view: SenseInteractiveView?
                        var presented = false
                        for try await message in stream {
                            try Task.checkCancellation()
                            guard case .object(let fields) = message, case .string(let type)? = fields["type"] else {
                                throw SenseFailure(code: "bad_output", message: "Sense helper sent an invalid message.")
                            }
                            if type != "done", type != "failed", type != "progress" {
                                guard case .int(let callID)? = fields["callID"], callID > lastCallID else {
                                    throw SenseFailure(code: "bad_output", message: "Sense API requires increasing callIDs.")
                                }
                                lastCallID = callID
                            }
                            switch type {
                            case "progress":
                                let accepted: Bool
                                if let readAddress = fields["readAddress"] {
                                    // Only the supplied snapshot may be read locally without a source round trip.
                                    let expected = entryAddress.map(JSONValue.string) ?? .null
                                    guard wire != .null,
                                          readAddress == expected, fields["n"] == nil else {
                                        throw SenseFailure(code: "bad_output", message: "Sense progress must identify its supplied source read.")
                                    }
                                    accepted = progress.read(address: entryAddress)
                                } else {
                                    let value: Double
                                    switch fields["n"] {
                                    case .int(let n): value = Double(n)
                                    case .double(let n): value = n
                                    default: throw SenseFailure(code: "bad_output", message: "Sense progress requires a finite number.")
                                    }
                                    accepted = try progress.advance(to: value) != nil
                                }
                                if accepted { try renewProgress(id) }
                            case "publish":
                                page = try decodePage(fields["page"], material: wire)
                                try renewProgress(id)
                            case "present":
                                presented = true
                                view = try decodeView(fields["view"])
                            case "notify":
                                let news = try decodeNews(fields["news"])
                                try renewProgress(id)
                                await postNews(news)
                            case "source_read", "source_watch", "state_get", "state_set", "app_read":
                                let waitStarted = try suspendStall(id)
                                do {
                                    try await service(fields, source: source)
                                    if type == "source_read" {
                                        let readAddress = if case .string(let a)? = fields["address"] { a } else { entryAddress }
                                        if progress.read(address: readAddress) {
                                            try renewProgress(id)
                                        }
                                    }
                                }
                                catch {
                                    let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                                    let replyType = type == "app_read" ? "app_reply" : type.hasPrefix("state_") ? "state_reply" : "source_reply"
                                    try send(.object(["type": .string(replyType), "id": fields["id"] ?? .null,
                                        "callID": fields["callID"] ?? .null, "failure": try JSONValue.fromEncodable(failure)]))
                                }
                                try resumeStall(id, since: waitStarted)
                            case "log":
                                guard case .string(let text)? = fields["text"], logBytes + text.utf8.count <= 2_048 else {
                                    throw SenseFailure(code: "bad_output", message: "Sense logs exceed 2 KiB or are malformed.")
                                }
                                logBytes += text.utf8.count
                            case "act":
                                guard event == nil, case .act = request, record.verbsEnabled, let perform,
                                      case .string(let verb)? = fields["verb"], case .string(let address)? = fields["address"] else {
                                    throw SenseFailure(code: "act_denied", message: "Sense actions require an active act request and the app door.")
                                }
                                let waitStarted = try suspendStall(id)
                                do {
                                    acted = try await perform(verb, address, fields["args"] ?? .object([:]))
                                    try Task.checkCancellation()
                                    try reply(fields, type: "act_reply", value: acted ?? .null, field: "result")
                                } catch {
                                    let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                                    actFailure = failure
                                    try send(.object(["type": .string("act_reply"), "id": fields["id"] ?? .null,
                                        "callID": fields["callID"] ?? .null, "failure": try JSONValue.fromEncodable(failure)]))
                                }
                                try resumeStall(id, since: waitStarted)
                            case "done":
                                try transport.claimCompletion(id)
                                if case .read = request, page == nil {
                                    throw SenseFailure(code: "bad_output", message: "Sense read finished without a page.")
                                }
                                if presented, record.status == .on, let registry = SensesHub.shared.registry,
                                   let current = try await registry.sense(for: record.corner), current.status == .on,
                                   current.id == record.id, current.version == record.version {
                                    await SenseNewsBoard.shared.present(view)
                                }
                                if case .read = request {
                                    guard let page else { throw SenseFailure(code: "bad_output", message: "Sense read finished without a page.") }
                                    finish(id, .page(page, SenseProvenance(record: record)))
                                } else {
                                    if event == nil, changed == nil, case .act = request {
                                        if let actFailure { throw actFailure }
                                        guard let acted else {
                                            throw SenseFailure(code: "no_action", message: "The sense performed no door action; no success receipt exists.")
                                        }
                                        finish(id, .acted(acted, SenseProvenance(record: record)))
                                        return
                                    }
                                    if request == .watch, event == nil, changed == nil {
                                        watching = !isSite || observation != nil
                                    }
                                    finish(id, .acted(.null, SenseProvenance(record: record)))
                                }
                                return
                            default: throw SenseFailure(code: "bad_output", message: "Unknown sense helper message: \(type)")
                            }
                        }
                    } catch {
                        let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                        finish(id, .failed(failure))
                        await terminate(failure: error is CancellationError || ["file_changed", "no_action", "act_denied"].contains(failure.code) ? nil : failure)
                    }
                }
                if Task.isCancelled {
                    finish(id, .failed(SenseFailure(code: "cancelled", message: "Sense request cancelled.")))
                    Task { await terminate(failure: nil) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func renewProgress(_ id: Int) throws { try transport.renewProgress(id) }

    private func suspendStall(_ id: Int) throws -> ContinuousClock.Instant {
        try transport.suspend(id)
    }

    private func resumeStall(_ id: Int, since started: ContinuousClock.Instant) throws {
        try transport.resume(id, since: started)
    }

    private func cancel(_ id: Int) async {
        guard pending?.id == id else { return }
        finish(id, .failed(SenseFailure(code: "cancelled", message: "Sense request cancelled.")))
        await terminate(failure: nil)
    }

    private func cancelWaiter(_ id: UUID) {
        // Removal is the single continuation claim shared with finish/stop.
        waiters.removeValue(forKey: id)?.resume()
    }

    private func finish(_ id: Int, _ outcome: SenseOutcome) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        var outcome = outcome
        let receipt: JSONValue
        switch outcome {
        case .failed(let failure): receipt = .object(["status": .string("failed"), "reason": .string(failure.code), "detail": .string(failure.message)])
        case .acted(let result, _): receipt = result == .null ? .object(["status": .string("ok")]) : result
        case .page: receipt = .object(["status": .string("ok"), "read": .bool(true)])
        }
        do { try AbilityStore(dataRoot: dataRoot).recordRun(id: record.id, version: record.candidateDigest ?? String(record.version), receipt: receipt) }
        catch {
            // recordRun owes the ledger's repair itself; the outcome keeps its own truth.
            switch outcome {
            case .acted(let result, let provenance):
                var fields: [String: JSONValue] = if case .object(let fields) = receipt { fields } else { ["result": result] }
                fields["accounting_error"] = .string(error.localizedDescription)
                outcome = .acted(.object(fields), provenance)
            case .failed(var failure):
                failure.message += " Accounting failed: " + error.localizedDescription
                outcome = .failed(failure)
            case .page: break
            }
        }
        current.events.finish(); transport.end(id); current.worker?.cancel()
        current.result.resume(returning: outcome)
        let waiting = waiters; waiters.removeAll()
        for waiter in waiting.values { waiter.resume() }
        Task { await onSettled() }
        if !stopped, watching, pendingChange != nil {
            onSourceChange()
        }
    }

    func stop() async { await terminate(failure: nil) }

    func stopIfIdle() async -> Bool {
        // An event subscription is live work, even between source edges.
        guard pending == nil, idleHolds == 0, observation == nil else { return false }
        await terminate(failure: nil)
        return true
    }

    private func terminate(failure: SenseFailure?) async {
        guard !stopped else { return }
        stopped = true
        if let pending { finish(pending.id, .failed(SenseFailure(code: "crashed", message: "Sense helper stopped before answering."))) }
        reader?.cancel(); observation?.cancel()
        let waiting = waiters; waiters.removeAll()
        for waiter in waiting.values { waiter.resume() }
        transport.stop()
        // Transport reaps the process before removing its scratch directory.
        await Task.detached(priority: .utility) { [onExit] in await onExit(failure) }.value
    }

    private func startReader() {
        reader = Task {
            var replied = false
            for await event in transport.events {
                guard !stopped else { return }
                switch event {
                case .line(let data):
                    do {
                        let message = try JSONValue.parse(data)
                        guard case .object(let fields) = message else { throw SenseFailure(code: "bad_output", message: "Sense helper sent a non-object message.") }
                        replied = true
                        if let current = pending, fields["id"] == .int(Int64(current.id)) {
                            if fields["type"] == .string("failed") {
                                throw try JSONDecoder().decode(SenseFailure.self, from: JSONEncoder().encode(fields["failure"] ?? .null))
                            }
                            if case .dropped = current.events.yield(message) {
                                throw SenseFailure(code: "output_limit", message: "Sense helper exceeded its pending message limit.")
                            }
                        } else {
                            throw SenseFailure(code: "bad_output", message: "Sense helper sent a message outside its request.")
                        }
                    } catch {
                        let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                        await readerFailed(failure); return
                    }
                case .ended(let detail):
                    let failure = SenseFailure(code: replied ? "crashed" : "spawn_failed", message: detail)
                    await readerFailed(failure); return
                }
            }
            if !stopped {
                let failure = SenseFailure(code: "resource_limit", message: "Sense helper output ended before its process settled.")
                await readerFailed(failure)
            }
        }
    }

    private func readerFailed(_ failure: SenseFailure) async {
        // Its requesting worker owns error attribution and settlement.
        if let pending { pending.events.finish(throwing: failure) }
        else { await terminate(failure: failure) }
    }

    private func service(_ fields: [String: JSONValue], source: any SenseSourceProvider) async throws {
        switch fields["type"] {
        case .string("app_read"):
            guard let apps else { throw SenseFailure(code: "unavailable", message: "App reading is not connected.") }
            let targets = Dictionary((record.reach.apps ?? []).map { ($0, "read") }, uniquingKeysWith: { first, _ in first })
            let value = try await apps(fields["args"] ?? .null, targets)
            try reply(fields, type: "app_reply", value: value, field: "result")
        case .string("source_read"):
            let corner = record.corner
            guard fields["corner"] == .string(corner.key) else { throw SenseFailure(code: "source_denied", message: "Sense source must stay in its declared corner.") }
            switch fields["address"] {
            case nil, .null, .string: break
            default: throw SenseFailure(code: "bad_output", message: "Sense source address must be a string or null.")
            }
            let address: String? = if case .string(let value)? = fields["address"] { value } else { sourceAddress }
            if case .fileKind = record.corner, let address,
               address != sourceAddress, address != sourceFile,
               address != sourceFile.map({ URL(fileURLWithPath: $0).absoluteString }) {
                let path = URL(string: address).flatMap { $0.isFileURL ? $0.path : nil } ?? address
                let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                guard path.hasPrefix("/"), record.reach.readPaths.contains(where: {
                    let root = URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
                    return candidate == root || candidate.hasPrefix(root + "/")
                }) else {
                    throw SenseFailure(code: "source_denied", message: "Sense source must stay at its requested file or declared read reach.")
                }
            }
            let material = try await source.material(for: corner, address: address)
            let wire = try await Self.materialWire(material, dataRoot: dataRoot, source: source)
            try Task.checkCancellation()
            try reply(fields, type: "source_reply", value: wire, field: "material")
        case .string("state_get"), .string("state_set"):
            guard case .string(let key)? = fields["key"], SenseWire.validStateKey(key) else {
                throw SenseFailure(code: "bad_state", message: "Sense notebook key is invalid.")
            }
            let setting = fields["type"] == .string("state_set")
            let value = try AbilityStore.notebook(notebook, key: key, setting: setting, value: fields["value"] ?? .null,
                failure: { SenseFailure(code: $0, message: $1) })
            try reply(fields, type: "state_reply", value: value)
        case .string("source_watch"):
            guard record.mode == .live, fields["corner"] == .string(record.corner.key) else {
                throw SenseFailure(code: "source_denied", message: "Only a live sense may subscribe to its declared corner.")
            }
            if observation == nil {
                guard let provider = source as? any SenseSourceWatchingProvider else {
                    throw SenseFailure(code: "unsupported", message: "Sense source does not provide live change events.")
                }
                let changes = try await provider.changes(for: record.corner, address: sourceAddress)
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                let appObservation: JSONValue?
                if case .app = record.corner {
                    appObservation = try await SensesHub.$passiveObservation.withValue(true) {
                        Self.appObservation(try await source.material(for: record.corner, address: sourceAddress))
                    }
                } else { appObservation = nil }
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                if case .app = record.corner { lastAppObservation = appObservation }
                observedSource = source
                if isSite {
                    let generation = UUID()
                    observationGeneration = generation
                    // Following outlives this read. It consumes explicit source
                    // proof and inherits no turn's TaskLocal Trust/action state.
                    observation = Task.detached(priority: .utility) { [weak self] in
                        for await material in changes {
                            guard !Task.isCancelled else { break }
                            await self?.receiveSiteChange(material, generation: generation)
                        }
                        await self?.siteObservationEnded(generation)
                    }
                } else {
                    observation = Task {
                        for await material in changes {
                            guard !Task.isCancelled, !stopped else { return }
                            if case .app = record.corner, let content = Self.appObservation(material) {
                                guard content != lastAppObservation else { continue }
                                lastAppObservation = content
                            }
                            pendingChange = material
                            if pending == nil, watching { onSourceChange() }
                        }
                        guard !Task.isCancelled, !stopped else { return }
                        if case .app = record.corner {
                            await postNews(SenseNews(senseID: record.id, version: record.version,
                                address: sourceAddress ?? record.corner.key,
                                summary: "Stopped following this corner because its source events ended.", at: Date()))
                            await terminate(failure: nil)
                        } else {
                            await postNews(SenseNews(senseID: record.id, version: record.version,
                                address: sourceAddress ?? record.corner.key,
                                summary: "Stopped following this file because its source events ended.", at: Date()))
                            await terminate(failure: nil)
                        }
                    }
                }
            }
            try reply(fields, type: "source_reply", value: .bool(true), field: "subscribed")
        default: break
        }
    }

    private func resetSiteObservation() {
        observationGeneration = UUID()
        observation?.cancel(); observation = nil
        observedSource = nil; pendingChange = nil; watching = false
    }

    private func receiveSiteChange(_ material: SenseMaterial, generation: UUID) async {
        guard !stopped, generation == observationGeneration else { return }
        pendingChange = material
        if pending == nil, watching { onSourceChange() }
    }

    private func siteObservationEnded(_ generation: UUID) async {
        guard generation == observationGeneration, !stopped, !Task.isCancelled else { return }
        observation = nil; observedSource = nil; pendingChange = nil; watching = false
        await postNews(SenseNews(senseID: record.id, version: record.version,
            address: sourceAddress ?? record.corner.key,
            summary: "Stopped following this site because its Chrome source events ended.", at: Date()))
        guard generation == observationGeneration, !stopped, !Task.isCancelled else { return }
        await terminate(failure: nil)
    }

    private static func appObservation(_ material: SenseMaterial) -> JSONValue? {
        guard case .accessibility(.object(var fields)) = material else { return nil }
        // A new selection frame is bookkeeping, not news from the world.
        fields.removeValue(forKey: "frame_id")
        return .object(fields)
    }

    fileprivate func drainChange() async {
        guard !stopped, watching, pending == nil, pendingChange != nil, let source = observedSource else { return }
        let generation = observationGeneration
        do {
            if let registry = SensesHub.shared.registry {
                guard let current = try await registry.sense(for: record.corner), current.id == record.id,
                      current.version == record.version, current.status == .on else {
                    await stop(); return
                }
            }
            guard !stopped, !Task.isCancelled, pending == nil,
                  watching && observationGeneration == generation, let material = pendingChange else { return }
            pendingChange = nil
            let previousNews = newsGeneration
            let outcome = await SenseActionContext.$perform.withValue(nil) {
                await request(.watch, source: source, perform: nil, changed: material)
            }
            guard !stopped, !Task.isCancelled, observationGeneration == generation else { return }
            if case .failed(let failure) = outcome {
                await postNews(SenseNews(senseID: record.id, version: record.version,
                    address: sourceAddress ?? record.corner.key,
                    summary: "Live change could not be read: \(ContextSecretContentPolicy.redactedFragment(failure.code)): \(ContextSecretContentPolicy.redactedFragment(failure.message))", at: Date()))
            } else if case .app = record.corner, newsGeneration == previousNews {
                await postNews(SenseNews(senseID: record.id, version: record.version,
                    address: sourceAddress ?? record.corner.key, summary: "App view changed.", at: Date()))
            }
        } catch {
            guard !stopped, !Task.isCancelled, observationGeneration == generation else { return }
            await terminate(failure: HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record)))
        }
    }

    private func decodePage(_ value: JSONValue?, material: JSONValue) throws -> NativePage {
        guard case .object(let fields)? = value else { throw SenseFailure(code: "bad_output", message: "Sense page is missing.") }
        var page = try SenseWire.decodePage(fields, corner: record.corner)
        if record.status == .on && !record.verbsEnabled { for i in page.things.indices { page.things[i].verbs = [] } }
        if let more = page.more, case .fileKind = record.corner, case .object(let material) = material,
           case .string(let version)? = material["version"] {
            let parts = more.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            guard var query = URLComponents(string: "?" + (parts.count == 2 ? String(parts[1]) : "")) else {
                throw SenseFailure(code: "bad_output", message: "Sense file continuation has an invalid query.")
            }
            query.queryItems = (query.queryItems ?? []).filter { $0.name != "version" } + [URLQueryItem(name: "version", value: version)]
            page.more = String(parts[0]) + "?" + (query.percentEncodedQuery ?? "")
        }
        try SenseWire.validatePage(page)
        return page
    }

    private func decodeNews(_ value: JSONValue?) throws -> SenseNews {
        guard case .object(let fields)? = value,
              fields["senseID"] == .string(record.id), fields["version"] == .int(Int64(record.version)) else {
            throw SenseFailure(code: "bad_output", message: "Sense news requires an address and summary.")
        }
        return try SenseWire.news(value, senseID: record.id, version: record.version)
    }

    private func postNews(_ news: SenseNews) async {
        do {
            guard record.status == .on, let registry = SensesHub.shared.registry,
                  let current = try await registry.sense(for: record.corner), current.status == .on,
                  current.id == record.id, current.version == record.version else { return }
            var news = news
            news.observationID = isSite ? sourceTab : sourceFile
            await SenseNewsBoard.shared.post(news)
            newsGeneration &+= 1
        } catch { await terminate(failure: HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))) }
    }

    private func decodeView(_ value: JSONValue?) throws -> SenseInteractiveView? {
        try SenseWire.view(value, senseID: record.id, version: record.version)
    }

    private func send(_ message: JSONValue) throws {
        guard !stopped else { throw SenseFailure(code: "crashed", message: "Sense helper has stopped.") }
        try transport.send(message)
    }

    private func reply(_ fields: [String: JSONValue], type: String, value: JSONValue, field: String = "value") throws {
        var response: [String: JSONValue] = ["type": .string(type), "id": fields["id"] ?? .null, field: value]
        if let callID = fields["callID"] { response["callID"] = callID }
        try send(.object(response))
    }

    private static func requestWire(_ request: SenseRequest) -> JSONValue {
        switch request {
        case .read(let address): .object(["type": .string("read"), "address": address.map(JSONValue.string) ?? .null])
        case .act(let verb, let address, let args): .object(["type": .string("act"), "verb": .string(verb), "address": .string(address), "args": args])
        case .watch: .object(["type": .string("watch")])
        }
    }

    private nonisolated static func materialWire(_ material: SenseMaterial, dataRoot: URL, source: any SenseSourceProvider) async throws -> JSONValue {
        // Local source capture has no execution cap and never holds this actor.
        let value = try await Task.detached(priority: .utility) { try materialValue(material, dataRoot: dataRoot) }.value
        if case .object(var fields) = value,
           case .string(let path)? = fields["path"], case .int(let bytes)? = fields.removeValue(forKey: "source_bytes"),
           case .string(let version)? = fields["version"],
           case .string(let encoded)? = fields["data"], let data = Data(base64Encoded: encoded) {
            await (source as? any SenseFileReadReporting)?.didReadFile(path: path, bytes: Int(bytes), version: version, data: data)
            return .object(fields)
        }
        return value
    }

    private nonisolated static func materialValue(_ material: SenseMaterial, dataRoot: URL) throws -> JSONValue {
        switch material {
        case .accessibility(let tree): return .object(["kind": .string("accessibility"), "tree": tree])
        case .file(let path, let bytes, let captured):
            try SenseSandboxProfile.requirePublicPath(path, dataRoot: dataRoot,
                personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let data: Data
            let sourceBytes: Int
            if let captured {
                data = captured; sourceBytes = bytes
            } else {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if attrs[.type] as? FileAttributeType == .typeDirectory,
                   SenseMaterial.packageExtensions.contains(url.pathExtension.lowercased()) {
                    let package = try packageArchive(url, dataRoot: dataRoot)
                    data = package.data; sourceBytes = package.bytes
                } else {
                    guard attrs[.type] as? FileAttributeType == .typeRegular else {
                        throw SenseFailure(code: "source_unavailable", message: "Sense file material must be a regular file or document package.")
                    }
                    data = try boundedFile(url, dataRoot: dataRoot)
                    sourceBytes = data.count
                }
            }
            let version = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return .object(["kind": .string("file"), "path": .string(url.path), "bytes": .int(Int64(data.count)),
                "source_bytes": .int(Int64(sourceBytes)), "version": .string(version),
                "data": .string(data.base64EncodedString())])
        case .pageSnapshot(let snapshot): return .object(["kind": .string("page"), "snapshot": snapshot])
        case .text(let text): return .object(["kind": .string("text"), "text": .string(text)])
        }
    }

    private nonisolated static func boundedFile(_ url: URL, dataRoot: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SenseFailure(code: "source_unavailable", message: "Sense file material is unavailable.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attrs = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(fd, &attrs) == 0, (attrs.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fcntl(fd, F_GETPATH, &path) == 0 else {
            throw SenseFailure(code: "source_denied", message: "Sense file material must remain a regular file.")
        }
        let openedPath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        try SenseSandboxProfile.requirePublicPath(openedPath, dataRoot: dataRoot,
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        let data = try handle.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 16 * 1_024 * 1_024 else {
            throw SenseFailure(code: "input_limit", message: "Sense file material exceeds 16 MiB.")
        }
        var after = stat()
        guard fstat(fd, &after) == 0, attrs.st_size == after.st_size,
              attrs.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, attrs.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              attrs.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, attrs.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw SenseFailure(code: "file_changed", message: "Sense file material changed during the read.")
        }
        return data
    }

    /// Stored ZIP keeps package member identities intact without granting the
    /// helper filesystem access or staging a copy of User's material in scratch.
    private nonisolated static func packageArchive(_ root: URL, dataRoot: URL) throws -> (data: Data, bytes: Int) {
        let files = try ExistingCornersSourceProvider.packageManifest(root).filter(\.isFile).map(\.url)
        func word<T: FixedWidthInteger>(_ number: T, into data: inout Data) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        var archive = Data(), directory = Data(), totalBytes = 0
        for url in files.sorted(by: { $0.path < $1.path }) {
            let name = Data(url.path.dropFirst(root.path.count + 1).utf8)
            guard name.count <= Int(UInt16.max), !name.isEmpty,
                  url.resolvingSymlinksInPath().path == url.path else {
                throw SenseFailure(code: "source_denied", message: "Sense document package member changed while reading.")
            }
            let bytes = try boundedFile(url, dataRoot: dataRoot)
            totalBytes += bytes.count
            var crc: UInt32 = 0xffff_ffff
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
            }
            crc ^= 0xffff_ffff
            let offset = UInt32(archive.count), count = UInt32(bytes.count)
            word(UInt32(0x04034b50), into: &archive)
            for value in [UInt16(20), 0x0800, 0, 0, 0] { word(value, into: &archive) }
            word(crc, into: &archive); word(count, into: &archive); word(count, into: &archive)
            word(UInt16(name.count), into: &archive); word(UInt16(0), into: &archive)
            archive.append(name); archive.append(bytes)
            word(UInt32(0x02014b50), into: &directory)
            for value in [UInt16(20), 20, 0x0800, 0, 0, 0] { word(value, into: &directory) }
            word(crc, into: &directory); word(count, into: &directory); word(count, into: &directory)
            word(UInt16(name.count), into: &directory)
            for _ in 0..<4 { word(UInt16(0), into: &directory) }
            word(UInt32(0), into: &directory); word(offset, into: &directory); directory.append(name)
            guard archive.count + directory.count + 22 <= 16 * 1_024 * 1_024 else {
                throw SenseFailure(code: "input_limit", message: "Sense document package exceeds 16 MiB of ZIP material.")
            }
        }
        let offset = UInt32(archive.count)
        archive.append(directory)
        word(UInt32(0x06054b50), into: &archive)
        word(UInt16(0), into: &archive); word(UInt16(0), into: &archive)
        word(UInt16(files.count), into: &archive); word(UInt16(files.count), into: &archive)
        word(UInt32(directory.count), into: &archive); word(offset, into: &archive); word(UInt16(0), into: &archive)
        return (archive, totalBytes)
    }
}
