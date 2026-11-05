import Foundation
import PersistenceCore
import Desk
// Blueprint: | `AgentScreenRooms+Agents.swift` | `AgentScreen`, `agentsTarget`, `delegationsRoom`: exact owner liveness; crews are the agent's lines |
// Saved job numbers use exact uncapped owner lookup; page counts and unavailable sources remain visible.

/// Crews, delegations and helper controls open by stable name; local reads happen only on open.
extension AgentScreen {

    static func agentsTarget(workspace: WorkspaceOperation, _ name: String, dataRoot: URL) async -> Target? {
        do {
            switch name {
            case "crews": return .page(crewsRoom(dataRoot: dataRoot))
            case "delegations": return .page(delegationsRoom(workspace: workspace, dataRoot: dataRoot))
            default: break
            }
            if name.hasPrefix("job."), let n = Int(name.dropFirst(4)), let id = try withNames(workspace: workspace, dataRoot, { $0.id("job", n) }) {
                return .page(await jobRoom(workspace: workspace, id: id, name: name, dataRoot: dataRoot)
                    ?? "\(name) has no matching record in the available delegation sources; this does not establish removal.\nBack: home · delegations.")
            }
            for (verb, paused) in [(".pause", true), (".resume", false)] where name.hasSuffix(verb) {
                let slug = String(name.dropLast(verb.count))
                guard let entry = try withNames(workspace: workspace, dataRoot, { $0.slugs[slug] }), entry.id.lowercased().hasPrefix("bot:") else { return nil }
                return .action(.perform(tool: "bot_pause", input: ["id": .string(String(entry.id.dropFirst(4))), "paused": .bool(paused)],
                                        title: (paused ? "Pause " : "Resume ") + entry.name, textField: nil, isEffect: true))
            }
            return nil
        } catch { return .page(nameFailure(error)) }
    }

    // MARK: Delegations

