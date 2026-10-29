import AuthoredCapabilities
import Foundation
import CryptoKit
import Darwin
import PersistenceCore
import NativeAgentCore
// Blueprint: | `HelperSenseRunner.swift` | Isolated plug supervision with validated progress-based stall detection excluding app-served reply waits, read-to-watch idle holds, subscription-owned lifetime and restarts; source callbacks keep newest material and signal EnginePartWake for unattended interpretation, fenced by helper generation; canonical sense disable/replacement retires only that selected lifetime's passive helpers (including unattended on-call wakes) and pending admissions; late retirement and failure reporting cannot affect a replacement, and availability reports rejected by the registry post no news, while sense-identified accepted human on-call work settles with its requesting owner; notebook access delegates to AbilityStore; versioned use and visible live failure news, sealed view events, detached site following and app change deduplication/news; app reads use assembly's Trust-admitted read closure. Live-watch reporting reads actual helper subscriptions, with presentation invalidation at their lifecycle edges. Cancellation joins the worker through settle before terminal accounting and preserves returned action receipts. |

/// One sandboxed helper per live sense/source; on-call helpers are discarded after their answer. Only a caller's act request can reach the installed door.
public actor HelperSenseRunner: SenseWatchReporting {
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

    public func liveWatches() async -> [SenseLiveWatch] {
        var watches: [SenseLiveWatch] = []
        for (key, slot) in live {
            guard let process = slot.process, await process.isFollowing(),
                  live[key]?.generation == slot.generation else { continue }
            watches.append(SenseLiveWatch(address: slot.address ?? slot.record.corner.surfaceName,
                senseID: slot.record.id, version: slot.record.version, corner: slot.record.corner))
        }
        return watches
    }

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
        let isEvent = if case .event = request { true } else { false }
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
        if record.language == .native, !isEvent {
            guard let sense = ExistingCornerSense(record: record) else {
                return .failed(SenseFailure(code: "unsupported", message: "Native sense identity is unsupported.", provenance: provenance))
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
            let process: SenseHelperProcess
            let callID = UUID()
            admissions[callID] = selection
            defer { admissions.removeValue(forKey: callID) }
            if case .event(let event) = request {
                guard record.language != .native, record.status == .on, SensesHub.shared.registry != nil,
                      try JSONEncoder().encode(event).count <= 16_384 else {
                    throw SenseFailure(code: "view_unavailable", message: "Sense view is no longer enabled or its event is too large.")
                }
            }
            try requireHelper()
            let address: String? = switch request {
            case .read(let address): address
            case .act(_, let address, _): address
            case .watch: nil
            case .event: viewAddresses[record.id].flatMap { $0.selection == selection ? $0.address : nil }
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
            if record.mode == .live, request != .watch, !isEvent {
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
                outcome = await SenseActionContext.$perform.withValue(isEvent ? nil : SenseActionContext.perform) {
                    await process.request(request, source: source, perform: SenseActionContext.perform)
                }
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
            // A settled action receipt remains evidence after Stop. Its own status says whether the sense completed or was interrupted.
            if case .acted = outcome { return Self.attributed(outcome, to: record) }
            return .failed(SenseFailure(code: "cancelled", message: "Sense request cancelled.", provenance: SenseProvenance(record: record)))
        }
        guard !shutDown else {
            if case .acted = outcome { return Self.attributed(outcome, to: record) }
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

    func retire(selection: String) async {
        defer { NotificationCenter.default.post(name: SenseNewsBoard.presentationDidChange, object: nil) }
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
        defer { NotificationCenter.default.post(name: SenseNewsBoard.presentationDidChange, object: nil) }
        guard let slot = live.removeValue(forKey: key) else { return }
        slot.idle?.cancel()
        await slot.process?.stop()
    }

    public func shutdown() async {
        defer { NotificationCenter.default.post(name: SenseNewsBoard.presentationDidChange, object: nil) }
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

    /// Only EnginePartWake admits unattended interpretation. Material stays in the source-bound helper; a retired generation can never consume it.
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
        // Idle retention is not an entry limit. Settlement will revisit this deadline if an entry is still running when it crosses.
        if let process = slot.process, !(await process.stopIfIdle()) { return }
        guard live[id]?.idleAt == deadline, live[id]?.generation == slot.generation else { return }
        await stopSlot(id)
    }

    private func settled(_ id: String, generation: UUID) async {
        guard let slot = live[id], slot.generation == generation, slot.idleAt <= Date() else { return }
        await expireIdle(id, deadline: slot.idleAt)
    }

    private func crashed(_ id: String, generation: UUID, failure: SenseFailure?) async {
        defer { NotificationCenter.default.post(name: SenseNewsBoard.presentationDidChange, object: nil) }
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
            if let registry = SensesHub.shared.registry {
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

    static func failure(_ error: Error, provenance: SenseProvenance) -> SenseFailure {
        if error is CancellationError {
            return SenseFailure(code: "cancelled", message: "Sense request cancelled.", provenance: provenance)
        }
        var failure = SenseFailure(error)
        failure.provenance = provenance
        return failure
    }
}
