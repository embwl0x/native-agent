import AgentWorkspace
import NativeAgentCore
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
// builtInToolNames and alwaysOnCoreNames, `safe_read`/.low in
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
        var projector = DelegationStatusProjector(configRoot: agentBridgeConfigRoot, dataRoot: dataRoot)
        let limit = Self.delegationStatusLimit(input)
        let offset = Self.delegationStatusOffset(input)
        let agentFilter = try Self.delegationStatusAgentFilter(input, dataRoot: dataRoot)
        let fullDetail = Self.delegationStatusFullDetail(input)
        var inbox: (url: URL, retained: Bool)?
        if let messageID, agentFilter == "claude" {
            // Through any of her doors, or a lane since renamed: the retained receipt owns its inbox.
            let matches = try AgentConversationStore(dataRoot: dataRoot).records().filter {
                AgentConversationDelivery.claudeInbox($0) && $0.readInput?["message_id"] == .string(messageID)
            }
            guard matches.count <= 1 else {
                throw ToolFailureError("More than one retained exchange owns this message_id; read its named conversation to reconcile it. Nothing was resent.", effects: .none)
            }
            var url = (agentBridgeConfigRoot ?? InstallPaths.current.bridgeConfigRoot).appendingPathComponent("claude-bridge/claude-inbox.jsonl")
            if case .object(let receipt)? = matches.first?.receipt, case .string(let path)? = receipt["filePath"] {
                let saved = URL(fileURLWithPath: path)
                guard path.hasPrefix("/"), ["claude-inbox.jsonl", "claude-inbox.jsonl"].contains(saved.lastPathComponent),
                      ["claude-bridge", "claude-bridge"].contains(saved.deletingLastPathComponent().lastPathComponent) else {
                    throw ToolFailureError("The retained exchange has an invalid inbox address in agents/conversations.json filePath. Nothing was read or resent.", effects: .none)
                }
                url = saved
            }
            inbox = (url, !matches.isEmpty)
            projector.claudeJobsDirectory = url.deletingLastPathComponent().appendingPathComponent("wake-jobs")
        }
        let snapshot = projector.readSnapshot(now: Date(), limit: limit, offset: offset,
                                              agent: agentFilter, messageID: messageID)
        // Not answered yet: her inbox says whether her live session read it.
        // An answer reads below, in full, as every exact read does.
        if let messageID, let inbox,
           snapshot.jobs.allSatisfy({ ($0.runStatus ?? $0.status) == "delivered_live" && $0.agentReplyTextHead == nil }),
           inbox.retained || DelegationStatusProjector.requestTexts(inbox: inbox.url, ids: [messageID], field: "id")[messageID] != nil {
            let read = DelegationStatusProjector.requestTexts(inbox: inbox.url, ids: [messageID], field: "read")[messageID] == "true"
            return .object(["status": .string(read ? "read" : "queued"), "message_id": .string(messageID),
                "filePath": .string(inbox.url.path), "read": .bool(read),
                "detail": .string(read ? "The recipient read this exact message; no answer is recorded yet." : "No recipient read is recorded. Delivery remains owed at the original inbox; nothing was resent.")])
        }

        let matchedCount = snapshot.matchedCount
        // Contact names only decorate retained evidence; an unreadable address book never hides it.
        let peers = (try? AgentPeerStore(dataRoot: dataRoot).list()) ?? []
        let sources = snapshot.sources.filter { source in (agentFilter == nil || source.agent == agentFilter)
            && (source.status != "absent" || peers.contains(where: { ($0.handles ?? []).contains(source.agent) })) }
        let evidenceStatus: String
        if sources.allSatisfy({ $0.status == "absent" }) {
            evidenceStatus = "no_evidence"
        } else if sources.contains(where: { $0.status == "partial" || $0.status == "unavailable" }) {
            evidenceStatus = sources.contains(where: { $0.status == "available" || $0.status == "partial" })
                ? "partial" : "unavailable"
        } else {
            evidenceStatus = "ok"
        }
        let jobs = snapshot.jobs

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
            "matched_count": .int(Int64(matchedCount)),
            "returned_count": .int(Int64(jobs.count)),
            "offset": .int(Int64(offset)),
            "has_more": .bool(offset < matchedCount && jobs.count < matchedCount - offset),
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
                // The contact first: its attested id carries the person's grant; the lane name never does.
                let who = peers.first(where: { ($0.handles ?? []).contains(job.agent) })
                let value = PeerDataTaintDispatcher.labelled(
                    fullDetail ? job.toJSON(includeReplyText: messageID != nil) : job.toCompactJSON(),
                    agent: who.map { "peer:" + $0.id } ?? job.agent, dataRoot: dataRoot)
                guard case .object(var object) = value else { return value }
                if let who {
                    object["door"] = .string(job.agent)
                    object["agent"] = .string("peer:" + who.id)
                    object["agent_name"] = .string(who.name)
                } else {
                    object["owner"] = .string("\(job.agent) had no reader on this Mac")
                }
                guard let messageID else { return .object(object) }
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
            ].filter { key, _ in sources.contains { $0.agent == key } }),
            "note": .string("Read-only wake-job projection. Source availability distinguishes readable empty stores, absent evidence, and skipped unreadable/malformed records. Readable jobs are retained; an empty or partial projection never proves no work exists. `none` stall basis is unmeasurable, not verified healthy; unknown delivery is not proven lost. Build counts describe this returned page."),
        ]
        if offset < matchedCount && jobs.count < matchedCount - offset {
            response["next_offset"] = .int(Int64(offset + jobs.count))
        }
        if let messageID {
            response["message_id"] = .string(messageID)
            response["lookup_status"] = .string(matchedCount == 0 ? "not_observed" : "matched")
            response["lookup_note"] = .string("Matches recorded accepted-message IDs only. Several rows can describe one execution: record_kind distinguishes a retained reply job from a delivery receipt. Compare thread_id/turn_id and dates; differing delivery outcomes remain recorded evidence, not permission to replay. A missing match does not prove no execution: queued, unreadable, or no-longer-retained work may not be represented. Internal job IDs remain unchanged.")
        }
        if let runtimeRevision { response["runtime_source_revision"] = .string(runtimeRevision) }
        return .object(response)
    }

    private static func invalidDelegationMessageLookup() -> JSONValue {
        .object(["status": .string("failed"), "effects": .string("none"), "reason": .string("delegation_message_id_invalid"),
                 "message": .string("Pass the exact messageId returned by a builder message, at most 160 characters. Omit, null, or empty lists bridge jobs. This is an identifier, never a path; no work was started.")])
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

    static func delegationStatusAgentFilter(_ input: [String: JSONValue], dataRoot: URL) throws -> String? {
        guard case .string(let s)? = input["agent"] else { return nil }
        let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "all" { return nil }
        let named = try AgentConversationRouting.namingSavedContact("agent_read", ["agent": .string(normalized)], dataRoot: dataRoot)
        let target: String = if case .string(let target)? = named["agent"] { target } else { normalized }
        if let lane = AgentConversationDelivery.lane(for: target, dataRoot: dataRoot) { return lane == "claude" ? "claude" : lane }
        if AgentConversationDelivery.inbox(agent: normalized, bridgeConfigRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot)) != nil {
            return normalized == "claude" ? "claude" : normalized
        }
        throw ToolFailureError("No retained inbox door matches this contact. Use agent.read for its own conversation.", argumentPath: "agent", effects: .none)
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
