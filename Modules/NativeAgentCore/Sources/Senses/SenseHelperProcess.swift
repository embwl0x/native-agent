import AuthoredCapabilities
import Foundation
import CryptoKit
import Darwin
import PersistenceCore
import NativeAgentCore
// Blueprint: | `SenseHelperProcess.swift` | Request and watch supervision; pending calls join settlement and receipts retain returned effects |

actor SenseHelperProcess {
    private struct Pending {
        let id: Int
        let events: AsyncThrowingStream<JSONValue, Error>.Continuation
        let stallWindow: TimeInterval
        var worker: Task<SenseOutcome, Never>?
        var settlement: Task<SenseOutcome, Never>?
        var interruption: SenseFailure?
        var returnedActions: [JSONValue] = []
    }
    private let record: SenseRecord
    private let dataRoot: URL
    private let script: String
    private let notebook: URL
    private let scratch: URL
    private let limits: HelperSenseRunner.Limits
    private let apps: (@Sendable (JSONValue, [String: String], SenseReadOperation) async throws -> JSONValue)?
    private let transport: OwnedProgramProcess
    private let onExit: @Sendable (SenseFailure?) async -> Void
    private let onSettled: @Sendable () async -> Void
    private let onSourceChange: @Sendable () -> Void
    private var nextID = 0
    private var pending: Pending?
    private var stopped = false
    private var watching = false {
        didSet {
            if watching != oldValue { NotificationCenter.default.post(name: SenseNewsBoard.presentationDidChange, object: nil) }
        }
    }
    private var lastAppObservation: JSONValue?
    private var sourceUnavailable = false
    private var newsGeneration = 0
    private var sourceAddress: String?
    private var sourceFile: String?
    private var sourceTab: String?
    private var observation: Task<Void, Never>?
    private var pendingChange: SenseMaterial?
    private var observedSource: (any SenseSourceProvider)?
    private var observationGeneration = UUID()
    private var pendingDone = ScopedWaiter()
    private var reader: Task<Void, Never>?
    private var termination: Task<Void, Never>?
    private var idleHolds = 0

    init(record: SenseRecord, dataRoot: URL, script: String, notebook: URL, scratch: URL, helper: URL,
         profile: String, limits: HelperSenseRunner.Limits, initialAddress: String?, apps: (@Sendable (JSONValue, [String: String],
             SenseReadOperation) async throws -> JSONValue)?,
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
        return await request(.watch, source: source, operation: .init(turn: nil, passive: true))
    }

    func requestFollowing(_ request: SenseRequest, source: any SenseSourceProvider,
                          operation: SenseReadOperation) async -> (outcome: SenseOutcome, watchFailure: SenseFailure?, following: Bool) {
        // Hold across read/watch settlement and actor hops without suppressing cancellation, stalls, crashes or explicit stops.
        idleHolds += 1
        let outcome = await self.request(request, source: source, operation: operation)
        var watchFailure: SenseFailure?
        if case .page = outcome {
            // Only reads admit following; supervision must never replay actions.
            if case .failed(let failure) = await startWatching(source: source) { watchFailure = failure }
        }
        idleHolds -= 1
        Task { await onSettled() }
        return (outcome, watchFailure, watching && observation != nil)
    }

    func request(_ request: SenseRequest, source: any SenseSourceProvider,
                 operation: SenseReadOperation,
                 changed: SenseMaterial? = nil) async -> SenseOutcome {
        let isEvent = if case .event = request { true } else { false }
        let operation = request == .watch || isEvent ? operation.observing() : operation
        let perform = operation.perform
        while !stopped, pending != nil, !Task.isCancelled {
            let done = pendingDone
            await done.park(budget: .init(deadline: operation.deadline))
            if operation.deadline.map({ ContinuousClock.now >= $0 }) == true {
                return .failed(SenseFailure(code: "timeout", message: "This sense call's wait ended before the previous call settled; it did not run."))
            }
        }
        if operation.deadline.map({ ContinuousClock.now >= $0 }) == true {
            return .failed(SenseFailure(code: "timeout", message: "This sense call's deadline ended before it could run."))
        }
        guard !stopped, !Task.isCancelled else {
            return .failed(SenseFailure(code: stopped ? "crashed" : "busy", message: "Sense helper is unavailable or already answering."))
        }
        if reader == nil { startReader() }
        if isSite, case .read = request {
            // Bind every served read to its current source/tab so prior subscriptions cannot retain closed tabs or turn sources.
            resetSiteObservation()
        }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            do {
                let (stream, events) = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
                pending = Pending(id: id, events: events, stallWindow: limits.requestSeconds)
                // The worker holds this operation's turn, action dependency and read captures through settlement.
                let worker = Task<SenseOutcome, Never> {
                    do {
                        let address: String?
                        switch request {
                        case .read(let a): address = a
                        case .act(_, let a, _): address = a
                        case .watch, .event: address = sourceAddress
                        }
                        var wire: JSONValue = .null
                        if !isEvent {
                            let material: SenseMaterial
                            if let changed { material = changed }
                            else { material = try await source.material(for: record.corner, address: address, operation: operation) }
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
                                "request": Self.requestWire(request),
                                "timeoutSeconds": .double(pending?.stallWindow ?? limits.requestSeconds), "material": wire]
                            run["program"] = try .fromEncodable(OwnedProgram(kind: .sense, id: record.id,
                                version: String(record.version), source: script, entry: .sense,
                                reach: record.reach, seconds: limits.requestSeconds))
                            try send(.object(run))
                        }
                        transport.begin(id: id, kind: .sense, seconds: pending?.stallWindow ?? limits.requestSeconds)
                        var progress = SenseEntryProgress()
                        let entryAddress = changed != nil || isEvent || request == .watch ? nil : address
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
                                    // Only supplied snapshots permit local reads without a source round trip.
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
                                if accepted { try transport.renewProgress(id) }
                            case "publish":
                                page = try decodePage(fields["page"], material: wire)
                                try transport.renewProgress(id)
                            case "present":
                                presented = true
                                view = try SenseWire.view(fields["view"], senseID: record.id, version: record.version)
                            case "notify":
                                let news = try decodeNews(fields["news"])
                                try transport.renewProgress(id)
                                try await postNews(news)
                            case "source_read", "source_watch", "state_get", "state_set", "app_read":
                                let waitStarted = try transport.suspend(id)
                                do {
                                    try await service(fields, source: source, operation: operation)
                                    if type == "source_read" {
                                        let readAddress = if case .string(let a)? = fields["address"] { a } else { entryAddress }
                                        if progress.read(address: readAddress) {
                                            try transport.renewProgress(id)
                                        }
                                    }
                                }
                                catch {
                                    let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                                    let replyType = type == "app_read" ? "app_reply" : type.hasPrefix("state_") ? "state_reply" : "source_reply"
                                    try send(.object(["type": .string(replyType), "id": fields["id"] ?? .null,
                                        "callID": fields["callID"] ?? .null, "failure": try JSONValue.fromEncodable(failure)]))
                                }
                                try transport.resume(id, since: waitStarted)
                            case "log":
                                guard case .string(let text)? = fields["text"], logBytes + text.utf8.count <= 2_048 else {
                                    throw SenseFailure(code: "bad_output", message: "Sense logs exceed 2 KiB or are malformed.")
                                }
                                logBytes += text.utf8.count
                            case "act":
                                guard case .act = request, record.verbsEnabled, let perform,
                                      case .string(let verb)? = fields["verb"], case .string(let address)? = fields["address"] else {
                                    throw SenseFailure(code: "act_denied", message: "Sense actions require an active act request and the app door.")
                                }
                                let waitStarted = try transport.suspend(id)
                                do {
                                    acted = try await perform(verb, address, fields["args"] ?? .object([:]))
                                    // Save returned effects before observing cancellation or writing to a stopped helper.
                                    if let acted { pending?.returnedActions.append(acted) }
                                    try Task.checkCancellation()
                                    try reply(fields, type: "act_reply", value: acted ?? .null, field: "result")
                                } catch {
                                    let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                                    actFailure = failure
                                    try send(.object(["type": .string("act_reply"), "id": fields["id"] ?? .null,
                                        "callID": fields["callID"] ?? .null, "failure": try JSONValue.fromEncodable(failure)]))
                                }
                                try transport.resume(id, since: waitStarted)
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
                                    return .page(page, SenseProvenance(record: record))
                                } else {
                                    if changed == nil, case .act = request {
                                        if let actFailure { throw actFailure }
                                        guard let acted else {
                                            throw SenseFailure(code: "no_action", message: "The sense performed no door action; no success receipt exists.")
                                        }
                                        return .acted(acted, SenseProvenance(record: record))
                                    }
                                    if request == .watch, changed == nil {
                                        watching = !isSite || observation != nil
                                    }
                                    return .acted(.null, SenseProvenance(record: record))
                                }
                            default: throw SenseFailure(code: "bad_output", message: "Unknown sense helper message: \(type)")
                            }
                        }
                        throw CancellationError()
                    } catch {
                        let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                        return .failed(failure)
                    }
                }
                pending?.worker = worker
                // Join the worker before terminal recording, release and response; this retained owner must never join itself.
                let settlement = Task {
                    await settle {
                        let outcome = await worker.value
                        return await self.finish(id, outcome, turn: operation.turn)
                    }
                }
                pending?.settlement = settlement
                if Task.isCancelled { await cancel(id) }
                let outcome = await settlement.value
                if case .failed(let failure) = await worker.value {
                    await terminate(failure: ["cancelled", "file_changed", "no_action", "act_denied"].contains(failure.code) ? nil : failure)
                }
                return outcome
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) async {
        guard pending?.id == id else { return }
        await terminate(failure: nil, interruption: SenseFailure(code: "cancelled", message: "Sense request cancelled."))
    }

    /// Only joined, cancellation-independent settlement may retain door receipts after interruption without claiming completed interpretation.
    private func finish(_ id: Int, _ outcome: SenseOutcome, turn: Turn?) -> SenseOutcome {
        guard let current = pending, current.id == id else { return outcome }
        pending = nil
        var outcome = current.interruption.map(SenseOutcome.failed) ?? outcome
        if !current.returnedActions.isEmpty {
            var fields: [String: JSONValue]
            switch outcome {
            case .failed(let failure):
                fields = failure.failureEvidence()
                // An interrupted helper may have dispatched a call whose outcome is still unknown.
                fields["effects"] = .string("unknown")
            case .acted(let result, _):
                fields = if case .object(let value) = result { value } else { ["result": result] }
            case .page: fields = ["status": .string("ok"), "read": .bool(true)]
            }
            let effects = current.returnedActions.map { action -> JSONValue in
                guard case .object(let value) = action else { return .string("unknown") }
                return OwnedProgramRunner.effects(value) ?? .string("unknown")
            } + (fields["effects"].map { [$0] } ?? [])
            fields["effects"] = [JSONValue.string("unknown"), .string("partial"), .string("occurred")].first(where: effects.contains) ?? .string("none")
            fields["returned_actions"] = .array(current.returnedActions)
            outcome = .acted(.object(fields), SenseProvenance(record: record))
        }
        let receipt: JSONValue
        switch outcome {
        case .failed(let failure): receipt = .object(failure.failureEvidence())
        case .acted(let result, _): receipt = result == .null ? .object(["status": .string("ok")]) : result
        case .page: receipt = .object(["status": .string("ok"), "read": .bool(true)])
        }
        do { try AbilityStore(dataRoot: dataRoot).recordRun(id: record.id, version: record.candidateDigest ?? String(record.version), receipt: receipt,
            nativeSense: record.status == .on && record.origin == .builtIn ? JSONValue.fromEncodable(record) : nil, turn: turn) }
        catch {
            // recordRun owns ledger repair; its failure cannot replace the outcome's truth.
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
        current.events.finish(); transport.end(id)
        pendingDone.resume()
        pendingDone = ScopedWaiter()
        Task { await onSettled() }
        if !stopped, watching, pendingChange != nil {
            onSourceChange()
        }
        return outcome
    }

    func stop() async { await terminate(failure: nil) }

    func isFollowing() -> Bool { !stopped && watching && observation != nil }

    func stopIfIdle() async -> Bool {
        // Event subscriptions remain live work between source edges.
        guard pending == nil, idleHolds == 0, observation == nil else { return false }
        await terminate(failure: nil)
        return true
    }

    private func terminate(failure: SenseFailure?, interruption: SenseFailure? = nil) async {
        if let termination { await termination.value; return }
        stopped = true
        let settlement = pending?.settlement
        if var current = pending {
            let reason = interruption ?? failure ?? SenseFailure(code: "cancelled", message: "Sense helper stopped before answering.")
            current.interruption = reason
            current.worker?.cancel()
            current.events.finish(throwing: reason)
            pending = current
        }
        reader?.cancel(); observation?.cancel()
        pendingDone.resume()
        pendingDone = ScopedWaiter()
        transport.stop()
        let termination = Task { [onExit] in
            await settle {
                if let settlement { _ = await settlement.value }
                // Reap the process before removing its scratch directory.
                await onExit(failure)
            }
        }
        self.termination = termination
        await termination.value
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
                        guard case .object(let fields) = message else {
                            throw SenseFailure(code: "bad_output", message: "Sense helper sent a non-object message.")
                        }
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
        // The requesting worker owns error attribution and settlement.
        if let pending { pending.events.finish(throwing: failure) }
        else { await terminate(failure: failure) }
    }

    private func service(_ fields: [String: JSONValue], source: any SenseSourceProvider, operation: SenseReadOperation) async throws {
        switch fields["type"] {
        case .string("app_read"):
            guard let apps else { throw SenseFailure(code: "unavailable", message: "App reading is not connected.") }
            let targets = Dictionary((record.reach.apps ?? []).map { ($0, "read") }, uniquingKeysWith: { first, _ in first })
            let value = try await apps(fields["args"] ?? .null, targets, operation)
            try reply(fields, type: "app_reply", value: value, field: "result")
        case .string("source_read"):
            let corner = record.corner
            guard fields["corner"] == .string(corner.key) else {
                throw SenseFailure(code: "source_denied", message: "Sense source must stay in its declared corner.")
            }
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
                    return NativeAgentWorkspaceRoot.relativePath(candidate, under: root) != nil
                }) else {
                    throw SenseFailure(code: "source_denied", message: "Sense source must stay at its requested file or declared read reach.")
                }
            }
            let material = try await source.material(for: corner, address: address, operation: operation)
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
                let changes = try await provider.changes(for: record.corner, address: sourceAddress, operation: operation.observing())
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                let appObservation: JSONValue?
                if case .app = record.corner {
                    appObservation = Self.appObservation(try await source.material(for: record.corner, address: sourceAddress,
                        operation: operation.observing()))
                } else { appObservation = nil }
                try Task.checkCancellation()
                guard !stopped else { throw CancellationError() }
                if case .app = record.corner { lastAppObservation = appObservation }
                observedSource = source
                let generation = UUID()
                observationGeneration = generation
                // Following outlives the read and must inherit no turn authority.
                observation = Task.detached(priority: .utility) { [weak self] in
                    for await change in changes {
                        guard !Task.isCancelled else { break }
                        await self?.receiveChange(change, generation: generation)
                    }
                    await self?.observationEnded(generation)
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

    private func receiveChange(_ change: SenseSourceChange, generation: UUID) async {
        guard !stopped, !Task.isCancelled, generation == observationGeneration else { return }
        if case .absent = change {
            // Checked absence supplies no helper bytes; retain the source watch and report absence through sense news.
            do {
                try await postNews(SenseNews(senseID: record.id, version: record.version,
                    address: sourceAddress ?? record.corner.key,
                    summary: "Watched path is absent.", at: Date()))
                pendingChange = nil
                sourceUnavailable = false
            } catch {
                await terminate(failure: HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record)))
            }
            return
        }
        guard case .changed(let material, _) = change else {
            if case .unavailable(let failure) = change {
                sourceUnavailable = true
                do {
                    try await postNews(SenseNews(senseID: record.id, version: record.version,
                        address: sourceAddress ?? record.corner.key,
                        summary: "Source observation unavailable: " + failure.message, at: Date()))
                } catch {
                    await terminate(failure: HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record)))
                }
            }
            return
        }
        if sourceUnavailable {
            do {
                try await postNews(SenseNews(senseID: record.id, version: record.version,
                    address: sourceAddress ?? record.corner.key, summary: "Source observation available again.", at: Date()))
                sourceUnavailable = false
            } catch {
                await terminate(failure: HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record)))
                return
            }
        }
        if case .app = record.corner, let content = Self.appObservation(material) {
            guard content != lastAppObservation else { return }
            lastAppObservation = content
        }
        pendingChange = material
        if pending == nil, watching { onSourceChange() }
    }

    private func observationEnded(_ generation: UUID) async {
        guard generation == observationGeneration, !stopped, !Task.isCancelled else { return }
        observation = nil; observedSource = nil; pendingChange = nil; watching = false
        let summary: String
        switch record.corner {
        case .site: summary = "Stopped following this site because its Chrome source events ended."
        case .app: summary = "Stopped following this corner because its source events ended."
        case .fileKind, .stream, .need: summary = "Stopped following this file because its source events ended."
        }
        do {
            try await postNews(SenseNews(senseID: record.id, version: record.version,
                address: sourceAddress ?? record.corner.key, summary: summary, at: Date()))
        } catch {
            await terminate(failure: HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record)))
            return
        }
        guard generation == observationGeneration, !stopped, !Task.isCancelled else { return }
        await terminate(failure: nil)
    }

    private static func appObservation(_ material: SenseMaterial) -> JSONValue? {
        guard case .accessibility(.object(var fields)) = material else { return nil }
        // Selection-frame changes are bookkeeping and must not become world news.
        fields.removeValue(forKey: "frame_id")
        // Compare the same app content fields for baseline and events; subscription coverage belongs to the observer.
        fields.removeValue(forKey: "ax_watch_coverage")
        return .object(fields)
    }

    func drainChange() async {
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
            let outcome = await request(.watch, source: source, operation: .init(turn: nil, passive: true), changed: material)
            guard !stopped, !Task.isCancelled, observationGeneration == generation else { return }
            if case .failed(let failure) = outcome {
                try await postNews(SenseNews(senseID: record.id, version: record.version,
                    address: sourceAddress ?? record.corner.key,
                    summary: """
                        Live change could not be read: \(ContextSecretContentPolicy.redactedFragment(failure.code)): \
                        \(ContextSecretContentPolicy.redactedFragment(failure.message))
                        """, at: Date()))
            } else if case .app = record.corner, newsGeneration == previousNews {
                try await postNews(SenseNews(senseID: record.id, version: record.version,
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

    private func postNews(_ news: SenseNews) async throws {
        guard let registry = SensesHub.shared.registry else {
            throw SenseFailure(code: "source_unavailable", message: "Sense news registry is not installed.")
        }
        guard record.status == .on,
              let current = try await registry.sense(for: record.corner), current.status == .on,
              current.id == record.id, current.version == record.version else { return }
        var news = news
        news.observationID = isSite ? sourceTab : sourceFile
        guard await SenseNewsBoard.shared.post(news) else {
            try Task.checkCancellation()
            throw SenseFailure(code: "news_not_kept", message: "Sense news was not accepted by private news storage.")
        }
        newsGeneration &+= 1
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
        case .event(let event): .object(["type": .string("event"), "event": event])
        }
    }
}
