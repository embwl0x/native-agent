import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AbandonedTurnReconciler.swift` | `TurnCheckpoint` retains its originating DataRootLife; reads project stopped/restored across lives, ordinary reconciliation settles through the Stop terminal record before retirement; independent checkpoint discovery, strict day validation, sweep-local terminal index and guarded retirement |

/// The conversation is rebuilt from the transcript; only in-flight state lives here.
public struct TurnCheckpoint: Codable, Sendable, Equatable {
    public let runId: String
    public var lifeID: String?
    public var stoppedReason: String?
    public let turnId: String
    public let sessionId: String
    public let surface: String
    public let userMessage: String
    public let acceptedAt: Date
    public var updatedAt = Date()
    public let envelope: [String: JSONValue]
    public let replyRoute: [String: JSONValue]
    public let fileAccess: String
    public let capabilityProfile: String?
    public var peerSources: [String]?
    /// The steering peers the person's card answered in this run: a resume
    /// continues under that one card, never a second.
    public var answeredPeers: [String]?
    /// What she attached to this reply with `reply.attach`, in order: a
    /// resume chooses them again, each behind the attachment fence once more.
    public var replyChoices: [String]?
    public let commandSignatureVerified: Bool?
    public let declaredRemote: Bool?
    public let helperDefinition: JSONValue?
    public var keptProse = ""
    public var workingCommentaryCharacters = 0
    public var workingNotes = ""
    /// Persisted sentinel: 1 while a call awaits its receipt, nil otherwise; never a step index.
    public var runningStep: Int?
    public var deliveryPending = false
    /// Input events and started-effect identities/digests. Relaunch reruns `step`
    /// to reconstruct state and effects; returned effect bodies are not stored.
    public var log: [JSONValue]?

    public var hasRedeliveryOwner: Bool {
        guard stoppedReason == nil, helperDefinition == nil,
              case .string(let surface)? = replyRoute["surface"] else { return false }
        return AgentBridgeCompletionRoute.Kind(surface: surface)?.hasRedeliveryOwner == true
    }

    /// What a turn that ended with `status` owes its door: its reply, kept here
    /// for redelivery, as `deliver:<surface>` to `<surface>:<destination>`, owed
    /// until that door says it holds it. Nil when nothing redelivers it, or when
    /// the door cannot yet say so (the phone): an obligation must be able to settle.
    public func owedDelivery(status: String) -> (key: String, to: String)? {
        guard hasRedeliveryOwner, status == "completed" || status == "waiting",
              case .string(let surface)? = replyRoute["surface"],
              AgentBridgeCompletionRoute.Kind(surface: surface)?.acceptsDurably == true else { return nil }
        let at = ["destinationId", "sourceKey", "threadId"].compactMap { key -> String? in
            if case .string(let value)? = replyRoute[key] { value } else { nil }
        }
        return ("deliver:" + surface, ([surface] + at).joined(separator: ":"))
    }

    public init(runId: String, turnId: String, sessionId: String, surface: String, userMessage: String,
                envelope: [String: JSONValue], replyRoute: [String: JSONValue], fileAccess: String,
                capabilityProfile: String?, peerSources: [String]?, commandSignatureVerified: Bool?,
                declaredRemote: Bool?, helperDefinition: JSONValue?, lifeID: String? = nil) {
        self.lifeID = lifeID
        self.runId = runId; self.turnId = turnId; self.sessionId = sessionId; self.surface = surface
        self.userMessage = userMessage; self.acceptedAt = Date()
        self.envelope = envelope; self.replyRoute = replyRoute; self.fileAccess = fileAccess
        self.capabilityProfile = capabilityProfile; self.peerSources = peerSources
        self.commandSignatureVerified = commandSignatureVerified; self.declaredRemote = declaredRemote
        self.helperDefinition = helperDefinition
    }

    public static func path(dataRoot: URL, sessionId: String, turnId: String) throws -> URL {
        guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId,
              NativeAgentChatSessionID.normalizedPathComponent(turnId) == turnId else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return dataRoot.appendingPathComponent("chat/session_state/\(sessionId)/turn-\(turnId).json")
    }

    public func write(dataRoot: URL) throws {
        let path = try Self.path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var record = self
        record.updatedAt = Date()
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(record), to: path)
    }

    public static func read(dataRoot: URL, sessionId: String, turnId: String) throws -> Self? {
        let path = try path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        var record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard record.sessionId == sessionId, record.turnId == turnId else { throw CocoaError(.fileReadCorruptFile) }
        if try !DataRootLife.isCurrent(record.lifeID, in: dataRoot) { record.stoppedReason = DataRootLife.stoppedReason }
        return record
    }

    public static func forSession(dataRoot: URL, sessionId: String) throws -> [Self] {
        try turnIds(dataRoot: dataRoot, sessionId: sessionId).compactMap {
            try read(dataRoot: dataRoot, sessionId: sessionId, turnId: $0)
        }
    }

    /// The turns a session holds checkpoints for, each readable on its own.
    public static func turnIds(dataRoot: URL, sessionId: String) throws -> [String] {
        let directory = try path(dataRoot: dataRoot, sessionId: sessionId, turnId: "checkpoint").deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("turn-") && $0.pathExtension == "json" }
            .map { String($0.deletingPathExtension().lastPathComponent.dropFirst(5)) }
    }

    public func remove(dataRoot: URL) throws {
        let path = try Self.path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

}

/// Checkpointed turns resume; a missing checkpoint keeps recovery owed.
public struct AbandonedTurnReconciler: Sendable {
    /// Ordinary trace window; checkpoints are discovered independently of age.
    public static let dayWindow = 3

    /// Upper bound on the catch-up scan after a gap. Without it, an install
    /// that has been off for months would read its whole trace history.
    public static let maximumDayWindow = 30

    /// Bound newly recorded obligations per sweep, including failed writes.
    public static let maximumWritesPerPass = 25

    /// Pinned at launch; only a previous process's turns are candidates.
    public static let processEpoch = Date()

    private let dataRoot: URL
    private let lane: TurnTracePersistLane
    private let now: @Sendable () -> Date
    private let processEpoch: Date

    public init(
        dataRoot: URL? = nil,
        lane: TurnTracePersistLane = TurnTracePersistLane(),
        now: @escaping @Sendable () -> Date = { Date() },
        processEpoch: Date = AbandonedTurnReconciler.processEpoch
    ) {
        self.lane = lane
        self.dataRoot = dataRoot ?? lane.resolvedDataRoot()
        self.now = now
        self.processEpoch = processEpoch
    }

    public struct Outcome: Sendable, Equatable {
        public let acceptedScanned: Int
        public let reconciled: [String]
        /// Turns accepted in this process are left alone.
        public let tooRecentToJudge: Int
        public let resumable: [TurnCheckpoint]
        /// Why the sweep could not conclude: a day file it could not read or a
        /// row it could not append. Nil for a conclusive sweep.
        public let failure: String?

        public init(acceptedScanned: Int, reconciled: [String], tooRecentToJudge: Int,
                    resumable: [TurnCheckpoint] = [], failure: String? = nil) {
            self.acceptedScanned = acceptedScanned
            self.reconciled = reconciled
            self.tooRecentToJudge = tooRecentToJudge
            self.resumable = resumable
            self.failure = failure
        }
    }

    private struct Accepted {
        let ts: Date
        let sessionId: String?
        let surface: String?
    }

    private static func isSettled(_ event: TurnTraceEvent) -> Bool {
        guard TurnTraceEvent.isTerminalKind(event.kind) else { return false }
        if case .object(let payload) = event.payload,
           payload["status"] == .string("abandoned") || payload["repairPending"] == .bool(true) { return false }
        return true
    }

    /// Discover checkpoints and reconcile a bounded legacy trace window.
    @discardableResult
    public func sweep(inFlightTurnIds: Set<String> = []) async -> Outcome {
        let today = now()
        var accepted: [String: Accepted] = [:]
        var terminated: Set<String> = []
        var terminalIndex: [URL: (terminated: Set<String>, replyReady: Set<String>)] = [:]

        let scan = scanRange(today: today)
        // Catch-up terminals are written today, outside a historical window.
        // Read them before selecting candidates so prior passes do not spend
        // the attempt budget again. Today's accepted turns stay outside that window.
        let terminalOnlyDays = scan.newestOffset > 0 ? [0] : []
        func readDay(_ path: URL, includeAccepted: Bool) async throws {
            guard terminalIndex[path] == nil else { return }
            var terminalTurns = Set<String>()
            var replyReadyTurns = Set<String>()
            let read = try await TurnTraceReplayReader.read(path)
            guard read.report.isClean else { throw CocoaError(.fileReadCorruptFile) }
            for event in read.events {
                let turnId = event.turnId
                if event.kind == "turn.accepted" {
                    guard includeAccepted, !turnId.isEmpty, turnId != "unknown", accepted[turnId] == nil else { continue }
                    accepted[turnId] = Accepted(ts: event.ts, sessionId: event.sessionId, surface: event.surface)
                } else if Self.isSettled(event) {
                    terminalTurns.insert(turnId)
                    if case .object(let payload) = event.payload,
                       payload["status"] == .string("completed") || payload["status"] == .string("waiting") {
                        replyReadyTurns.insert(turnId)
                    }
                }
            }
            terminalIndex[path] = (terminalTurns, replyReadyTurns)
        }
        // An unreadable day hides only what it holds: checkpoints are still found
        // and judged on their own days, and the window stays pending.
        var persistenceFailures: [String] = []
        for dayOffset in terminalOnlyDays + Array(scan.newestOffset...scan.oldestOffset) {
            guard let day = TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: -dayOffset, to: today)
            else { continue }
            let path = lane.path(for: day)
            do {
                try await readDay(path, includeAccepted: dayOffset >= scan.newestOffset)
                terminated.formUnion(terminalIndex[path]!.terminated)
            } catch {
                persistenceFailures.append("\(path.lastPathComponent) is unreadable: \(error.localizedDescription)")
            }
        }
        let ledgerComplete = persistenceFailures.isEmpty

        var tooRecent = 0
        var written: [String] = []
        var writeAttempts = 0
        var deferred = false
        var resumable: [TurnCheckpoint] = []
        var checkpoints: [String: TurnCheckpoint] = [:]
        // Unreadable checkpoints owe their own repair; their siblings still resume.
        var unreadable: Set<String> = []
        do {
            let root = dataRoot.appendingPathComponent("chat/session_state")
            if FileManager.default.fileExists(atPath: root.path) {
                for session in try FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    let sessionId = session.lastPathComponent
                    do {
                        let values = try session.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                        for turnId in try TurnCheckpoint.turnIds(dataRoot: dataRoot, sessionId: sessionId) {
                            do {
                                guard let checkpoint = try TurnCheckpoint.read(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
                                else { continue }
                                checkpoints[turnId] = checkpoint
                                if accepted[turnId] == nil {
                                    accepted[turnId] = Accepted(ts: checkpoint.acceptedAt,
                                        sessionId: checkpoint.sessionId, surface: checkpoint.surface)
                                }
                            } catch {
                                unreadable.insert(turnId)
                                let detail = "Turn checkpoint is unreadable; repair chat/session_state/\(sessionId)/turn-\(turnId).json before resuming: \(error)"
                                persistenceFailures.append(detail)
                                Self.owe(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId, detail: detail)
                            }
                        }
                    } catch {
                        unreadable.insert(sessionId)
                        let detail = "Turn checkpoint is unreadable; repair chat/session_state/\(sessionId) before resuming: \(error)"
                        persistenceFailures.append(detail)
                        Self.owe(dataRoot: dataRoot, sessionId: sessionId, turnId: "", detail: detail)
                    }
                }
            }
        } catch {
            let detail = "Turn checkpoint is unreadable; repair chat/session_state before resuming: \(error)"
            Self.owe(dataRoot: dataRoot, sessionId: "", turnId: "", detail: detail)
            return Outcome(acceptedScanned: accepted.count, reconciled: [], tooRecentToJudge: 0, failure: detail)
        }
        // A turn with no checkpoint is judged from the ledger alone, so only a
        // ledger read whole may owe its recovery.
        let candidates = accepted
            .filter { (checkpoints[$0.key] != nil || (ledgerComplete && !terminated.contains($0.key)))
                && !inFlightTurnIds.contains($0.key)
                && !unreadable.contains($0.key) && !unreadable.contains($0.value.sessionId ?? "") }
            .sorted {
                if (checkpoints[$0.key] != nil) != (checkpoints[$1.key] != nil) { return checkpoints[$0.key] != nil }
                return $0.value.ts < $1.value.ts
            }
        for (turnId, row) in candidates {
            // A turn this process accepted is never abandoned by this process;
            // one a previous process accepted cannot still be running.
            guard row.ts < processEpoch || checkpoints[turnId]?.stoppedReason != nil else {
                tooRecent += 1
                continue
            }
            if let checkpoint = checkpoints[turnId] {
                do {
                    let days = Set([row.ts, checkpoint.updatedAt, today].flatMap { day in
                        [day] + [-1, 1].compactMap { TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: $0, to: day) }
                    }.map { lane.path(for: $0) })
                    for path in days { try await readDay(path, includeAccepted: false) }
                    let hasTerminal = days.contains { terminalIndex[$0]!.terminated.contains(turnId) }
                    if let reason = checkpoint.stoppedReason {
                        let terminal = TurnTraceEvent(turnId: turnId, ts: checkpoint.updatedAt, kind: "turn.cancelled",
                            sessionId: checkpoint.sessionId, surface: checkpoint.surface,
                            payload: .object(["status": .string("stopped"), "terminalReason": .string(reason)]))
                        let result: Result<Void, any Error> = await settle { [lane, dataRoot] in
                            do {
                                if !hasTerminal {
                                    let target = lane.path(for: terminal.ts)
                                    _ = try await lane.appendGuarded(terminal, alsoLocking: Array(days)) { current in
                                        guard current.report.isClean else { throw CocoaError(.fileReadCorruptFile) }
                                        var events = current.events
                                        for path in days where path != target && FileManager.default.fileExists(atPath: path.path) {
                                            let read = TurnTraceReplayReader.parse(try Data(contentsOf: path))
                                            guard read.report.isClean else { throw CocoaError(.fileReadCorruptFile) }
                                            events += read.events
                                        }
                                        return !events.contains { $0.turnId == turnId && Self.isSettled($0) }
                                    }
                                }
                                try checkpoint.remove(dataRoot: dataRoot)
                                return .success(())
                            } catch { return .failure(error) }
                        }
                        try result.get()
                        written.append(turnId)
                        continue
                    }
                    if hasTerminal, checkpoint.deliveryPending, !checkpoint.hasRedeliveryOwner {
                        // A finished turn whose route cannot redeliver: the retirement row
                        // lands durably (deduped) before the file goes, so a kill between the
                        // two retires it again next launch and never loses the row.
                        let retired = TurnTraceEvent(turnId: turnId, kind: "turn.checkpoint_retired",
                            sessionId: checkpoint.sessionId, surface: checkpoint.surface,
                            payload: .object(["reason": .string("no_redelivery_owner")]))
                        let wrote = try await lane.appendGuarded(retired) { current in
                            !current.events.contains { $0.kind == "turn.checkpoint_retired" && $0.turnId == turnId }
                        }
                        if wrote { await TurnTraceBus.shared.deliverToSubscribers(retired) }
                        try checkpoint.remove(dataRoot: dataRoot)
                        continue
                    }
                    let replyReady = checkpoint.deliveryPending
                        && days.contains { terminalIndex[$0]!.replyReady.contains(turnId) }
                    if !hasTerminal || replyReady { resumable.append(checkpoint) }
                    else { try checkpoint.remove(dataRoot: dataRoot) }
                } catch {
                    let detail = "Cannot check checkpoint terminal: \(error)"
                    persistenceFailures.append(detail)
                    Self.owe(dataRoot: dataRoot, sessionId: checkpoint.sessionId, turnId: turnId, detail: detail)
                }
                continue
            }
            let id = "turn-recovery:" + turnId
            // A turn whose recovery is already owed is settled for this sweep;
            // only a new record spends the pass's write quota.
            if (try? await ExperienceStore.at(dataRoot).experience(id)) != nil {
                written.append(turnId)
                continue
            }
            guard writeAttempts < Self.maximumWritesPerPass else {
                deferred = true
                break
            }
            writeAttempts += 1
            await Self.owe(dataRoot: dataRoot, sessionId: row.sessionId ?? "unknown", turnId: turnId,
                detail: "The accepted turn has no saved checkpoint or confirmed terminal. Restore its checkpoint from retained evidence before resuming; do not repeat uncertain effects.", id: id).value
            do {
                guard try await ExperienceStore.at(dataRoot).experience(id) != nil else { throw CocoaError(.fileWriteUnknown) }
                written.append(turnId)
            } catch { persistenceFailures.append("Turn recovery could not keep its repair obligation: \(error)") }
        }
        // The cursor advances only over scanned days whose candidates are confirmed.
        // A failed read/append or deferred candidate leaves the window pending.
        // Stable repair identities make another sweep of unfinished turns idempotent.
        if persistenceFailures.isEmpty, !deferred, let newestScannedDay = TurnTracePersistLane.dayCalendar.date(
            byAdding: .day, value: -scan.newestOffset, to: today
        ) {
            writeCursor(day: newestScannedDay)
        }
        return Outcome(
            acceptedScanned: accepted.count,
            reconciled: written,
            tooRecentToJudge: tooRecent,
            resumable: resumable,
            failure: persistenceFailures.isEmpty ? nil : persistenceFailures.joined(separator: "\n")
        )
    }

    static func operation(sessionId: String, turnId: String) -> String {
        "turn.reconcile:" + (turnId.isEmpty ? "session:" + sessionId : turnId)
    }

    static func owner(sessionId: String, turnId: String) -> String {
        "chat/session_state/" + sessionId + (turnId.isEmpty ? "" : "/turn-\(turnId).json")
    }

    public static func repairCall(sessionId: String, turnId: String) -> String {
        ToolFailureError.call("app", ["action": .string("turn.reconcile"),
            "args": .object(["session_id": .string(sessionId), "turn_id": .string(turnId)])])
    }

    @discardableResult
    static func owe(dataRoot: URL, sessionId: String, turnId: String, detail: String, id: String = UUID().uuidString) -> Task<Void, Never> {
        RepairOwed.owe(dataRoot, id: id, kind: .run,
            evidence: [.init(source: "turn_traces", id: turnId)], operation: operation(sessionId: sessionId, turnId: turnId),
            owner: owner(sessionId: sessionId, turnId: turnId), words: detail,
            nextCall: repairCall(sessionId: sessionId, turnId: turnId))
    }

    /// Day-offsets from `today` this sweep reads (0 = today), oldest offset
    /// last. Ordinarily `dayWindow` days ending today; after a gap it reaches
    /// back to the last swept day so a turn abandoned outside the ordinary
    /// window is not missed. When the gap is longer than `maximumDayWindow`
    /// the window sits at the OLD end of the backlog — the sweep drains the
    /// oldest unswept days first and the cursor advances by that much, so the
    /// next sweep continues where this one stopped rather than skipping to
    /// today.
    private func scanRange(today: Date) -> (newestOffset: Int, oldestOffset: Int) {
        // Without a cursor, drain from before the oldest trace day, oldest-first.
        guard let cursorDay = persistedCursorDay() ?? oldestTraceDay().flatMap({
            TurnTracePersistLane.dayCalendar.date(byAdding: .day, value: -1, to: $0)
        }) else {
            // Nothing has ever been traced. Ordinary window ending today.
            return (0, Self.dayWindow - 1)
        }
        let calendar = TurnTracePersistLane.dayCalendar
        let lastOffset = max(0, calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: cursorDay),
            to: calendar.startOfDay(for: today)
        ).day ?? 0)
        // Days back that still need a look, counting the cursor day itself.
        let unswept = max(Self.dayWindow, lastOffset + 1)
        let window = min(Self.maximumDayWindow, unswept)
        let oldestOffset = unswept - 1
        return (oldestOffset - (window - 1), oldestOffset)
    }

    /// The day recorded by the last sweep, if the cursor file is readable.
    private func persistedCursorDay() -> Date? {
        guard let raw = try? String(contentsOf: cursorPath, encoding: .utf8),
              let value = try? JSONValue.parse(Data(raw.utf8)),
              case .object(let obj) = value,
              case .string(let day)? = obj["lastSweptDay"],
              let last = TurnTracePersistLane.day(from: day) else { return nil }
        return last
    }

    /// Oldest `yyyy-MM-dd.jsonl` day file on disk, or nil when none exist.
    /// Read from the lane's own directory so writer root overrides apply.
    private func oldestTraceDay() -> Date? {
        let dir = lane.path(for: now()).deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap {
                TurnTracePersistLane.day(
                    from: $0.deletingPathExtension().lastPathComponent
                )
            }
            .min()
    }

    private var cursorPath: URL {
        dataRoot
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("abandoned-reconciler-cursor.json")
    }

    private func writeCursor(day date: Date) {
        let day = TurnTracePersistLane.dayString(from: date)
        try? SwiftNativePersistenceCore.writeDataAtomicDurable(Data("{\"lastSweptDay\":\"\(day)\"}".utf8), to: cursorPath)
    }
}
