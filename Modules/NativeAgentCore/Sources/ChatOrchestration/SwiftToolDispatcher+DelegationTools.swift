import Foundation
import PersistenceCore
import SwarmRuns

// MARK: - delegation_status (W2, upgrade campaign 2026-08 Track A)
//
// The read side of the delegation loop. `claude_message` / `codex_message`
// enqueue work; until now nothing in Swift could READ the resulting job
// records, so the window between enqueue and the terminal bridge event was
// dark. This tool is that window's instrument: a pure local read over the two
// wake-job stores, no writes, no process spawn, no network.
//
// Wiring canon (same as task_ledger_list / workshop_status): catalog-visible +
// builtInToolNames, LAZY-LOADED (NOT alwaysOnCoreNames), `safe_read`/.low in
// SecurityCenter. It is NOT a notification-tier tool — nothing leaves the
// machine, so the external_send carve-out does not apply.

extension SwiftToolDispatcher {

    /// delegation_status — list the newest delegated jobs across the Claude
    /// Claude, Codex, and OMP wake-job stores with their real lifecycle timestamps.
    ///
    /// Read-only. Store roots come from `agentBridgeConfigRoot` (the same
    /// injection point `claude_message` uses), so tests never touch the live
    /// `~/.config`.
    func impl_delegation_status(input: [String: JSONValue]) async throws -> JSONValue {
        if case .string(let agent)? = input["agent"], agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "swarm" {
            return inspectRetainedSwarm(input: input)
        }
        let messageID: String?
        switch input["message_id"] {
        case nil, .null: messageID = nil
        case .string(let raw):
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count <= 160 else { return Self.invalidDelegationMessageLookup() }
            messageID = value.isEmpty ? nil : value
        default: return Self.invalidDelegationMessageLookup()
        }
        let projector = DelegationStatusProjector(configRoot: agentBridgeConfigRoot)
        let limit = Self.delegationStatusLimit(input)
        let offset = Self.delegationStatusOffset(input)
        let agentFilter = Self.delegationStatusAgentFilter(input)
        let fullDetail = Self.delegationStatusFullDetail(input)

        // Clock injection lives one layer down, on the projector: elapsed and
        // stall arithmetic is what needs a deterministic `now`, and threading a
        // mutable clock through the dispatcher would be process-global test
        // state. Tests drive `DelegationStatusProjector.recentJobs(now:)`
        // directly with a pinned date.
        let snapshot = projector.readSnapshot(now: Date())
        var matchingJobs = snapshot.jobs
        if let agentFilter {
            matchingJobs = matchingJobs.filter { $0.agent == agentFilter }
        }
        if let messageID {
            matchingJobs = matchingJobs.filter { $0.acceptedMessageIDs.contains(messageID) }
        }
        let sources = snapshot.sources.filter { agentFilter == nil || $0.agent == agentFilter }
        let evidenceStatus: String
        if sources.allSatisfy({ $0.status == "absent" }) {
            evidenceStatus = "no_evidence"
        } else if sources.contains(where: { $0.status == "partial" || $0.status == "unavailable" }) {
            evidenceStatus = sources.contains(where: { $0.status == "available" || $0.status == "partial" })
                ? "partial" : "unavailable"
        } else {
            evidenceStatus = "ok"
        }
        // Filtering after the former global top-20 window could hide an
        // agent's older jobs entirely. Filter the complete ordered projection,
        // then take a compact provider-facing page.
        let jobs = Array(matchingJobs.dropFirst(min(offset, matchingJobs.count)).prefix(limit))

        let stalled = jobs.filter { $0.stalled }
        let open = jobs.filter { $0.completedAt == nil }
        let runtimeRevision: String? = {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: "NativeAgentSourceRevision") as? String else {
                return nil
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.count == 40 && value.allSatisfy(\.isHexDigit) ? value : nil
        }()
        let currentBuild = jobs.filter {
            guard let runtimeRevision else { return false }
            return $0.producerSourceRevision?.lowercased() == runtimeRevision
        }
        let legacyOrOther = jobs.filter { job in
            guard let runtimeRevision else { return true }
            return job.producerSourceRevision?.lowercased() != runtimeRevision
        }
        var response: [String: JSONValue] = [
            "status": .string(evidenceStatus),
            "source_availability": .array(sources.map(\.json)),
            "projection_schema_version": .int(2),
            "count": .int(Int64(jobs.count)),
            "matched_count": .int(Int64(matchingJobs.count)),
            "returned_count": .int(Int64(jobs.count)),
            "offset": .int(Int64(offset)),
            "has_more": .bool(offset + jobs.count < matchingJobs.count),
            "detail": .string(fullDetail ? "full" : "compact"),
            "open_count": .int(Int64(open.count)),
            "stalled_count": .int(Int64(stalled.count)),
            // PROVEN lost (the record says so) is counted separately from
            // UNKNOWN (the bridge could not confirm). Folding them together
            // would turn "we don't know" into "it failed".
            "delivery_lost_count": .int(Int64(jobs.filter { $0.deliveryOutcome == "lost" }.count)),
            "delivery_unknown_count": .int(Int64(jobs.filter { $0.deliveryOutcome == "unknown" }.count)),
            "current_build_count": .int(Int64(currentBuild.count)),
            "current_build_delivery_unknown_count": .int(Int64(currentBuild.filter { $0.deliveryOutcome == "unknown" }.count)),
            "legacy_or_other_build_count": .int(Int64(legacyOrOther.count)),
            "legacy_or_other_build_delivery_unknown_count": .int(Int64(legacyOrOther.filter { $0.deliveryOutcome == "unknown" }.count)),
            "jobs": .array(jobs.map { job in
                let value = fullDetail ? job.toJSON() : job.toCompactJSON()
                guard let messageID, case .object(var object) = value else { return value }
                object["matched_message_id"] = .string(messageID)
                if let threadID = job.recordedThreadID { object["thread_id"] = .string(threadID) }
                if let turnID = job.recordedTurnID { object["turn_id"] = .string(turnID) }
                return .object(object)
            }),
            // Naming the stores in the envelope keeps a "no jobs" answer
            // honest: an empty list because the directory is absent reads
            // very differently from an empty list because nothing is queued.
            // Home-relative, never absolute (gpt-5.5 BLOCKING: an absolute
            // path leaks the account name into model-visible output on
            // public installs).
            "stores": .object([
                "claude": .string(Self.homeRelativePath(projector.claudeJobsDirectory)),
                "codex": .string(Self.homeRelativePath(projector.codexJobsDirectory)),
                "omp": .string(Self.homeRelativePath(projector.ompJobsDirectory)),
            ]),
            "note": .string("Read-only wake-job projection. Source availability distinguishes readable empty stores, absent evidence, and skipped unreadable/malformed records. Readable jobs are retained; an empty or partial projection never proves no work exists. `none` stall basis is unmeasurable, not verified healthy; unknown delivery is not proven lost. Build counts describe this returned page."),
        ]
        if offset + jobs.count < matchingJobs.count {
            response["next_offset"] = .int(Int64(offset + jobs.count))
        }
        if let messageID {
            response["message_id"] = .string(messageID)
            response["lookup_status"] = .string(matchingJobs.isEmpty ? "not_observed" : "matched")
            response["lookup_note"] = .string("Matches recorded accepted-message IDs only. A missing match does not prove no execution: queued, unreadable, or no-longer-retained work may not be represented. Internal job IDs remain unchanged.")
        }
        if let runtimeRevision { response["runtime_source_revision"] = .string(runtimeRevision) }
        return .object(response)
    }

