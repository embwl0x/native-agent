import Foundation
import NativeAgentCore
import PersistenceCore

/// The conversation is rebuilt from the transcript; only in-flight state lives here.
public struct TurnCheckpoint: Codable, Sendable, Equatable {
    public let runId: String
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
    public let commandSignatureVerified: Bool?
    public let declaredRemote: Bool?
    public let helperDefinition: JSONValue?
    public var keptProse = ""
    public var workingCommentaryCharacters = 0
    public var workingNotes = ""
    public var runningStep: Int?
    public var deliveryPending = false

    public var hasRedeliveryOwner: Bool {
        guard helperDefinition == nil, case .string(let surface)? = replyRoute["surface"] else { return false }
        return AgentBridgeCompletionRoute.Kind(surface: surface)?.hasRedeliveryOwner == true
    }

    public init(runId: String, turnId: String, sessionId: String, surface: String, userMessage: String,
                envelope: [String: JSONValue], replyRoute: [String: JSONValue], fileAccess: String,
                capabilityProfile: String?, peerSources: [String]?, commandSignatureVerified: Bool?,
                declaredRemote: Bool?, helperDefinition: JSONValue?) {
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
        try JSONEncoder().encode(record).write(to: path, options: .atomic)
    }

    public static func read(dataRoot: URL, sessionId: String, turnId: String) throws -> Self? {
        let path = try path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard record.sessionId == sessionId, record.turnId == turnId else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    public static func forSession(dataRoot: URL, sessionId: String) throws -> [Self] {
        let directory = try path(dataRoot: dataRoot, sessionId: sessionId, turnId: "checkpoint").deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("turn-") && $0.pathExtension == "json" }
            .compactMap { file in
                try read(dataRoot: dataRoot, sessionId: sessionId,
                    turnId: String(file.deletingPathExtension().lastPathComponent.dropFirst(5)))
            }
    }

    public func remove(dataRoot: URL) throws {
        let path = try Self.path(dataRoot: dataRoot, sessionId: sessionId, turnId: turnId)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}

/// Checkpointed turns resume; older turns without a checkpoint retain an honest terminal.
public struct AbandonedTurnReconciler: Sendable {
    /// Ordinary trace window; checkpoints are discovered independently of age.
    public static let dayWindow = 3

    /// Upper bound on the catch-up scan after a gap. Without it, an install
    /// that has been off for months would read its whole trace history.
    public static let maximumDayWindow = 30

    /// Bound guarded rereads as well as durable appends, including failed writes.
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
        func readDay(_ path: URL, includeAccepted: Bool) throws {
            guard terminalIndex[path] == nil else { return }
            var terminalTurns = Set<String>()
            var replyReadyTurns = Set<String>()
            if FileManager.default.fileExists(atPath: path.path) {
                let text = try String(contentsOf: path, encoding: .utf8)
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard Self.lifecycleKinds.contains(where: { line.utf8.firstRange(of: $0.utf8) != nil }),
                          let data = String(line).data(using: .utf8),
                          let value = try? JSONValue.parse(data),
                          case .object(let row) = value,
                          case .string(let kind)? = row["kind"],
                          case .string(let turnId)? = row["turnId"] else { continue }
                    switch kind {
                    case "turn.accepted":
                        guard includeAccepted, !turnId.isEmpty, turnId != "unknown", accepted[turnId] == nil,
                              case .string(let stamp)? = row["ts"],
                              let ts = Self.iso8601(stamp) else { continue }
                        accepted[turnId] = Accepted(ts: ts,
                            sessionId: Self.string(row["sessionId"]), surface: Self.string(row["surface"]))
                    case "turn.terminal", "turn.cancelled", "turn.failed":
                        terminalTurns.insert(turnId)
                        if case .object(let payload)? = row["payload"],
                           payload["status"] == .string("completed") || payload["status"] == .string("waiting") {
                            replyReadyTurns.insert(turnId)
                        }
                    default:
                        continue
                    }
                }
            }
            terminalIndex[path] = (terminalTurns, replyReadyTurns)
        }
        for dayOffset in terminalOnlyDays + Array(scan.newestOffset...scan.oldestOffset) {
            guard let day = Self.dayCalendar.date(byAdding: .day, value: -dayOffset, to: today)
            else { continue }
            let path = lane.path(for: day)
            do {
                try readDay(path, includeAccepted: dayOffset >= scan.newestOffset)
                terminated.formUnion(terminalIndex[path]!.terminated)
            } catch {
                return Outcome(acceptedScanned: 0, reconciled: [], tooRecentToJudge: 0,
                               failure: "\(path.lastPathComponent) is unreadable")
            }
        }

