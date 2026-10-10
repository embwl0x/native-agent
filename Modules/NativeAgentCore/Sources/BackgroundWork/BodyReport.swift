import Foundation
import NativeAgentCore
import PersistenceCore
import BackgroundLoops
import AgentWorkspace
import AgentConversations
import MemoryV2
import TurnTrace
import Desk
import DoctorChecks

/// The body's last day, read deterministically from the files the organs
/// already write: the daily note on the standing harness item, Doctor's
/// owners and the heartbeat assessment all read this one projection.
public struct BodyReport: Sendable, Equatable {
    /// The day the report is written for (yyyy-MM-dd, local).
    public var day: String
    /// Runs that ended without their exit row and were relaunched in the last
    /// day; the newest one's relaunch and how it ended ("signal 05", "killed").
    public var crashes: Int
    public var lastCrash: Date?
    public var lastCrashCause: String?
    public var loopFailures: Int
    /// Loops whose pulse is past due.
    public var overdueOrgans: [String]
    /// Agent peers whose local health reads broken or unverified.
    public var peersBroken: [String]
    /// First replies slower than `slowFirstReplySeconds`.
    public var slowFirstReplies: Int
    public var slowFirstReplySeconds: Int
    /// Stream-guard cuts by provider.
    public var noReplyCuts: [String: Int]
    public var misses: Int
    public var jobsRetired: Int
    public var repairsDone: Int
    /// Open harness findings, newest first (the standing Body item excluded).
    public var openHarness: [DeskItem]
    /// Counts read from a log with damaged rows ("loop failures", "jobs retired",
    /// "repairs done"): a floor, not a clean count.
    public var incomplete: [String] = []
    /// Files that could not be read ("pulses", "peer health"): their lists are
    /// unknown, not empty.
    public var unavailable: [String] = []
    /// Doctor's adverse rows in its last report by who heals them; rows for a
    /// person reading Doctor (heartbeat-ineligible) stay out.
    public var doctorOwners: [DoctorOwner: [String]] = [:]
    /// The day's finished turns and their median model rounds (nil with none).
    public var turns = 0
    public var roundsP50: Int?

    /// About the slowest tenth of first replies (10-07..10-10: median 6 s, p90 29 s).
    public static let slowFirstReplySeconds = 30
    /// The crash breadcrumbs: a launch row opens each run, the exit row closes
    /// a clean one, a fatal-signal row names a crash; nothing after the launch
    /// row is a SIGKILL.
    public static func crashBreadcrumbs(_ dataRoot: URL) -> URL { dataRoot.appendingPathComponent("logs/crash-breadcrumbs.log") }
    public static let launchMark = "NativeAgent launched "

