import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
import Experiences
import os
// Blueprint: | `TurnTracePersistLane.swift` | The one trace writer and reader of the record's details; terminal and dispatch notices; the agent's done verbs (`Deed`) |

/// One trace writer: a turn's events are details about its heard experience (subject = turn id); a standalone receipt is a detail about none.
/// `append` logs failures; checked and terminal writes propagate them.
public struct TurnTracePersistLane: Sendable {
    /// Reads and writes resolve the same root: environment, instance, default.
    public func resolvedDataRoot() -> URL {
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_TURN_TRACE_ROOT"], !raw.isEmpty {
            return literalFileURL(raw)
        }
        return dataRootOverride ?? defaultDataRoot()
    }

    let dataRootOverride: URL?
    public init(dataRootOverride: URL? = nil) {
        self.dataRootOverride = dataRootOverride
    }

    var store: ExperienceStore { ExperienceStore.at(resolvedDataRoot()) }
    /// The record names this lane as the owner of the details it writes; it reads only those.
    static let source = "trace"

    /// Write one event; log a failure.
    public func append(_ event: TurnTraceEvent) async {
        do { try await appendChecked(event) }
        catch { ModuleLog(category: "TurnTracePersistLane")("append failed (\(event.kind), turn \(event.turnId)): \(error)", level: .error) }
    }

    /// Write one event. A `transitionId` makes the write happen at most once under that id.
    public func appendChecked(_ event: TurnTraceEvent, transitionId: String? = nil) async throws {
        let written = try await store.note([try event.detail(once: transitionId.map { "transition:" + $0 })],
                                           durable: TurnTraceEvent.isTerminalKind(event.kind))
        if let seq = written.first ?? nil { feed(event); noteDeed(event); postCompletionIfNeeded(event, seq: seq) }
    }

    /// Write events in one transaction, in order: one disk sync for the whole flush.
    public func appendBatch(_ events: [TurnTraceEvent]) async throws {
        guard !events.isEmpty else { return }
        let written = try await store.note(events.map { try $0.detail() }, durable: events.contains { TurnTraceEvent.isTerminalKind($0.kind) })
        for (event, seq) in zip(events, written) { if let seq { feed(event); noteDeed(event); postCompletionIfNeeded(event, seq: seq) } }
    }

    /// The newest successful standalone receipt of a kind: its id and time. A reading in memory, fed as receipts are written and read from the
    /// record once per kind per launch, so a turn that asks never queries the record.
    public func newestSuccessfulReceipt(kind: String) async throws -> (id: String, at: Date)? {
        let key = resolvedDataRoot().standardizedFileURL.path
        if let known = Self.receipts.withLock({ $0[key]?[kind] }) { return known.value }
        var newest: (id: String, at: Date)?
        var before: Int64?
        while newest == nil {
            let page = try await store.details(.init(sources: [Self.source], subjects: [""], kinds: [kind], before: before, limit: 128,
                                                     newestFirst: true))
            for detail in page {
                guard let event = TurnTraceEvent(detail: detail) else {
                    throw PersistenceCoreError.ioFailure("The \(kind) receipt \(detail.seq) is unreadable; the newest successful one cannot be known.")
                }
                if let found = Self.success(event) { newest = found; break }
            }
            guard page.count == 128, let last = page.last?.seq else { break }
            before = last
        }
        // A receipt written while this read ran is already in memory; the newer of the two stands.
        let read = newest
        return Self.receipts.withLock { state in
            let fed = state[key]?[kind]?.value
            let kept = [read, fed].compactMap { $0 }.max { $0.at < $1.at }
            state[key, default: [:]][kind] = Known(value: kept)
            return kept
        }
    }

    /// A deed, said once for the record and for memory: a written `tool.dispatch` row is something the agent's own mind did when it ended `ok` and
    /// `succeeded`, not as a preview, top-level (no `parentId`), not the body's own (no `automaticOrigin`), and inside a turn holding an admitted
    /// model (`receipt.model`, the route admitted at the turn's boundary that made the call). What the app runs by itself holds none: a runner
    /// (`DeskNotifyRunner`'s ability), a part's wake or a carried habit (`withCurrentChatModel` clears it), a person's tap, a page's own read.
    private enum Deed {
        static let action = "$.payload.receipt.action"
        /// Scalars only: their serialized text is the JSON SQLite compares with.
        static let holding: [String: JSONValue] = ["$.payload.phase": .string("end"), "$.payload.status": .string("ok"),
                                                   "$.payload.receipt.resultClass": .string("succeeded"), "$.payload.receipt.preview": .bool(false)]
        static let lacking = ["$.payload.parentId", "$.payload.automaticOrigin"]
        static let bearing = ["$.payload.receipt.model"]

        /// The same conditions read off one row in memory as SQLite reads them off the record: `holding` is JSON equality, `lacking` absence,
        /// `bearing` text.
        static func doneVerb(in row: JSONValue) -> String? {
            func at(_ path: String) -> JSONValue? {
                path.split(separator: ".").dropFirst().reduce(Optional(row)) { value, key in value?.objectValue?[String(key)] }
            }
            guard case .string(let done)? = at(action), holding.allSatisfy({ at($0.key) == $0.value }), lacking.allSatisfy({ at($0) == nil }),
                  bearing.allSatisfy({ if case .string? = at($0) { true } else { false } }) else { return nil }
            return done
        }
    }

    /// The distinct verbs the agent's own mind has done (`Deed`), as far back as the record holds their details. The record is asked once per root, at the
    /// first ask, and answers without decoding a row; every deed written since is noted as it is written, so a later ask is answered from memory
    /// and never queries again. A record that could not be read is reported to that first ask only; deeds written since still count. A record
    /// not yet written has done nothing.
    public func doneVerbs() throws -> Set<String> {
        let key = resolvedDataRoot().standardizedFileURL.path
        if let known = Self.done.withLock({ state in state[key].flatMap { $0.read ? $0.verbs : nil } }) { return known }
        let recorded: [String], failure: (any Error)?
        do {
            recorded = try store.recordedDetailValues(.init(sources: [Self.source], kinds: ["tool.dispatch"]), at: Deed.action,
                holding: try Deed.holding.mapValues { try $0.serialize(pretty: false) }, lacking: Deed.lacking, bearing: Deed.bearing)
            failure = nil
        } catch {
            recorded = []
            failure = error
        }
        // A deed written while this read ran is already in memory; both stand.
        let verbs = Self.done.withLock { state in
            var known = state[key] ?? Done()
            known.verbs.formUnion(recorded)
            known.read = true
            state[key] = known
            return known.verbs
        }
        if let failure { throw failure }
        return verbs
    }

    /// A deed written is in the agent's done set from that write on; a root not yet read keeps it for its first read.
    private func noteDeed(_ event: TurnTraceEvent) {
        guard event.kind == "tool.dispatch", let verb = Deed.doneVerb(in: event.row) else { return }
        let key = resolvedDataRoot().standardizedFileURL.path
        Self.done.withLock { state in _ = state[key, default: Done()].verbs.insert(verb) }
    }

    private struct Done: Sendable { var read = false; var verbs: Set<String> = [] }
    private static let done = OSAllocatedUnfairLock<[String: Done]>(initialState: [:])

    private struct Known: Sendable { let value: (id: String, at: Date)? }
    private static let receipts = OSAllocatedUnfairLock<[String: [String: Known]]>(initialState: [:])

    private static func success(_ event: TurnTraceEvent) -> (id: String, at: Date)? {
        guard event.turnId == "unknown", event.diagnostic["status"] == .string("ok"), case .string(let id)? = event.diagnostic["id"],
              case .string(let raw)? = event.diagnostic["createdAt"], let at = TurnTraceEvent.parseISO8601(raw) else { return nil }
        return (id, at)
    }

    /// A written receipt updates a reading already in memory; a kind not yet read stays unread until asked.
    private func feed(_ event: TurnTraceEvent) {
        guard let found = Self.success(event) else { return }
        let key = resolvedDataRoot().standardizedFileURL.path
        Self.receipts.withLock { state in
            guard let known = state[key]?[event.kind] else { return }
            if (known.value?.at ?? .distantPast) <= found.at { state[key]?[event.kind] = Known(value: found) }
        }
    }

    /// Write one event unless its turn's events already say it is not needed (`already` sees them in order); the read and the write are one
    /// transaction, flushed through the drive's cache because a checkpoint is removed on its strength. Returns whether it wrote.
    @discardableResult
    public func appendGuarded(_ event: TurnTraceEvent, unless already: @escaping @Sendable ([TurnTraceEvent]) throws -> Bool) async throws -> Bool {
        let detail = try event.detail()
        let wrote = try await store.note(detail, durable: true) { existing in
            try already(existing.compactMap(TurnTraceEvent.init(detail:)))
        }
        if wrote, let seq = try await store.details(.init(sources: [Self.source], subjects: [detail.subject], kinds: [detail.kind], limit: 1,
                                                          newestFirst: true)).first?.seq {
            postCompletionIfNeeded(event, seq: seq)
        }
        return wrote
    }

    /// Read this lane's events through the record; another owner's detail is never read here. Rows that no longer decode as a trace event are
    /// counted, never dropped silently.
    public func events(_ query: ExperienceStore.DetailQuery) async throws -> TraceRead {
        var query = query
        query.sources = [Self.source]
        let details = try await store.details(query)
        let events = details.compactMap(TurnTraceEvent.init(detail:))
        return TraceRead(events: events, unreadable: details.count - events.count, lastSeq: details.map(\.seq).max())
    }

    /// Terminal observers hear only a written live terminal; dispatch observers hear only a written closing row. Reconciliation announces neither.
    private func postCompletionIfNeeded(_ event: TurnTraceEvent, seq: Int64) {
        guard TurnTraceEvent.isTerminalKind(event.kind) || event.kind == "tool.dispatch.closed" else { return }
        if case .object(let payload) = event.payload,
           case .string("terminal_reconciliation")? = payload["observedBy"] {
            return
        }
        var info: [String: Any] = ["turnId": event.turnId, "kind": event.kind, "seq": seq]
        info["sessionId"] = event.sessionId
        info["surface"] = event.surface
        if case .object(let fields) = event.payload {
            if case .string(let part)? = fields["part"] { info["part"] = part }
            if case .string(let steer)? = fields["steered_by"] { info["agent"] = steer }
        }
        NotificationCenter.default.post(name: event.kind == "tool.dispatch.closed" ? .turnTraceDispatchClosedPersisted : .turnTraceTerminalPersisted,
                                        object: nil, userInfo: info)
    }

    /// Guard the shared formatter with dayLock: "today" and "this week" are days on the Mac's clock.
    private static let dayLock = NSLock()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    package static func dayString(from date: Date) -> String {
        dayLock.withLock { dayFormatter.string(from: date) }
    }

    package static func day(from string: String) -> Date? {
        dayLock.withLock { dayFormatter.date(from: string) }
    }

    /// Day arithmetic on the Mac's clock, including across DST changes.
    package static var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dayLock.withLock { dayFormatter.timeZone }
        return calendar
    }
}