        var tooRecent = 0
        var written: [String] = []
        var writeAttempts = 0
        var persistenceFailures: [String] = []
        var deferred = false
        var resumable: [TurnCheckpoint] = []
        var checkpoints: [String: TurnCheckpoint] = [:]
        var unreadableSessions: Set<String> = []
        do {
            let root = dataRoot.appendingPathComponent("chat/session_state")
            if FileManager.default.fileExists(atPath: root.path) {
                for session in try FileManager.default.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    do {
                        let values = try session.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                        for checkpoint in try TurnCheckpoint.forSession(dataRoot: dataRoot, sessionId: session.lastPathComponent) {
                            let turnId = checkpoint.turnId
                            checkpoints[turnId] = checkpoint
                            if accepted[turnId] == nil {
                                accepted[turnId] = Accepted(ts: checkpoint.acceptedAt,
                                    sessionId: checkpoint.sessionId, surface: checkpoint.surface)
                            }
                        }
                    } catch {
                        unreadableSessions.insert(session.lastPathComponent)
                        persistenceFailures.append("Turn checkpoint is unreadable; repair chat/session_state/\(session.lastPathComponent) before resuming: \(error)")
                    }
                }
            }
        } catch {
            return Outcome(acceptedScanned: accepted.count, reconciled: [], tooRecentToJudge: 0,
                failure: "Turn checkpoint is unreadable; repair chat/session_state before resuming: \(error)")
        }
        let candidates = accepted
            .filter { (!terminated.contains($0.key) || checkpoints[$0.key] != nil)
                && !inFlightTurnIds.contains($0.key)
                && !unreadableSessions.contains($0.value.sessionId ?? "") }
            .sorted {
                if (checkpoints[$0.key] != nil) != (checkpoints[$1.key] != nil) { return checkpoints[$0.key] != nil }
                return $0.value.ts < $1.value.ts
            }
        for (turnId, row) in candidates {
            let age = today.timeIntervalSince(row.ts)
            // A turn this process accepted is never abandoned by this process;
            // one a previous process accepted cannot still be running.
            guard row.ts < processEpoch else {
                tooRecent += 1
                continue
            }
            if let checkpoint = checkpoints[turnId] {
                do {
                    let days = Set([row.ts, checkpoint.updatedAt, today].flatMap { day in
                        [day] + [-1, 1].compactMap { Self.dayCalendar.date(byAdding: .day, value: $0, to: day) }
                    }.map { lane.path(for: $0) })
                    for path in days { try readDay(path, includeAccepted: false) }
                    let hasTerminal = days.contains { terminalIndex[$0]!.terminated.contains(turnId) }
                    if hasTerminal, checkpoint.deliveryPending, !checkpoint.hasRedeliveryOwner {
                        // A finished turn whose route cannot redeliver: the retirement row
                        // lands durably (deduped) before the file goes, so a kill between the
                        // two retires it again next launch and never loses the row.
                        let retired = TurnTraceEvent(turnId: turnId, kind: "turn.checkpoint_retired",
                            sessionId: checkpoint.sessionId, surface: checkpoint.surface,
                            payload: .object(["reason": .string("no_redelivery_owner")]))
                        let wrote = try await lane.appendGuarded(retired) { current in
                            !current.split(separator: "\n").contains { $0.contains("\"turn.checkpoint_retired\"") && $0.contains(turnId) }
                        }
                        if wrote { await TurnTraceBus.shared.deliverToSubscribers(retired) }
                        try checkpoint.remove(dataRoot: dataRoot)
                        continue
                    }
                    let replyReady = checkpoint.deliveryPending
                        && days.contains { terminalIndex[$0]!.replyReady.contains(turnId) }
                    if !hasTerminal || replyReady { resumable.append(checkpoint) }
                    else { try checkpoint.remove(dataRoot: dataRoot) }
                } catch { persistenceFailures.append("Cannot check checkpoint terminal: \(error)") }
                continue
            }
            guard writeAttempts < Self.maximumWritesPerPass else {
                deferred = true
                break
            }
            writeAttempts += 1
            let minutes = Int((age / 60).rounded())
            // CHECK AND APPEND IN ONE CRITICAL SECTION. The scan above is
            // unlocked, so a real terminal can land between it and this write;
            // the guard re-reads the target day file under the lane's own
            // write lock and stands down if one did (GPT-5.6 round review,
            // 2026-09-11). A terminal always wins over an abandoned verdict.
            //
            // ACROSS DAY FILES. The guard only sees the file this row is being
            // appended to (today's). A real terminal for a turn accepted
            // yesterday evening lands in the turn's OWN day file, or in the
            // next one if it crossed local midnight — neither of which is
            // today's when the sweep runs a day later. Those are read here too,
            // so an abandoned verdict never stands next to a real terminal.
            // They are passed as `alsoLocking` so the predicate reads them
            // UNDER THEIR OWN LOCKS, inside the same critical section as the
            // append — a real terminal can no longer land between the sibling
            // read and the synthetic write (GPT-5.6 round review, 2026-09-11).
            //
            // CALENDAR DAYS, not 86_400s: across a DST transition a fixed
            // interval names the day after (or before) the real neighbour, so
            // the file the true terminal landed in would never be locked or
            // read (GPT-5.6 round review r2, 2026-09-11). Sorted so every
            // caller takes these nested locks in the same order.
            let siblingDays = Set(
                ([row.ts]
                    + [-1, 1].compactMap {
                        Self.dayCalendar.date(byAdding: .day, value: $0, to: row.ts)
                    })
                    .map { lane.path(for: $0) }
            )
            .filter { $0 != lane.path(for: today) }
            .sorted { $0.path < $1.path }
            let event = TurnTraceEvent(
                turnId: turnId,
                ts: today,
                kind: "turn.terminal",
                sessionId: row.sessionId,
                surface: row.surface,
                payload: .object([
                    "schema": .string("turn.lifecycle.v1"),
                    "status": .string("abandoned"),
                    "observedBy": .string("terminal_reconciliation"),
                    "reason": .string("abandoned: no terminal after \(minutes) minutes"),
                    "acceptedAt": .string(Self.iso8601String(row.ts)),
                ])
            )
            do {
                let wrote = try await lane.appendGuarded(
                    event,
                    alsoLocking: siblingDays,
                    shouldAppend: { current in
                        if Self.containsTerminal(forTurn: turnId, in: current) { return false }
                        for path in siblingDays {
                            // Missing sibling: nothing there. Unreadable sibling:
                            // it may hold the real terminal, so fail the sweep.
                            guard FileManager.default.fileExists(atPath: path.path) else { continue }
                            let text = try String(contentsOf: path, encoding: .utf8)
                            if Self.containsTerminal(forTurn: turnId, in: text) { return false }
                        }
                        return true
                    }
                )
                if wrote {
                    await TurnTraceBus.shared.deliverToSubscribers(event)
                    written.append(turnId)
                    if processEpoch.timeIntervalSince(row.ts) <= 3600,
                       let sessionId = row.sessionId, NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId,
                       let surface = row.surface,
                       ["telegram", "agent-bridge", "slack", "ios", "phone", "siri"].contains(surface) || sessionId.hasPrefix("agent-") {
                        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
                        if FileManager.default.fileExists(atPath: path.path) {
                            let persistence = SwiftNativePersistenceCore()
                            let note: JSONValue = .object([
                                "id": .string(UUID().uuidString.lowercased()), "sessionId": .string(sessionId),
                                "role": .string("system"), "source": .string(surface),
                                "content": .string("This reply did not finish before the app restarted."),
                                "createdAt": .string(Self.iso8601String(today)),
                                "metadata": .object(["kind": .string("interrupted_turn_note")])])
                            try await persistence.withFileLock(path) { try await persistence.appendJSONL(note, to: path) }
                        }
                    }
                }
            } catch {
                persistenceFailures.append("guarded append failed: \(error)")
                FileHandle.standardError.write(
                    Data("TurnTracePersistLane: guarded append failed (turn \(turnId)): \(error)\n".utf8)
                )
            }
        }
        // Once every eligible candidate in the days ACTUALLY SCANNED has been
        // confirmed, the cursor advances over exactly those days and no
        // further. When the backlog was longer than `maximumDayWindow` the
        // newest scanned day is not today: the unscanned remainder stays
        // behind the cursor and the next sweep continues from there, instead
        // of the old jump to today that abandoned it forever (GPT-5.6 round
        // review, 2026-09-11).
        // A failed read/append or deferred candidate leaves the window pending.
        // Already confirmed terminals make the next pass idempotent.
        if persistenceFailures.isEmpty, !deferred, let newestScannedDay = Self.dayCalendar.date(
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

    private static let lifecycleKinds = ["turn.accepted", "turn.terminal", "turn.cancelled", "turn.failed"]

    /// Day-offsets from `today` this sweep reads (0 = today), oldest offset
    /// last. Ordinarily `dayWindow` days ending today; after a gap it reaches
    /// back to the last swept day so a turn abandoned outside the ordinary
    /// window is not missed. When the gap is longer than `maximumDayWindow`
    /// the window sits at the OLD end of the backlog — the sweep drains the
    /// oldest unswept days first and the cursor advances by that much, so the
    /// next sweep continues where this one stopped rather than skipping to
    /// today.
    private func scanRange(today: Date) -> (newestOffset: Int, oldestOffset: Int) {
        // No cursor (first run, or a corrupt file) is NOT "start at today":
        // that records today as swept and strands every older trace file
        // forever, which is also the migration path for every install made
        // before the cursor existed. Start one day BEFORE the oldest day file
        // that actually exists and let the ordinary 30-day window walk
        // forward, oldest-first, over successive sweeps (GPT-5.6 round review
        // r2, 2026-09-11).
        guard let cursorDay = persistedCursorDay() ?? oldestTraceDay().flatMap({
            Self.dayCalendar.date(byAdding: .day, value: -1, to: $0)
        }) else {
            // Nothing has ever been traced. Ordinary window ending today.
            return (0, Self.dayWindow - 1)
        }
        let calendar = Self.dayCalendar
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

    /// Day arithmetic in exactly the timezone the ledger file names are
    /// formatted in. A fixed 86,400s "day" can name the wrong calendar day on
    /// a 23- or 25-hour local day, which means reading and locking the wrong
    /// ledger file.
    static let dayCalendar: Calendar = {
        var calendar = Calendar.current
        calendar.timeZone = TurnTracePersistLane.dayTimeZone
        return calendar
    }()

    private var cursorPath: URL {
        dataRoot
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("abandoned-reconciler-cursor.json")
    }

    private func writeCursor(day date: Date) {
        let dir = cursorPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = TurnTracePersistLane.dayString(from: date)
        try? Data("{\"lastSweptDay\":\"\(day)\"}".utf8).write(to: cursorPath, options: .atomic)
    }

    /// Does this JSONL text already carry a terminal row for `turnId`? The
    /// substring pre-check keeps a 20k-line day file from being parsed for a
    /// turn it never mentions.
    static func containsTerminal(forTurn turnId: String, in text: String, status: String? = nil) -> Bool {
        guard text.contains(turnId) else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains(turnId),
                  let data = String(line).data(using: .utf8),
                  let value = try? JSONValue.parse(data),
                  case .object(let row) = value,
                  case .string(let rowTurnId)? = row["turnId"],
                  rowTurnId == turnId,
                  case .string(let kind)? = row["kind"] else { continue }
            if kind == "turn.terminal" || kind == "turn.cancelled" || kind == "turn.failed" {
                if let status {
                    guard case .object(let payload)? = row["payload"], payload["status"] == .string(status) else { continue }
                }
                return true
            }
        }
        return false
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text)? = value, !text.isEmpty { return text }
        return nil
    }

    private static func iso8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