    /// The day before `now`, from the files as they stand.
    public static func read(dataRoot: URL, now: Date = Date()) async throws -> BodyReport {
        let since = now.addingTimeInterval(-86_400)
        func inDay(_ date: Date?) -> Bool { date.map { $0 > since && $0 <= now } ?? false }
        var incomplete: [String] = [], unavailable: [String] = []
        func rows(_ path: String, stamp: String, name: String) async throws -> [[String: JSONValue]] {
            let read = try await SwiftNativePersistenceCore().readJSONLReporting(dataRoot.appendingPathComponent(path))
            if read.report.malformedLineCount > 0 { incomplete.append(name) }
            return read.rows.compactMap { row in
                guard case .object(let object) = row, case .string(let at)? = object[stamp],
                      inDay(NativeTimestampFormat.parseISO8601(at)) else { return nil }
                return object
            }
        }

        // Runs, oldest first; the last is the one still running.
        let crumbs = crashBreadcrumbs(dataRoot)
        var runs: [(at: Date, end: String?)] = []
        for line in FileManager.default.fileExists(atPath: crumbs.path)
            ? try String(contentsOf: crumbs, encoding: .utf8).split(separator: "\n") : [] {
            if line.hasPrefix(launchMark), let at = NativeTimestampFormat.parseISO8601(String(line.dropFirst(launchMark.count))) {
                runs.append((at, nil))
            } else if !runs.isEmpty, runs[runs.count - 1].end == nil {
                if line.hasPrefix("NativeAgent exited") { runs[runs.count - 1].end = "exited" }
                if line.hasPrefix("NativeAgent fatal signal ") { runs[runs.count - 1].end = String(line.dropFirst("NativeAgent fatal ".count)) }
            }
        }
        let crashed = zip(runs, runs.dropFirst()).filter { run, relaunch in run.end != "exited" && inDay(relaunch.at) }

        let launchedAt = runs.last?.at ?? .distantPast
        // An unreadable file is unknown, never an empty, healthy list.
        let loopState = dataRoot.appendingPathComponent("logs/background_loop_state.json")
        if FileManager.default.fileExists(atPath: loopState.path),
           (try? JSONSerialization.jsonObject(with: Data(contentsOf: loopState))) as? [String: Any] == nil {
            unavailable.append("pulses")
        }
        let pulses: [OrganPulse] = unavailable.contains("pulses") ? []
            : Array(await SwiftNativeLoopScheduler.readLoopState(loopState).pulses.values)

        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        var health: [String: AgentLocalHealth] = [:]
        if FileManager.default.fileExists(atPath: AgentLocalHealth.url(dataRoot).path) {
            do { health = try JSONDecoder().decode([String: AgentLocalHealth].self, from: Data(contentsOf: AgentLocalHealth.url(dataRoot))) }
            catch { unavailable.append("peer health") }
        }
        let broken = health.filter(\.value.isBroken).keys.map { agent in
            peers.first { "peer:" + $0.id == agent }?.name ?? agent
        }

        let events = try await TurnTraceRecentReader(dataRootOverride: dataRoot).read(now: now, since: since).events
        var accepted: [String: Date] = [:], firstDelta: [String: Date] = [:]
        for event in events {
            switch event.kind {
            case "turn.accepted": accepted[event.turnId] = accepted[event.turnId] ?? event.ts
            case "provider.firstDelta": firstDelta[event.turnId] = firstDelta[event.turnId] ?? event.ts
            default: break
            }
        }
        // The call ledger holds every cut, a background call's (no turn) too.
        var cuts: [String: Int] = [:]
        for row in try await rows("traces/events.jsonl", stamp: "createdAt", name: "no-reply cuts")
        where row["kind"] == .string("provider.noReply") {
            if case .string(let provider)? = row["title"] { cuts[provider, default: 0] += 1 }
        }
        let rounds = TurnTraceRecentReader.rounds(events).map(\.rounds)
        let slow = firstDelta.count { turn, first in
            accepted[turn].map { first.timeIntervalSince($0) > Double(slowFirstReplySeconds) } ?? false
        }

        let weeks = [MemoryStatusProjection.isoWeek(now), MemoryStatusProjection.isoWeek(now, ago: 1)]
        let misses = try await MemoryStatusProjection.misses(dataRoot: dataRoot, weeks: weeks)
            .flatMap(\.misses).count { inDay(NativeTimestampFormat.parseISO8601($0.at)) }

        let loopFailures = try await rows("logs/background_loop_failures.jsonl", stamp: "createdAt", name: "loop failures").count
        let retired = try await rows("scheduler/retired.jsonl", stamp: "at", name: "jobs retired").count
        // Only repairs that changed something (Doctor's own completion verbs), not inspections.
        let repairs = DoctorSafeRepairPolicy.appliedRepairCount(in: try await rows(
            "doctor/repair_receipts.jsonl", stamp: "at", name: "repairs done").map { row in
            let receipt: String = if case .string(let text)? = row["receipt"] { text } else { "" }
            return CheckResult(id: "", title: "", status: "", detail: receipt, receipt: receipt)
        })
        struct DoctorSnapshot: Decodable { let checks: [CheckResult] }
        let latest = dataRoot.appendingPathComponent("doctor/latest.json")
        var doctorOwners: [DoctorOwner: [String]] = [:]
        for row in FileManager.default.fileExists(atPath: latest.path)
            ? try JSONDecoder().decode(DoctorSnapshot.self, from: Data(contentsOf: latest)).checks : []
        where DoctorHeartbeatPolicy.isEligible(row.id) {
            if let owner = DoctorOwner.of(row, repairAvailable: row.repair_available == true) {
                doctorOwners[owner, default: []].append(row.id)
            }
        }

        let day = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return BodyReport(
            day: String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0),
            crashes: crashed.count, lastCrash: crashed.last?.1.at,
            lastCrashCause: crashed.last.map { $0.0.end ?? "killed" },
            loopFailures: loopFailures,
            overdueOrgans: pulses.filter { $0.isOverdue(now: now, launchedAt: launchedAt) }.map(\.organ).sorted(),
            peersBroken: broken.sorted(),
            slowFirstReplies: slow, slowFirstReplySeconds: slowFirstReplySeconds,
            noReplyCuts: cuts, misses: misses,
            jobsRetired: retired, repairsDone: repairs,
            openHarness: HarnessQueue.open(try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState()),
            incomplete: incomplete, unavailable: unavailable,
            doctorOwners: doctorOwners,
            turns: rounds.count, roundsP50: TurnTraceRecentReader.percentile(rounds, 0.5)
        )
    }

    /// The note on the standing Body item.
    public var note: String {
        "Body report \(day): crashes \(crashes)"
            + (lastCrash.map { " (last relaunch \($0.formatted(.iso8601)), \(lastCrashCause ?? "killed"))" } ?? "")
            + ", loop failures \(loopFailures), \(organsLine)"
            + (unavailable.contains("peer health") ? ", peers broken/unverified: peer health unreadable"
                : ", peers broken/unverified [\(peersBroken.joined(separator: ", "))]")
            + ", slow first replies \(slowFirstReplies) (>\(slowFirstReplySeconds)s), no-reply cuts \(noReplyCuts.values.reduce(0, +))"
            + (noReplyCuts.isEmpty ? "" : " [\(noReplyCuts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))]")
            + ", misses \(misses), jobs retired \(jobsRetired), repairs done \(repairsDone)"
            + ", rounds per turn p50 \(roundsP50.map(String.init) ?? "none") over \(turns) turns"
            + (incomplete.isEmpty ? "" : " (incomplete: \(incomplete.joined(separator: ", ")))")
    }

    /// The overdue organs, or that the pulses could not be read.
    public var organsLine: String {
        unavailable.contains("pulses") ? "organs overdue: pulses unreadable"
            : "organs overdue [\(overdueOrgans.joined(separator: ", "))]"
    }

    /// Today's report on the standing Body item, once a day.
    public static func writeDaily(dataRoot: URL, now: Date = Date()) async throws {
        let report = try await read(dataRoot: dataRoot, now: now)
        let body = try await HarnessQueue.standing(dataRoot: dataRoot)
        try await SwiftNativeDeskStore(dataRoot: dataRoot)
            .appendNoteIfAbsent(body.handle, marker: "Body report \(report.day):", text: report.note)
    }
}