    private static func jobs(dataRoot: URL, now: Date, jobID: String? = nil) -> DelegationStatusReadSnapshot {
        DelegationStatusProjector(configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot), dataRoot: dataRoot)
            .readSnapshot(now: now, limit: jobID == nil ? 12 : nil, jobID: jobID)
    }

    private static func sourceRows(_ snapshot: DelegationStatusReadSnapshot) -> [String] {
        snapshot.sources.map { source in
            source.source + ": " + source.status + (source.detail.map { " · " + $0 } ?? "")
        }
    }

    static func jobState(_ job: DelegationReadout, now: Date) -> String {
        let state = job.runStatus ?? job.status ?? job.state ?? "not recorded"
        var parts = ["execution: " + state]
        if job.executionError != nil {
            parts.append(state == "observation_unavailable" ? "completion observation unavailable" : "execution error recorded")
        }
        if let delivery = job.deliveryOutcome { parts.append("delivery: " + delivery) }
        if job.completedAt == nil { parts.append("completion time not recorded") }
        if job.stalled(at: now) { parts.append("stalled") }
        if let at = (job.completedAt ?? job.startedAt ?? job.claimedAt ?? job.createdAt).flatMap(date) {
            parts.append(age(now.timeIntervalSince(at)))
        }
        return parts.joined(separator: " · ")
    }

    private static func jobTitle(_ job: DelegationReadout) -> String {
        nonEmpty(job.requestTextHead).map(firstLine) ?? nonEmpty(job.topicSlug) ?? "work for \(job.agent)"
    }

    /// Keep job state in the delegation view and conversation in its owning room.
    static func delegationsRoom(workspace: WorkspaceOperation, dataRoot: URL, now: Date = Date()) -> String {
        do {
            let snapshot = jobs(dataRoot: dataRoot, now: now)
            let all = snapshot.jobs
            let list = all.prefix(12)
            let lines: [String] = try withNames(workspace: workspace, dataRoot) { book in
                try list.map { job in
                    let n = try book.number("job", id: job.id) {
                        Set(all.map(\.id))
                    }
                    return pad("job.\(n)", 8) + pad(job.agent, 9) + clip(jobTitle(job), 44) + " · " + jobState(job, now: now)
                }
            }
            let stalled = list.filter(\.stalled).count
            let complete = snapshot.sources.allSatisfy { ["available", "absent"].contains($0.status) }
            return screen(["DELEGATIONS", complete ? "available sources" : "partial sources"] + (stalled > 0 ? ["\(stalled) stalled"] : [])
                + ["\(list.count) newest of \(snapshot.matchedCount) observed"],
                [lines.isEmpty ? [complete ? "no jobs found in the available sources" : "job census unavailable; no empty verdict"] : lines,
                 section("SOURCES", sourceRows(snapshot)),
                 ["Replies come back to you by themselves; there is nothing to poll."]],
                verbs: [("job.N", "open one: what you asked, its reply, its Desk item"), ("<agent>", "that agent's conversation"),
                        ("<agent>.say", "sends it new work now; queues behind a pending reply (text)")])
        } catch { return nameFailure(error) }
    }

    static func jobRoom(workspace: WorkspaceOperation, id: String, name: String, dataRoot: URL, now: Date = Date()) async -> String? {
        do {
            let snapshot = jobs(dataRoot: dataRoot, now: now, jobID: id)
            guard let job = snapshot.jobs.first(where: { $0.id == id }) else {
                return screen([name,
                    "record not observed"], [["""
                        An exact lookup found no matching record in the readable sources. Absence does not establish removal; the recent list \
                        is only a page.
                        """],
                    section("SOURCES", sourceRows(snapshot))], verbs: [("delegations", "newest observed jobs")])
            }
            let asked = nonEmpty(job.requestTextHead).map { plainLines($0).prefix(3).map { clip($0, 100) } } ?? [clip(jobTitle(job), 100)]
            let replyText = nonEmpty(job.agentReplyText) ?? nonEmpty(job.agentReplyTextHead) ?? nonEmpty(job.completionTextHead)
            if let replyText {
                ContactThread.consume(.init(text: replyText, stamp: .init(source: job.agent.isEmpty ? nil : job.agent, steeredBy: [], contact: true)),
                    mark: { peer, _ in workspace.ports.tools.markConsumed(peer: peer) })
            }
            var reply = replyText.map { plainLines($0).prefix(5).map { clip($0, 100) } }
                ?? ["no reply text retained; read the recorded execution and delivery state"]
            if job.agentReplyTruncated { reply.append("(reply cut; the full text: app agent.read agent \(job.agent))") }
            var about: [String] = []
            if let error = nonEmpty(job.executionError) { about.append(jobFailure(job, error: error)) }
            if let handle = job.deskHandle, let desk = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState(),
               let item = desk.items.first(where: { $0.handle == handle }) {
                about.append("desk." + item.alias + " " + clip(item.title, 60))
            }
            let took = job.elapsedSeconds.flatMap { $0 > 0 ? $0 : nil }.map { "observed elapsed " + age(TimeInterval($0)) }
            return screen([name, job.agent, jobState(job, now: now)] + (took.map { [$0] } ?? []),
                [section("STATUS", [jobState(job, now: now)]), section("ASKED", asked), section("REPLY", reply), section("ABOUT", about), section("SOURCES",
                    sourceRows(snapshot))],
                verbs: [(job.agent + ".say", "follow up (text)"), (job.agent, "the whole conversation"), ("delegations", "newest observed jobs")],
                back: "Back: home · delegations.")
        } catch { return nameFailure(error) }
    }

    private static func jobFailure(_ job: DelegationReadout, error: String) -> String {
        var args: [String: JSONValue] = ["agent": .string(job.agent)]
        args["message_id"] = job.acceptedMessageIDs.sorted().first.map(JSONValue.string)
        let observationUnavailable = job.runStatus == "observation_unavailable"
        return failureFace(.object(["status": .string(job.runStatus ?? job.status ?? "failed"), "reason": .string(observationUnavailable
            ? "agent_observation_unavailable" : "agent_execution_error"),
            "detail": .string(error), "effects": .string("unknown"),
            "remedy": Repair.reconcile(instruction: observationUnavailable
                ? "Repair the completion evidence source and inspect the existing turn; do not interrupt or replay it from silence."
                : "Read execution and delivery evidence before sending more work.",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.jobs"),
                    "args": .object(args)])]))]))
    }
}