    private static func invalidDelegationMessageLookup() -> JSONValue {
        .object(["status": .string("failed"), "reason": .string("delegation_message_id_invalid"),
                 "note": .string("Pass the exact messageId returned by a builder message, at most 160 characters. Omit, null, or empty lists bridge jobs. This is an identifier, never a path; no work was started.")])
    }

    private func inspectRetainedSwarm(input: [String: JSONValue]) -> JSONValue {
        func invalid(_ reason: String) -> JSONValue {
            .object(["status": .string("failed"), "reason": .string(reason),
                     "note": .string("Swarm inspection requires an exact run_id; select report_id from its metadata to page retained text. No work was started.")])
        }
        guard case .string(let rawID)? = input["run_id"] else { return invalid("swarm_run_id_required") }
        let runID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runID.isEmpty, runID.count <= 160 else { return invalid("swarm_run_id_invalid") }
        let reportID: String?
        switch input["report_id"] {
        case nil, .null: reportID = nil
        case .string(let raw):
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count <= 160 else { return invalid("swarm_report_id_invalid") }
            reportID = value.isEmpty ? nil : value
        default: return invalid("swarm_report_id_invalid")
        }
        func number(_ value: JSONValue?, fallback: Int) -> Int? {
            switch value {
            case nil, .null: return fallback
            case .int(let value): return Int(exactly: value)
            case .double(let value): return value.isFinite ? Int(exactly: value.rounded(.towardZero)) : nil
            case .string(let value): return Int(value)
            default: return nil
            }
        }
        guard let offset = number(input["offset"], fallback: 0), let limit = number(input["limit"], fallback: 2_000) else {
            return invalid("swarm_pagination_invalid")
        }
        return SwiftNativeSwarmRunsReader(runsPath: dataRoot.appendingPathComponent("swarms/runs.json"))
            .inspectSwarm(runID: runID, reportID: reportID, offset: offset, limit: limit)
    }

    static func delegationStatusLimit(_ input: [String: JSONValue]) -> Int {
        let raw: Int?
        switch input["limit"] {
        case .some(.int(let i)): raw = Int(exactly: i)
        case .some(.double(let d)): raw = d.isFinite ? Int(exactly: d.rounded(.towardZero)) : nil
        case .some(.string(let s)): raw = Int(s)
        default: raw = nil
        }
        guard let raw else { return 8 }
        return max(1, min(raw, 12))
    }

    static func delegationStatusOffset(_ input: [String: JSONValue]) -> Int {
        let raw: Int?
        switch input["offset"] {
        case .some(.int(let value)): raw = Int(exactly: value)
        case .some(.double(let value)): raw = value.isFinite ? Int(exactly: value.rounded(.towardZero)) : nil
        case .some(.string(let value)): raw = Int(value)
        default: raw = nil
        }
        return max(0, raw ?? 0)
    }

    static func delegationStatusFullDetail(_ input: [String: JSONValue]) -> Bool {
        guard case .string(let raw)? = input["detail"] else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "full"
    }

    static func delegationStatusAgentFilter(_ input: [String: JSONValue]) -> String? {
        guard case .string(let s)? = input["agent"] else { return nil }
        let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // "all"/"" mean no filter. An unrecognized value falls through to no
        // filter too — silently returning zero rows for a typo'd agent name
        // would look like "nothing is running".
        switch normalized {
        case "claude", "claude": return "claude"
        case "codex": return "codex"
        case "omp", "kimi": return "omp"
        default: return nil
        }
    }
}

extension SwiftToolDispatcher {
    /// Model-visible store labels are home-relative: "~/x/y" for anything
    /// under the user's home, last-two-components fallback otherwise.
    static func homeRelativePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return url.pathComponents.suffix(2).joined(separator: "/")
    }
}