/// Trace events read from the record, with the count of rows that no longer decode and the newest sequence read.
public struct TraceRead: Sendable {
    public let events: [TurnTraceEvent]
    public let unreadable: Int
    public let lastSeq: Int64?
    public var isClean: Bool { unreadable == 0 }
}

extension TurnTraceEvent {
    /// The detail this event is: about its turn (the turn's id is its heard experience's id), or about none for a standalone receipt. The row is the
    /// full envelope plus any receipt fields, so every detail reads back as the event it was.
    func detail(once: String? = nil) throws -> ExperienceStore.Detail {
        ExperienceStore.Detail(source: TurnTracePersistLane.source, at: ts, subject: turnId == "unknown" ? "" : turnId, kind: kind,
                               row: try row.serializedData(pretty: false), once: once)
    }

    /// The row this event is written as; a reading of a written event reads this.
    var row: JSONValue {
        .object(Self.ordinaryEnvelope(payload: payload, turnId: turnId, ts: ts, kind: kind, sessionId: sessionId, surface: surface,
                                      destinationId: destinationId, threadId: threadId).merging(diagnostic) { _, receipt in receipt })
    }

    init?(detail: ExperienceStore.Detail) {
        guard let row = try? JSONValue.parse(detail.row) else { return nil }
        self.init(persistedJSONRow: row, physicalByteCount: detail.row.count + 1)
    }
}

extension Notification.Name {
    /// Posted once the dispatch owner's closing coverage row is written. The same turnId/seq envelope lets off-turn readers join terminal and dispatch
    /// completion in either order, without polling.
    public static let turnTraceDispatchClosedPersisted =
        Notification.Name("turnTraceDispatchClosedPersisted")

    /// Notify only after a terminal is written; carry turnId, kind and seq plus known session, surface, part and steering agent. This notification requires
    /// a real turn, unlike chatTurnCompleted.
    public static let turnTraceTerminalPersisted =
        Notification.Name("turnTraceTerminalPersisted")
}
