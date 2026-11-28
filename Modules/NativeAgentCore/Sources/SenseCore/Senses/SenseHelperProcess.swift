import Foundation
import Darwin
import PersistenceCore
import NativeAgentCore
// Blueprint: | `SenseHelperProcess.swift` | Request and watch supervision; pending calls join settlement and receipts retain returned effects |

actor SenseHelperProcess {
    private struct Pending {
        let id: Int
        let events: AsyncThrowingStream<JSONValue, Error>.Continuation
        var worker: Task<SenseOutcome, Never>?
        var settlement: Task<SenseOutcome, Never>?
        var interruption: SenseFailure?
        var returnedActions: [JSONValue] = []
    }
    private let record: SenseRecord
    private let dataRoot: URL
    private let script: String
    private let notebook: URL
    private let selection: String
    private let slot: String
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
            if watching != oldValue { NotificationCenter.default.post(SenseNewsBoard.PresentationDidChange()) }
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
    private var termination: Task<SenseFailure?, Never>?
    private var idleHolds = 0

    init(record: SenseRecord, dataRoot: URL, script: String, notebook: URL, scratch: URL, helper: URL,
         profile: String, limits: HelperSenseRunner.Limits, selection: String, slot: String, initialAddress: String?,
         apps: (@Sendable (JSONValue, [String: String],
             SenseReadOperation) async throws -> JSONValue)?,
         onSourceChange: @escaping @Sendable () -> Void,
         onSettled: @escaping @Sendable () async -> Void,
         onExit: @escaping @Sendable (SenseFailure?) async -> Void) throws {
        self.record = record; self.dataRoot = dataRoot; self.script = script; self.notebook = notebook
        self.selection = selection; self.slot = slot
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
                 changed: SenseMaterial? = nil, eventRoute: SenseNewsBoard.ViewRoute? = nil) async -> SenseOutcome {
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
            resetObservation()
        }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            do {
                let (stream, events) = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
                pending = Pending(id: id, events: events)
                // The worker holds this operation's turn, action dependency and read captures through settlement.
                let worker = Task<SenseOutcome, Never> {
                    await runRequestWorker(request, source: source, operation: operation, changed: changed, isEvent: isEvent, eventRoute: eventRoute,
                                           perform: perform, id: id, stream: stream)
                }
                pending?.worker = worker
                // Join the worker before terminal recording, release and response; this retained owner must never join itself.
                let settlement = Task {
                    await settle {
                        let outcome = await worker.value
                        return await self.finish(id, outcome, startingWatch: request == .watch && changed == nil, turn: operation.turn)
                    }
                }
                pending?.settlement = settlement
                if Task.isCancelled { await cancel(id) }
                let outcome = await settlement.value
                _ = await termination?.value
                return outcome
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Prepare the request, then read its replies through completion.
    private func runRequestWorker(_ request: SenseRequest, source: any SenseSourceProvider, operation: SenseReadOperation,
                                  changed: SenseMaterial?, isEvent: Bool, eventRoute: SenseNewsBoard.ViewRoute?, perform: SenseActionContext.Perform?, id: Int,
                                  stream: AsyncThrowingStream<JSONValue, Error>) async -> SenseOutcome {
        let wire: JSONValue, attachment: Data?, address: String?
        do {
            (wire, attachment, address) = try await sendRequest(request, source: source, operation: operation, changed: changed,
                                                   isEvent: isEvent, eventRoute: eventRoute, id: id)
        } catch { return .failed(HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))) }
        do {
            return try await receiveRequest(request, source: source, operation: operation, changed: changed, isEvent: isEvent,
                                            perform: perform, id: id, stream: stream, wire: wire, attachment: attachment, address: address)
        } catch {
            let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
            beginTermination(failure: failure)
            return .failed(failure)
        }
    }

    /// Capture source material, send the request and start its stall window.
    private func sendRequest(_ request: SenseRequest, source: any SenseSourceProvider, operation: SenseReadOperation,
                             changed: SenseMaterial?, isEvent: Bool, eventRoute: SenseNewsBoard.ViewRoute?, id: Int) async throws -> (JSONValue, Data?, String?) {
        let address: String?
        switch request {
        case .read(let a): address = a
        case .act(_, let a, _): address = a
        case .watch: address = sourceAddress
        case .event: address = if let eventRoute { eventRoute.address } else { sourceFile ?? sourceAddress }
        }
        var wire: JSONValue = .null
        var attachment: Data?
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
            (wire, attachment) = try await Self.materialWire(material, dataRoot: dataRoot, source: source)
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
        transport.begin(id: id, seconds: nil)
        if changed != nil {
            try send(.object(["id": .int(Int64(id)), "type": .string("changed"), "material": wire]), attachment: attachment)
        } else {
            var run: [String: JSONValue] = ["id": .int(Int64(id)), "type": .string("run"),
                "sense": try JSONValue.fromEncodable(record),
                "request": Self.requestWire(request), "material": wire]
            run["program"] = try .fromEncodable(OwnedProgram(kind: .sense, id: record.id,
                version: String(record.version), source: script, entry: .sense,
                reach: record.reach))
            try send(.object(run), attachment: attachment)
        }
        return (wire, attachment, address)
    }

    /// Service helper messages until the request has an outcome.
    private func receiveRequest(_ request: SenseRequest, source: any SenseSourceProvider, operation: SenseReadOperation,
                                changed: SenseMaterial?, isEvent: Bool, perform: SenseActionContext.Perform?, id: Int,
                                stream: AsyncThrowingStream<JSONValue, Error>, wire: JSONValue, attachment: Data?, address: String?) async throws -> SenseOutcome {
        var progress = SenseEntryProgress()
        let entryAddress = changed != nil || isEvent || request == .watch ? nil : address
        let siteViewEvent = if case .event(_, let revision) = request { isSite && revision != nil } else { false }
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
            if type != "done", type != "entry_failed", type != "progress" {
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
            case "source_copy":
                guard let attachment else { throw SenseFailure(code: "bad_input", message: "No file snapshot is bound.") }
                try reply(fields, type: "source_reply", value: wire, field: "material", attachment: attachment)
            case "publish":
                let decoded: NativePage
                do {
                    guard case .object(let supplied)? = fields["page"] else {
                        throw SenseFailure(code: "bad_output", message: "Sense publish requires a page.")
                    }
                    decoded = try SenseWire.decodePage(supplied, corner: record.corner)
                    try SenseWire.validatePage(decoded,
                        textError: "Sense page requires an address and at most 40,000 text bytes.")
                } catch {
                    try reject(fields, type: "publish_reply", error: error)
                    continue
                }
                page = try boundPage(decoded, material: wire)
                try transport.renewProgress(id)
                try reply(fields, type: "publish_reply", value: .null)
            case "present":
                do { view = try SenseWire.view(fields["view"], senseID: record.id, version: record.version) }
                catch { try reject(fields, type: "present_reply", error: error); continue }
                presented = true
                try reply(fields, type: "present_reply", value: .null)
            case "notify":
                var news: SenseNews
                do {
                    news = try SenseWire.news(fields["news"], senseID: record.id, version: record.version,
                        error: "Sense news requires address and summary (at most 4,000 bytes).")
                    news.address = ContextSecretContentPolicy.redactedFragment(news.address)
                    news.summary = ContextSecretContentPolicy.redactedFragment(news.summary)
                } catch { try reject(fields, type: "notify_reply", error: error); continue }
                guard news.summary.utf8.count <= SenseWire.newsBytes else {
                    throw SenseFailure(code: "bad_output", message: "Sense news requires an address and summary.")
                }
                try transport.renewProgress(id)
                do { try await postNews(news, fromEntry: true) }
                catch {
                    let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                    try reply(fields, type: "notify_reply", value: JSONValue.fromEncodable(failure), field: "failure")
                    continue
                }
                try reply(fields, type: "notify_reply", value: .null)
            case "source_read", "source_watch", "state_get", "state_set", "state_delete", "state_list", "state_cas", "app_read":
                let waitStarted = try transport.suspend(id)
                do {
                    try await service(fields, source: source, operation: operation, address: isEvent ? address : sourceAddress,
                                      siteViewEvent: siteViewEvent)
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
                guard case .string(let verb)? = fields["verb"], case .string(let address)? = fields["address"] else {
                    try reject(fields, type: "act_reply", error: SenseFailure(code: "bad_output",
                        message: "Sense actions are allowed only while answering an act request."))
                    continue
                }
                guard case .act = request, record.verbsEnabled, let perform else {
                    throw SenseFailure(code: "act_denied", message: "Sense actions require an active act request and the app door.")
                }
                let waitStarted = try transport.suspend(id)
                do {
                    acted = try await perform(verb, address, fields["args"] ?? .object([:]))
                    // Save returned effects before observing cancellation or writing to a stopped helper.
                    if let acted { pending?.returnedActions.append(acted) }
                    try Task.checkCancellation()
                    try jsonReply(fields, type: "act_reply", value: acted ?? .null)
                } catch {
                    let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                    actFailure = failure
                    try send(.object(["type": .string("act_reply"), "id": fields["id"] ?? .null,
                        "callID": fields["callID"] ?? .null, "failure": try JSONValue.fromEncodable(failure)]))
                }
                try transport.resume(id, since: waitStarted)
            case "entry_failed":
                let failure = try JSONDecoder().decode(SenseFailure.self, from: JSONEncoder().encode(fields["failure"] ?? .null))
                try transport.claimCompletion(id)
                return .failed(HelperSenseRunner.failure(failure, provenance: SenseProvenance(record: record)))
            case "done":
                try transport.claimCompletion(id)
                if case .read = request, page == nil {
                    throw SenseFailure(code: "bad_output", message: "Sense read finished without a page.")
                }
                do {
                    if presented, record.status == .on, let registry = SensesHub.shared.registry,
                       let current = try await registry.sense(for: record.corner), current.status == .on,
                       current.id == record.id, current.version == record.version,
                       try registry.helperSelection(current) == selection {
                        try Task.checkCancellation()
                        var siteSource = isSite ? source as? DoorSource : nil
                        var place = isEvent ? address : sourceFile ?? sourceAddress
                        if isSite, let tab = wire.objectValue?["snapshot"]?.objectValue?["tabId"]?.strictInt64 {
                            var input: [String: JSONValue] = [:]
                            if let place, place.hasPrefix("{"), case .object(let retained)? = try? JSONValue.parse(Data(place.utf8)) {
                                input = retained
                            }
                            input["tab_id"] = .int(tab)
                            place = try JSONValue.object(input).serialize(pretty: false)
                            siteSource = nil
                        }
                        await SenseNewsBoard.shared.present(view,
                            route: .init(selection: selection, slot: slot, address: place, siteSource: siteSource))
                    }
                } catch { return .failed(HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))) }
                if case .read = request {
                    guard let page else { throw SenseFailure(code: "bad_output", message: "Sense read finished without a page.") }
                    return .page(page, SenseProvenance(record: record))
                } else {
                    if changed == nil, case .act = request {
                        if let actFailure { return .failed(actFailure) }
                        guard let acted else {
                            return .failed(SenseFailure(code: "no_action", message: "The sense performed no door action; no success receipt exists."))
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
    }

    private func cancel(_ id: Int) async {
        guard pending?.id == id else { return }
        await terminate(failure: nil, interruption: SenseFailure(code: "cancelled", message: "Sense request cancelled."))
    }

    /// Only joined, cancellation-independent settlement may retain door receipts after interruption without claiming completed interpretation.
    private func finish(_ id: Int, _ outcome: SenseOutcome, startingWatch: Bool, turn: Turn?) -> SenseOutcome {
        guard let current = pending, current.id == id else { return outcome }
        pending = nil
        var outcome = current.interruption.map(SenseOutcome.failed) ?? outcome
        if case .failed = outcome, startingWatch || (!watching && observation != nil) { beginTermination(failure: nil) }
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

    @discardableResult
    func stop() async -> SenseFailure? {
        let readerTask = reader
        let observationTask = observation
        let failure = await beginTermination(failure: nil).value
        await readerTask?.value
        await observationTask?.value
        return failure
    }

    func isFollowing() -> Bool { !stopped && watching && observation != nil }

    func stopIfIdle() async -> Bool {
        // Event subscriptions remain live work between source edges.
        guard pending == nil, idleHolds == 0, observation == nil else { return false }
        await terminate(failure: nil)
        return true
    }

    private func terminate(failure: SenseFailure?, interruption: SenseFailure? = nil) async {
        _ = await beginTermination(failure: failure, interruption: interruption).value
    }

    @discardableResult
    private func beginTermination(failure: SenseFailure?, interruption: SenseFailure? = nil) -> Task<SenseFailure?, Never> {
        if let termination { return termination }
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
            return failure
        }
        self.termination = termination
        return termination
    }

    private func startReader() {
        reader = Task {
            var replied = false
            for await event in transport.events {
                guard !stopped else { return }
                switch event {
                case .frame(let frame):
                    do {
                        guard case .object(var fields) = try JSONValue.parse(frame.header) else {
                            throw SenseFailure(code: "bad_output", message: "Sense helper sent a non-object message.")
                        }
                        let needsPayload = ["app_read", "act", "state_get", "state_set", "state_delete", "state_list", "state_cas",
                                            "publish", "present", "notify"].contains(fields["type"]?.stringValue ?? "")
                        guard frame.flags == (needsPayload ? 2 : 0) else {
                            throw SenseFailure(code: "bad_frame", message: "Unexpected sense attachment.")
                        }
                        if needsPayload {
                            guard fields["id"] != nil, fields["callID"] != nil, frame.payload.count <= 2 * 1024 * 1024,
                                  case .object(let body) = try JSONValue.parse(frame.payload),
                                  Set(fields.keys).isDisjoint(with: body.keys) else {
                                throw SenseFailure(code: "bad_frame", message: "Invalid sense call payload.")
                            }
                            fields.merge(body) { header, _ in header }
                        }
                        replied = true
                        if let current = pending, fields["id"] == .int(Int64(current.id)) {
                            if fields["type"] == .string("failed") {
                                throw try JSONDecoder().decode(SenseFailure.self, from: JSONEncoder().encode(fields["failure"] ?? .null))
                            }
                            if case .dropped = current.events.yield(.object(fields)) {
                                throw SenseFailure(code: "output_limit", message: "Sense helper exceeded its pending message limit.")
                            }
                        } else {
                            throw SenseFailure(code: "bad_output", message: "Sense helper sent a message outside its request.")
                        }
                    } catch {
                        let failure = HelperSenseRunner.failure(error, provenance: SenseProvenance(record: record))
                        await terminate(failure: failure); return
                    }
                case .ended(let detail):
                    let failure = SenseFailure(code: replied ? "crashed" : "spawn_failed", message: detail)
                    await terminate(failure: failure); return
                }
            }
            if !stopped {
                let failure = transport.failure ?? SenseFailure(code: "resource_limit", message: "Sense helper output ended before its process settled.")
                await terminate(failure: failure)
            }
        }
    }

    private func service(_ fields: [String: JSONValue], source: any SenseSourceProvider, operation: SenseReadOperation,
                         address boundAddress: String?, siteViewEvent: Bool) async throws {
        switch fields["type"] {
        case .string("app_read"):
            guard let apps else { throw SenseFailure(code: "unavailable", message: "App reading is not connected.") }
            let targets = Dictionary((record.reach.apps ?? []).map { ($0, "read") }, uniquingKeysWith: { first, _ in first })
            let value = try await apps(fields["args"] ?? .null, targets, operation)
            try jsonReply(fields, type: "app_reply", value: value)
        case .string("source_read"):
            let corner = record.corner
            guard fields["corner"] == .string(corner.key) else {
                throw SenseFailure(code: "source_denied", message: "Sense source must stay in its declared corner.")
            }
            switch fields["address"] {
            case nil, .null, .string: break
            default: throw SenseFailure(code: "bad_output", message: "Sense source address must be a string or null.")
            }
            // A site view's event reads the reader or tab that produced that view.
            let address: String? = if !siteViewEvent, case .string(let value)? = fields["address"] { value } else { boundAddress }
            if case .fileKind = record.corner, let address,
               address != boundAddress, address != sourceFile,
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
            let (wire, attachment) = try await Self.materialWire(material, dataRoot: dataRoot, source: source)
            try Task.checkCancellation()
            if let attachment { try reply(fields, type: "source_reply", value: wire, field: "material", attachment: attachment) }
            else { try jsonReply(fields, type: "source_reply", value: wire) }
        case .string(let type) where ["state_get", "state_set", "state_delete", "state_list", "state_cas"].contains(type):
            let args: [JSONValue]
            if type == "state_list" {
                args = fields["prefix"].map { [$0] } ?? []
            } else {
                guard let key = fields["key"] else { throw SenseFailure(code: "bad_state", message: "Sense state requires a key.") }
                if type == "state_cas" || type == "state_set" {
                    guard let value = fields["value"] else { throw SenseFailure(code: "bad_state", message: "Sense state requires a JSON value.") }
                    let options = fields["options"].map { [$0] } ?? []
                    if type == "state_cas" {
                        guard let expected = fields["expected"] else { throw SenseFailure(code: "bad_state", message: "Compare-and-swap requires an expected value.") }
                        args = [key, expected, value] + options
                    } else { args = [key, value] + options }
                } else { args = [key] }
            }
            let call = try AbilityStore.NotebookCall(String(type.dropFirst("state_".count)), args, legacy: false)
            _ = try call.checkedWriteValue()
            let value = try AbilityStore.withLock {
                if call.writes, record.status != .draft {
                    let registry = FileSenseRegistry(dataRoot: dataRoot)
                    guard let current = try registry.presentationRecords().first(where: { $0.id == record.id }),
                          current.status == .on, (try? registry.helperSelection(current)) == selection else {
                        throw SenseFailure(code: "state_changed", message: "The notebook's sense was stopped or replaced.")
                    }
                }
                return try AbilityStore.notebook(notebook, call: call)
            }
            try jsonReply(fields, type: "state_reply", value: value)
        case .string("source_watch"):
            guard record.mode == .live, fields["corner"] == .string(record.corner.key) else {
                throw SenseFailure(code: "source_denied", message: "Only a live sense may subscribe to its declared corner.")
            }
            if observation == nil {
                guard let provider = source as? any SenseSourceWatchingProvider else {
                    throw SenseFailure(code: "unsupported", message: "Sense source does not provide live change events.")
                }
                let changes = try await provider.changes(for: record.corner, address: boundAddress, operation: operation.observing())
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

    private func resetObservation() {
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
        guard case .changed(let material, _, _) = change else {
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

    private func boundPage(_ input: NativePage, material: JSONValue) throws -> NativePage {
        var page = input
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
        return page
    }

    private func jsonReply(_ fields: [String: JSONValue], type: String, value: JSONValue) throws {
        guard !stopped else { throw SenseFailure(code: "crashed", message: "Sense helper has stopped.") }
        try transport.send(.object(["type": .string(type), "id": fields["id"] ?? .null, "callID": fields["callID"] ?? .null]),
            flags: 2, payload: PlugFrame.json(value))
    }

    private func reject(_ fields: [String: JSONValue], type: String, error: Error) throws {
        try reply(fields, type: type, value: .fromEncodable(SenseFailure(error, code: "bad_output")), field: "failure")
    }

    private func postNews(_ news: SenseNews, fromEntry: Bool = false) async throws {
        guard let registry = SensesHub.shared.registry else {
            throw SenseFailure(code: "source_unavailable", message: "Sense news registry is not installed.")
        }
        guard record.status == .on,
              let current = try await registry.sense(for: record.corner), current.status == .on,
              current.id == record.id, current.version == record.version else { return }
        var news = news
        news.observationID = isSite ? sourceTab : sourceFile
        news.watch = observationGeneration.uuidString
        guard await SenseNewsBoard.shared.post(news) else {
            try Task.checkCancellation()
            if fromEntry { throw SenseFailure(code: "news_not_kept", message: "Sense news was not accepted by private news storage.") }
            return
        }
        newsGeneration &+= 1
    }

    private func send(_ message: JSONValue, attachment: Data? = nil) throws {
        guard !stopped else { throw SenseFailure(code: "crashed", message: "Sense helper has stopped.") }
        try transport.send(message, flags: attachment == nil ? 0 : 1, payload: attachment ?? Data())
    }

    private func reply(_ fields: [String: JSONValue], type: String, value: JSONValue, field: String = "value", attachment: Data? = nil) throws {
        var response: [String: JSONValue] = ["type": .string(type), "id": fields["id"] ?? .null, field: value]
        if let callID = fields["callID"] { response["callID"] = callID }
        try send(.object(response), attachment: attachment)
    }

    private static func requestWire(_ request: SenseRequest) -> JSONValue {
        switch request {
        case .read(let address): .object(["type": .string("read"), "address": address.map(JSONValue.string) ?? .null])
        case .act(let verb, let address, let args): .object(["type": .string("act"), "verb": .string(verb), "address": .string(address), "args": args])
        case .watch: .object(["type": .string("watch")])
        case .event(let event, _): .object(["type": .string("event"), "event": event])
        }
    }
}
