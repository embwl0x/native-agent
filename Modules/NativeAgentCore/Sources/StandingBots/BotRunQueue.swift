import Foundation
import Darwin
import NativeAgentCore
// Blueprint: | `BotRunQueue.swift` | `BotRunQueue`; `enqueue`, `presence`, `refusal`: commit claim/refusal before removal; daily reservations |

public struct BotRunReceipt: Sendable, Equatable {
    public let runID: UUID
    public let accepted: Bool
    public let reason: String
}

/// Manual requests carry the person's authority; unattended requests recheck gates after queue waits and restarts.
public enum BotRunOrigin: String, Codable, Sendable {
    case manual, event
}

/// Keep sender identity with durable event input; nil means the sender was not recorded.
public struct BotEventProvenance: Codable, Equatable, Sendable {
    public let source: BotEventSource?
    public let verifiedChatID: String?
    public let verifiedUserID: String?

    public init(source: BotEventSource?, verifiedChatID: String? = nil, verifiedUserID: String? = nil) {
        self.source = source
        self.verifiedChatID = verifiedChatID
        self.verifiedUserID = verifiedUserID
    }

}

public enum BotRunAdmissionError: String, Error {
    case paused, alreadyRunning = "already_running"
}

/// Consume before execution to prevent interrupted work replay; all callers share admission.
public struct BotRunQueue: Sendable {
    public static let didChange = Notification.Name("StandingBots.scheduleDidChange")
    public static let alreadyExecutingWords = """
        This helper is executing its standing job now. Complete the work and return its result in this turn; do not queue or \
        wait on your own Run control.
        """
    private let disk: StandingBotsDisk
    private let dataRoot: URL
    private var path: URL { disk.root.appendingPathComponent("run-queue.json") }

    /// Commit event input with its request so it cannot reach another run of the same bot.
    struct QueuedRequest: Codable, Equatable {
        var runID: UUID
        var context: String? = nil
        var origin: BotRunOrigin
        var provenance: BotEventProvenance? = nil
        var isEvent: Bool { origin == .event }
    }
    private static let admission = Admission()

    private struct Claim: Codable {
        let requestID: UUID
        let briefVersion: Int
        let admittedAt: Date
        var executionAdmittedAt: Date? = nil
    }

    private func claimRecord(_ id: UUID) -> URL {
        disk.root.appendingPathComponent(id.uuidString).appendingPathComponent("run-claim.json")
    }

    /// Called only while holding both the store lock and this bot's writer lock.
    private func reconcileClaim(_ id: UUID, requests: inout [UUID: QueuedRequest]) throws {
        let path = claimRecord(id)
        guard let claim = try disk.read(Claim.self, at: path) else { return }
        if try refusalUnlocked(bot: id, requestID: claim.requestID) != nil {
            try FileManager.default.removeItem(at: path)
            return
        }
        let shelf = ShelfStore(dataRoot: dataRoot)
        let settled = try shelf.rawEntryLocked(claim.requestID)
        if let settled, settled.botId != id { throw StandingBotsError.corruptStore("helper claim/result identity") }
        guard settled != nil || claim.executionAdmittedAt != nil else {
            throw StandingBotsError.corruptStore("""
                Helper request \(claim.requestID) lost its pre-execution admission outcome. Restore its refusal or execution evidence; \
                no interrupted run was invented and nothing was replayed.
                """)
        }
        let detail = "Helper admission ended without a settled result. Effects are unknown; do not replay the request."
        var entry = ShelfEntry(id: claim.requestID, botId: id, briefVersion: claim.briefVersion,
            runAt: claim.admittedAt, coverageStart: claim.admittedAt, coverageEnd: claim.admittedAt,
            headline: "Interrupted helper request", findings: "", changedSinceLastGood: "",
            uncertainties: [detail], runHealth: .partial, spend: ShelfSpend(tokens: nil, seconds: 0))
        entry.status = .interrupted
        entry.statusDetail = detail
        entry.sessionID = BotDefinition.sessionID(for: id)
        if settled == nil { try shelf.appendLocked(entry) }
        if requests[id]?.runID == claim.requestID {
            requests.removeValue(forKey: id)
            try disk.write(requests, at: self.path)
        }
        try FileManager.default.removeItem(at: path)
    }

