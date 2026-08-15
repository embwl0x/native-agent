import Foundation
import PersistenceCore

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
    /// and Codex wake-job stores with their real lifecycle timestamps.
    ///
    /// Read-only. Store roots come from `agentBridgeConfigRoot` (the same
    /// injection point `claude_message` uses), so tests never touch the live
    /// `~/.config`.
    func impl_delegation_status(input: [String: JSONValue]) async throws -> JSONValue {
        let projector = DelegationStatusProjector(configRoot: agentBridgeConfigRoot)
        let limit = Self.delegationStatusLimit(input)
        let agentFilter = Self.delegationStatusAgentFilter(input)

        // Clock injection lives one layer down, on the projector: elapsed and
        // stall arithmetic is what needs a deterministic `now`, and threading a
        // mutable clock through the dispatcher would be process-global test
        // state. Tests drive `DelegationStatusProjector.recentJobs(now:)`
        // directly with a pinned date.
        var jobs = projector.recentJobs(now: Date(), limit: limit)
        if let agentFilter {
            jobs = jobs.filter { $0.agent == agentFilter }
        }

        let stalled = jobs.filter { $0.stalled }
        let open = jobs.filter { $0.completedAt == nil }
        return .object([
            "status": .string("ok"),
            "count": .int(Int64(jobs.count)),
            "open_count": .int(Int64(open.count)),
            "stalled_count": .int(Int64(stalled.count)),
            // PROVEN lost (the record says so) is counted separately from
            // UNKNOWN (the bridge could not confirm). Folding them together
            // would turn "we don't know" into "it failed".
            "delivery_lost_count": .int(Int64(jobs.filter { $0.deliveryOutcome == "lost" }.count)),
            "delivery_unknown_count": .int(Int64(jobs.filter { $0.deliveryOutcome == "unknown" }.count)),
            "jobs": .array(jobs.map { $0.toJSON() }),
            // Naming the stores in the envelope keeps a "no jobs" answer
            // honest: an empty list because the directory is absent reads
            // very differently from an empty list because nothing is queued.
            // Home-relative, never absolute (gpt-5.5 BLOCKING: an absolute
            // path leaks the account name into model-visible output on
            // public installs).
            "stores": .object([
                "claude": .string(Self.homeRelativePath(projector.claudeJobsDirectory)),
                "codex": .string(Self.homeRelativePath(projector.codexJobsDirectory)),
            ]),
            "note": .string("Read-only projection of the on-disk wake-job records. stall_basis names the evidence behind `stalled`: \"deadline\" and \"stall_seconds\" are real verdicts, \"terminal\" means the run already ended, and \"none\" means the record carries no deadline or stall threshold — the job is NOT known to be healthy, it is unmeasurable. Codex records carry neither, so codex jobs are always stall_basis=none while in flight. delivery_outcome \"unknown\" means the bridge could not confirm the handoff either way; it is NOT the same as \"lost\". An absent completion_text_head on a delivered job is normal — the runner clears the text once delivery succeeds."),
        ])
    }

    static func delegationStatusLimit(_ input: [String: JSONValue]) -> Int {
        let raw: Int?
        switch input["limit"] {
        case .some(.int(let i)): raw = Int(i)
        case .some(.double(let d)): raw = Int(d)
        case .some(.string(let s)): raw = Int(s)
        default: raw = nil
        }
        guard let raw else { return DelegationStatusProjector.defaultLimit }
        return max(1, min(raw, DelegationStatusProjector.maxLimit))
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
