import NativeAgentCore
import NativeAgentShared
import Foundation
import PersistenceCore
// Blueprint: | `AgentCommsActions+DelegationTools.swift` | `SwiftToolDispatcher` `impl_delegation_status` |


extension SwiftToolDispatcher {

    /// Store roots share the message route’s injected agentBridgeConfigRoot; this read starts no work.
    func impl_delegation_status(invocation: ChatToolInvocation, input: DelegationStatusArgs) async throws -> JSONValue {
        let projector = DelegationStatusProjector(configRoot: agentBridgeConfigRoot, dataRoot: dataRoot)
        let limit = max(1, min(input.limit ?? 8, 12))
        let offset = max(0, input.offset ?? 0)
        let agentFilter = try Self.delegationStatusAgentFilter(conversation: invocation.conversation, input.agent, dataRoot: dataRoot)
        let fullDetail = input.detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "full"
        let snapshot = projector.readSnapshot(limit: limit, offset: offset, agent: agentFilter)
        let matchedCount = snapshot.matchedCount
        let peers = try AgentPeerStore(dataRoot: dataRoot).list()
        let sources = snapshot.sources.filter { $0.status != "absent" }
        let evidenceStatus: String
        if sources.isEmpty {
            evidenceStatus = "no_evidence"
        } else if sources.contains(where: { $0.status == "partial" || $0.status == "unavailable" }) {
            evidenceStatus = sources.contains(where: { $0.status == "available" || $0.status == "partial" })
                ? "partial" : "unavailable"
        } else {
            evidenceStatus = "ok"
        }
        let jobs = snapshot.jobs
        // Settlement is the projector's evidence, independent of a recorded execution completion time.
        let open = jobs.filter { $0.completedAt == nil && !$0.deliverySettled }
        var response: [String: JSONValue] = [
            "status": .string(evidenceStatus),
            "source_availability": .array(sources.map(\.json)),
            "projection_schema_version": .int(4),
            "count": .int(Int64(jobs.count)),
            "matched_count": .int(Int64(matchedCount)),
            "returned_count": .int(Int64(jobs.count)),
            "offset": .int(Int64(offset)),
            "has_more": .bool(offset < matchedCount && jobs.count < matchedCount - offset),
            "detail": .string(fullDetail ? "full" : "compact"),
            "open_count": .int(Int64(open.count)),
            // Confirmed loss and unknown delivery must remain distinct.
            "delivery_lost_count": .int(Int64(jobs.filter { $0.deliveryOutcome == "lost" }.count)),
            "delivery_unknown_count": .int(Int64(jobs.filter { $0.deliveryOutcome == "unknown" }.count)),
            "deliveries": .array(jobs.map { job in
                let value = PeerDataTaintDispatcher.labelled(fullDetail ? job.toJSON() : job.toCompactJSON(), agent: job.agent, dataRoot: dataRoot)
                guard case .object(var object) = value,
                      let who = peers.first(where: { "peer:" + $0.id == job.agent }) else { return value }
                object["agent_name"] = .string(who.name)
                return .object(object)
            }),
            "note": .string("""
                jobs: the work you gave other agents and your own lines (agent self) with agent.job, newest first; agent.read {job} opens one. \
                deliveries: retained reply \
                deliveries, read-only; source availability distinguishes readable empty stores, absent evidence and skipped unreadable or \
                malformed records. An empty or partial projection never proves no work exists; unknown delivery is not proven lost.
                """),
        ]
        // The agent's commissions are the jobs; deliveries are the replies owed or carried for chats and contacts.
        do {
            let given = try AgentJobStore(dataRoot: dataRoot).jobs()
                .filter { agentFilter == nil || $0.agent == agentFilter }
                .sorted { $0.startedAt > $1.startedAt }
            response["jobs_open"] = .int(Int64(given.filter { !$0.state.isTerminal }.count))
            response["jobs"] = .array(given.prefix(limit).map { job in
                var row: [String: JSONValue] = ["job": .string(job.id), "agent": .string(job.agent), "name": .string(job.name),
                    "state": .string(job.state.rawValue), "kind": .string(job.kind), "brief": .string(String(job.brief.prefix(160))),
                    "started_at": .string(NativeTimestampFormat.fractionalZulu(job.startedAt)),
                    "read_with": .object(["action": .string("agent.read"), "args": .object(["agent": .string(job.agent), "job": .string(job.id)])])]
                if job.isOwn { row["conversation"] = .string(job.id) }
                if let verdict = job.check?.verdict { row["check"] = .string(verdict.rawValue) }
                if let ended = job.endedAt { row["ended_at"] = .string(NativeTimestampFormat.fractionalZulu(ended)) }
                return .object(row)
            })
        } catch {
            response["jobs_unavailable"] = .string("Your jobs could not be read: \(error.localizedDescription)")
        }
        if offset < matchedCount && jobs.count < matchedCount - offset {
            response["next_offset"] = .int(Int64(offset + jobs.count))
        }
        return .object(response)
    }

    /// A named contact filters to its own deliveries; a name that resolves to no saved contact filters by that exact principal.
    static func delegationStatusAgentFilter(conversation: AgentConversationContext, _ agent: String?, dataRoot: URL) throws -> String? {
        guard let s = agent else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "all" { return nil }
        let named = try AgentConversationRouting.namingSavedContact(conversation: conversation, "agent_read", ["agent": .string(trimmed)],
            dataRoot: dataRoot)
        if case .string(let target)? = named["agent"] { return target }
        return trimmed
    }
}