    // Serialize disk transactions with process-wide claims to prevent double admission.
    private final class Admission: @unchecked Sendable {
        let lock = NSLock()
        var active: [String: [UUID: (descriptor: Int32, done: ScopedWaiter)]] = [:]
    }

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
        disk = StandingBotsDisk(dataRoot: self.dataRoot)
    }

    private var rootKey: String { dataRoot.resolvingSymlinksInPath().path }

    /// Event context is run input, never authority to instruct the app.
    public func enqueue(bot id: UUID, context: String? = nil,
                        origin: BotRunOrigin = .manual,
                        provenance: BotEventProvenance? = nil, scope: BotRunScope) throws -> BotRunReceipt {
        guard !scope.ancestry.contains(id) else {
            throw StandingBotsError.invalidValue(Self.alreadyExecutingWords)
        }
        let receipt: BotRunReceipt
        do {
            Self.admission.lock.lock()
            defer { Self.admission.lock.unlock() }
            receipt = try disk.locked {
                let bot = try disk.definition(id).definition
                guard bot.deleted != true else { throw StandingBotsError.notFound(id) }
                var requests = try readRequests()
                if origin == .manual, Self.admission.active[rootKey]?[id] != nil {
                    guard let claim = try disk.read(Claim.self, at: claimRecord(id)) else {
                        throw StandingBotsError.corruptStore("exact bot run claim unavailable")
                    }
                    return BotRunReceipt(runID: claim.requestID, accepted: false, reason: BotRunAdmissionError.alreadyRunning.rawValue)
                }
                if let existing = requests[id] {
                    return BotRunReceipt(runID: existing.runID, accepted: false, reason: BotRunAdmissionError.alreadyRunning.rawValue)
                }
                let runID = UUID()
                let text = (context?.isEmpty ?? true) ? nil : context
                requests[id] = QueuedRequest(runID: runID, context: text, origin: origin, provenance: provenance)
                try disk.write(requests, at: path)
                return BotRunReceipt(runID: runID, accepted: true, reason: "queued")
            }
        }
        if receipt.accepted { NotificationCenter.default.post(name: Self.didChange, object: dataRoot) }
        return receipt
    }

    /// Inside the store lock. Present bytes must be the current request map.
    private func readRequests() throws -> [UUID: QueuedRequest] {
        let saved = try disk.read([UUID: QueuedRequest].self, at: path) ?? [:]
        // Commit refusals before removal so a crash cannot make refused work executable.
        return try saved.filter { try refusalUnlocked(bot: $0.key, requestID: $0.value.runID) == nil }
    }

    func pending() throws -> [UUID: QueuedRequest] {
        try disk.locked {
            var requests = try readRequests()
            for directory in try disk.files(at: disk.root, extension: "") {
                guard let id = UUID(uuidString: directory.lastPathComponent),
                      try disk.bytes(at: claimRecord(id)) != nil else { continue }
                let lock = directory.appendingPathComponent("run.lock")
                try disk.validatePath(lock)
                let fd = open(lock.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard fd >= 0 else { throw StandingBotsError.corruptStore("bot run claim unavailable") }
                defer { close(fd) }
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { try reconcileClaim(id, requests: &requests) }
                else if errno != EWOULDBLOCK { throw StandingBotsError.corruptStore("bot run claim unavailable") }
            }
            return requests
        }
    }

    public func activeOrQueuedIDs(locked: Bool = true) throws -> Set<UUID> {
        let ids = try activeAndQueuedIDs(locked: locked)
        return ids.active.union(ids.queued)
    }

    public func activeAndQueuedIDs(locked: Bool = true) throws -> (active: Set<UUID>, queued: Set<UUID>) {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        // Unlocked: a read-only look at the queue file for a glance that must not wait.
        let queued = locked ? try pending() : try readRequests()
        return (Set(Self.admission.active[rootKey]?.keys.map { $0 } ?? []), Set(queued.keys))
    }

    /// The shelf's active rows carry their writer admission time, never a guessed clock time from a view.
    public func shelfRuns() throws -> (active: Set<UUID>, queued: Set<UUID>, started: [UUID: Date], issues: [UUID: String]) {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        let queued = try pending()
        let active = Set(Self.admission.active[rootKey]?.keys.map { $0 } ?? [])
        var started: [UUID: Date] = [:]
        var issues: [UUID: String] = [:]
        for id in active {
            do {
                guard let claim = try disk.read(Claim.self, at: claimRecord(id)) else {
                    throw StandingBotsError.corruptStore("active helper start evidence unavailable")
                }
                started[id] = claim.admittedAt
            } catch {
                issues[id] = "This helper's start record is unavailable: \(error). Preserve and repair its run-claim.json."
            }
        }
        return (active, Set(queued.keys), started, issues)
    }

    public enum RequestPresence: Sendable { case queued, running, deadlineExceeded, absent }

    func admitExecution(bot id: UUID, requestID: UUID) throws {
        try disk.locked {
            guard var claim = try disk.read(Claim.self, at: claimRecord(id)), claim.requestID == requestID else {
                throw StandingBotsError.corruptStore("exact helper execution claim unavailable")
            }
            claim.executionAdmittedAt = Date()
            try disk.write(claim, at: claimRecord(id))
        }
    }

    /// Absence is definitive only when neither the exact queue entry nor a live writer owns its settlement.
    public func presence(bot id: UUID, requestID: UUID) throws -> RequestPresence {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        return try disk.locked {
            var requests = try readRequests()
            let claim = disk.root.appendingPathComponent(id.uuidString).appendingPathComponent("run.lock")
            try disk.validatePath(claim)
            let fd = open(claim.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if fd < 0 {
                if errno == ENOENT { return requests[id]?.runID == requestID ? .queued : .absent }
                throw StandingBotsError.corruptStore("bot run claim unavailable")
            }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                try reconcileClaim(id, requests: &requests)
                return requests[id]?.runID == requestID ? .queued : .absent
            }
            if errno == EWOULDBLOCK {
                if let saved = try disk.read(Claim.self, at: claimRecord(id)), saved.requestID == requestID {
                    return .running
                }
                return requests[id]?.runID == requestID ? .queued : .absent
            }
            throw StandingBotsError.corruptStore("bot run claim unavailable")
        }
    }

    func rejectPending(bot: UUID, requestID: UUID, detail: String) throws {
        try disk.locked {
            var requests = try readRequests()
            if requests[bot]?.runID == requestID {
                try recordRefusal(bot: bot, requestID: requestID, detail: detail)
                requests.removeValue(forKey: bot)
                try disk.write(requests, at: path)
            }
        }
    }

    struct ClaimedRun {
        let runID: UUID
        let bot: BotDefinition
        let context: String?
        let provenance: BotEventProvenance?
    }

    func claim(bot id: UUID, requestID: UUID?, manual: Bool = false) throws -> ClaimedRun {
        let run = try admit(bot: id, runID: requestID, manual: manual)
        NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
        return run
    }

    func claimWhenAvailable(bot id: UUID, requestID: UUID?, manual: Bool = false, scope: BotRunScope) async throws -> ClaimedRun {
        // Waiting on a run this task is already inside can only ever time out.
        guard !scope.ancestry.contains(id) else { throw BotRunAdmissionError.alreadyRunning }
        while true {
            try Task.checkCancellation()
            do { return try claim(bot: id, requestID: requestID, manual: manual) }
            catch BotRunAdmissionError.alreadyRunning {
                guard scope.ancestry.isEmpty else {
                    throw StandingBotsError.invalidValue("""
                        This helper is already running. A running helper cannot wait for another active helper; continue without waiting.
                        """)
                }
                // Select the execution under admission; finish may resolve it before parking.
                guard let waiter = Self.admission.lock.withLock({ Self.admission.active[rootKey]?[id]?.done }) else {
                    try Task.checkCancellation()
                    return try claim(bot: id, requestID: requestID, manual: manual)
                }
                await waiter.park()
            }
        }
    }

    private func admit(bot id: UUID, runID: UUID?, manual: Bool = false) throws -> ClaimedRun {
        Self.admission.lock.lock()
        defer { Self.admission.lock.unlock() }
        return try disk.locked {
            var requests = try readRequests()
            guard Self.admission.active[rootKey]?[id] == nil,
                  requests[id] == nil || manual || requests[id]?.runID == runID else {
                throw BotRunAdmissionError.alreadyRunning
            }
            // Keep the flock inode stable: kernel-held ownership survives slow writers and releases on process exit.
            let claimPath = disk.root.appendingPathComponent(id.uuidString).appendingPathComponent("run.lock")
            try disk.validatePath(claimPath)
            try FileManager.default.createDirectory(at: claimPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(claimPath.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw StandingBotsError.corruptStore("bot run claim unavailable") }
            var retained = false
            defer { if !retained { close(descriptor) } }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw BotRunAdmissionError.alreadyRunning }
                throw StandingBotsError.corruptStore("bot run claim unavailable")
            }
            try reconcileClaim(id, requests: &requests)
            let bot = try disk.definition(id).definition
            // Consume refused requests too, so a later settings edit cannot replay them.
            var context: String? = nil
            var provenance: BotEventProvenance? = nil
            if let runID, requests[id]?.runID != runID { throw BotRunAdmissionError.alreadyRunning }
            let admittedID = runID ?? UUID()
            if runID != nil {
                // Retain the durable request until its successor claim or refusal commits.
                let request = requests[id]
                context = request?.context
                if request?.isEvent == true {
                    provenance = request?.provenance ?? BotEventProvenance(source: nil)
                }
            }
            // A queued deliberate check is independent of scheduled checks.
            guard !bot.paused || runID != nil || manual else { throw BotRunAdmissionError.paused }
            guard bot.deleted != true else {
                try recordRefusal(bot: id, requestID: admittedID, detail: "The helper was deleted before execution. No helper turn ran.")
                if runID != nil {
                    requests.removeValue(forKey: id)
                    try disk.write(requests, at: path)
                }
                throw StandingBotsError.notFound(id)
            }
            let metadata = Data("\(getpid()) \(Date().timeIntervalSince1970)\n".utf8)
            guard ftruncate(descriptor, 0) == 0,
                  metadata.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == metadata.count else {
                throw StandingBotsError.corruptStore("bot run claim metadata unavailable")
            }
            try disk.write(Claim(requestID: admittedID, briefVersion: bot.briefVersion, admittedAt: Date()),
                           at: claimRecord(id))
            if runID != nil {
                // Failed claim writes preserve the queue; later failures preserve the exact claim and never authorize replay.
                requests.removeValue(forKey: id)
                try disk.write(requests, at: path)
            }
            Self.admission.active[rootKey, default: [:]][id] = (descriptor, ScopedWaiter())
            retained = true
            return ClaimedRun(runID: admittedID, bot: bot, context: context, provenance: provenance)
        }
    }

    /// Keep the writer lock through exact pre-execution refusal settlement; no unknown effects need reconciliation.
    func retireUnstartedClaim(bot id: UUID, requestID: UUID, detail: String) throws {
        try disk.locked {
            guard let claim = try disk.read(Claim.self, at: claimRecord(id)), claim.requestID == requestID else {
                throw StandingBotsError.corruptStore("exact refused helper claim unavailable: \(requestID)")
            }
            try recordRefusal(bot: id, requestID: requestID, detail: detail)
            try FileManager.default.removeItem(at: claimRecord(id))
        }
    }

    private struct Refusal: Codable { let botID: UUID; let requestID: UUID; let detail: String }
    private func refusalPath(bot: UUID, requestID: UUID) -> URL {
        disk.root.appendingPathComponent(bot.uuidString).appendingPathComponent("refused")
            .appendingPathComponent(requestID.uuidString + ".json")
    }
    private func recordRefusal(bot: UUID, requestID: UUID, detail: String) throws {
        try disk.write(Refusal(botID: bot, requestID: requestID, detail: detail), at: refusalPath(bot: bot, requestID: requestID))
    }
    private func refusalUnlocked(bot: UUID, requestID: UUID) throws -> String? {
        guard let row = try disk.read(Refusal.self, at: refusalPath(bot: bot, requestID: requestID)) else { return nil }
        guard row.botID == bot, row.requestID == requestID else { throw StandingBotsError.corruptStore("refused helper request identity") }
        return row.detail
    }
    /// Missing settlement evidence says nothing about execution; only a positive refusal can retire it.
    public func refusal(bot: UUID, requestID: UUID) throws -> String? {
        try disk.locked { try refusalUnlocked(bot: bot, requestID: requestID) }
    }

    func finish(bot id: UUID) {
        Self.admission.lock.lock()
        defer {
            Self.admission.lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: dataRoot)
        }
        let execution = Self.admission.active[rootKey]?.removeValue(forKey: id)
        if let execution { close(execution.descriptor) }
        if Self.admission.active[rootKey]?.isEmpty == true {
            Self.admission.active.removeValue(forKey: rootKey)
        }
        execution?.done.resume()
    }

    /// Cross-process spend admission precedes effects; unreadable state must not reset the allowance.
    func reserveDailySpend(tokens: Int, bot: UUID, ceiling: Int, at now: Date = Date()) throws {
        struct Spend: Codable { var day: Int; var tokens: Int }
        try disk.locked {
            let path = disk.root.appendingPathComponent(bot.uuidString).appendingPathComponent("daily-spend.json")
            guard let day = Int(exactly: floor(now.timeIntervalSince1970 / 86_400)) else {
                throw StandingBotsError.corruptStore("daily spend date")
            }
            let saved = try disk.read(Spend.self, at: path)
            if let saved, saved.tokens < 0 {
                throw StandingBotsError.corruptStore("daily spend")
            }
            // A backwards wall-clock change must not mint another allowance.
            var spend = saved ?? Spend(day: day, tokens: 0)
            if day > spend.day { spend = Spend(day: day, tokens: 0) }
            let remaining = ceiling.subtractingReportingOverflow(spend.tokens)
            guard tokens > 0, !remaining.overflow, tokens <= remaining.partialValue else {
                throw BotRunnerError.dailySpendLimit
            }
            let total = spend.tokens.addingReportingOverflow(tokens)
            guard !total.overflow else { throw StandingBotsError.corruptStore("daily spend overflow") }
            spend.tokens = total.partialValue
            try disk.write(spend, at: path)
        }
    }
}
