import Foundation
import PersistenceCore
import Desk
import SwarmRuns
// Blueprint: | `HerScreenRooms+Agents.swift` | `HerScreen`: `agentsTarget`, `crewsRoom`, `delegationsRoom`; crews reuse HerScreen's crew rows and canonical SwarmCrew liveness, counting unknown separately from running |

/// Her screen, agents slice (2026-09-24, User: "get it all in her workspace").
/// Crews (every swarm, not only a live one), delegations (the jobs Claude,
/// Codex and Omp ran for her) and a helper's pause/resume, each by a stable
/// name. Local file reads on open only; nothing here runs on home.
extension HerScreen {
    static let crewStoreRemedy = Repair.remedy(owner: "SwarmRuns", nextCall: nil, tap: nil,
        instruction: "Inspect only the reported swarm-store file; restore access or repair its data, preserving original bytes and worker results.")

    /// `crews`, `delegations`, `job.N`, `<helper>.pause` / `.resume`; nil for any other name.
    static func agentsTarget(_ name: String, dataRoot: URL) async -> Target? {
        switch name {
        case "crews": return .page(crewsRoom(dataRoot: dataRoot))
        case "delegations": return .page(delegationsRoom(dataRoot: dataRoot))
        default: break
        }
        if name.hasPrefix("job."), let n = Int(name.dropFirst(4)), let id = withNames(dataRoot, { $0.id("job", n) }) {
            return .page(await jobRoom(id: id, name: name, dataRoot: dataRoot)
                ?? "\(name) is no longer in the delegation records.\nBack: home · delegations.")
        }
        for (verb, paused) in [(".pause", true), (".resume", false)] where name.hasSuffix(verb) {
            let slug = String(name.dropLast(verb.count))
            guard let entry = withNames(dataRoot, { $0.slugs[slug] }), entry.id.lowercased().hasPrefix("bot:") else { return nil }
            return .action(.perform(tool: "bot_pause", input: ["id": .string(String(entry.id.dropFirst(4))), "paused": .bool(paused)],
                                    title: (paused ? "Pause " : "Resume ") + entry.name, textField: nil, isEffect: true))
        }
        return nil
    }

    // MARK: Crews

    /// Every crew, unsettled first, then the newest finished runs: task, state,
    /// workers, age. Unknown liveness stays explicit; `crew.N` opens one.
    static func crewsRoom(dataRoot: URL, now: Date = Date()) -> String {
        let all: [[String: Any]]
        do { all = try SwiftNativeSwarmRunsReader(runsPath: dataRoot.appendingPathComponent("swarms/runs.json")).readCrews() }
        catch { return readFailure(error, reason: "crew_records_unavailable", remedy: crewStoreRemedy) }
        let live = all.filter { SwarmCrew.liveness(of: $0) == .running }, unknown = all.filter { SwarmCrew.liveness(of: $0) == .unknown }
        let lines = crewRows(all, dataRoot: dataRoot, now: now)
        return screen(["CREWS", "\(live.count) running"] + (unknown.isEmpty ? [] : ["\(unknown.count) unknown"])
            + ["\(all.count) in the record"] + (all.count > 10 ? ["10 newest shown"] : []),
            [lines.isEmpty ? ["no crews yet"] : lines],
            verbs: [("crew.N", "open its task, worker states and words"), ("app {find:\"agent.swarm\"}", "arguments for starting a crew")])
    }

    // MARK: Delegations

    private static func jobs(dataRoot: URL, now: Date) -> [DelegationJobProjection] {
        DelegationStatusProjector(configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot), dataRoot: dataRoot).recentJobs(now: now, limit: DelegationStatusProjector.maxLimit)
    }

    /// Handed straight into the agent's live session (Claude): no reply
    /// comes back on the job; she answers in a bridge chat of her own.
    private static func deliveredLive(_ job: DelegationJobProjection) -> Bool {
        (job.runStatus ?? job.status) == "delivered_live"
    }

    static func jobState(_ job: DelegationJobProjection, now: Date) -> String {
        let state = job.runStatus ?? job.status ?? job.state ?? "not recorded"
        var parts = ["execution: " + (deliveredLive(job) ? "not recorded (live handoff)" : state)]
        if job.executionError != nil { parts.append("execution error recorded") }
        if let delivery = job.deliveryOutcome { parts.append("delivery: " + delivery) }
        if deliveredLive(job) { parts.append("handoff: delivered live") }
        if job.stalled(at: now) { parts.append("stalled") }
        if let at = (job.completedAt ?? job.startedAt ?? job.claimedAt ?? job.createdAt).flatMap(date) {
            parts.append(age(now.timeIntervalSince(at)))
        }
        return parts.joined(separator: " · ")
    }

    private static func jobTitle(_ job: DelegationJobProjection) -> String {
        nonEmpty(job.requestTextHead).map(firstLine) ?? nonEmpty(job.topicSlug)?.replacingOccurrences(of: "claude:", with: "") ?? "work for \(job.agent)"
    }

    /// The newest jobs across the three builder lanes: who, what she asked,
    /// its state. `job.N` opens one; the lane's own room holds the talk.
    static func delegationsRoom(dataRoot: URL, now: Date = Date()) -> String {
        let all = jobs(dataRoot: dataRoot, now: now)
        let list = all.prefix(12)
        let lines: [String] = withNames(dataRoot) { book in
            list.map { job in
                let n = book.number("job", id: job.id) {
                    Set(all.map(\.id))
                }
                return pad("job.\(n)", 8) + pad(job.agent, 9) + clip(jobTitle(job), 44) + " · " + jobState(job, now: now)
            }
        }
        let open = list.filter { $0.completedAt == nil }.count, stalled = list.filter(\.stalled).count
        return screen(["DELEGATIONS", "\(open) open"] + (stalled > 0 ? ["\(stalled) stalled"] : []) + ["\(list.count) newest"],
            [lines.isEmpty ? ["nothing delegated yet"] : lines,
             ["Replies come back to you by themselves; there is nothing to poll."]],
            verbs: [("job.N", "open one: what you asked, its reply, its Desk item"), ("claude / codex / omp", "that agent's conversation"),
                    ("<agent>.say", "sends it new work now; queues behind a pending reply (text)")])
    }

    /// A built-in lane's last exchanges both ways, from its own job records
    /// (what she asked, what came back), oldest first; for a record with no
    /// saved exchange history.
    static func laneTalk(_ agent: String, slug: String, now: Date = Date()) -> [String] {
        let mine = DelegationStatusProjector().recentJobs(now: now, limit: 30).filter { $0.agent == agent }.prefix(3).reversed()
        return mine.flatMap { job -> [String] in
            let asked = (job.createdAt ?? job.claimedAt ?? job.startedAt ?? job.completedAt).flatMap(date)
            let back = job.completedAt.flatMap(date)
            let reply = nonEmpty(job.agentReplyText) ?? nonEmpty(job.agentReplyTextHead) ?? nonEmpty(job.completionTextHead)
            func row(_ at: Date?, _ who: String, _ text: String) -> String {
                pad(at.map { age(now.timeIntervalSince($0)) } ?? "", 5) + pad(clip(who, 20), 10) + clip(sentence(text), 80)
            }
            let sent = nonEmpty(job.requestTextHead).map { [row(asked, "me", $0)] } ?? []
            if let reply {
                ContactThread.consume(.init(text: reply, stamp: .init(source: job.agent.isEmpty ? nil : job.agent, steeredBy: [], contact: true)),
                    mark: { peer, _ in AgentWorkspacePorts.current.tools.markConsumed(peer: peer) })
                return sent + [row(back, slug, reply)]
            }
            // No words back: the send's own outcome, not words from them.
            if let error = nonEmpty(job.executionError) {
                return (sent.isEmpty ? [row(asked, "me", "(message text not kept)")] : sent) + [jobFailure(job, error: error)]
            }
            return (sent.isEmpty ? [row(asked, "me", "(message text not kept)")] : sent) + [row(back, "", jobState(job, now: now))]
        }
    }

    static func jobRoom(id: String, name: String, dataRoot: URL, now: Date = Date()) async -> String? {
        guard let job = jobs(dataRoot: dataRoot, now: now).first(where: { $0.id == id }) else { return nil }
        let asked = nonEmpty(job.requestTextHead).map { plainLines($0).prefix(3).map { clip($0, 100) } } ?? [clip(jobTitle(job), 100)]
        let replyText = nonEmpty(job.agentReplyText) ?? nonEmpty(job.agentReplyTextHead) ?? nonEmpty(job.completionTextHead)
        if let replyText {
            ContactThread.consume(.init(text: replyText, stamp: .init(source: job.agent.isEmpty ? nil : job.agent, steeredBy: [], contact: true)),
                mark: { peer, _ in AgentWorkspacePorts.current.tools.markConsumed(peer: peer) })
        }
        var reply = replyText.map { plainLines($0).prefix(5).map { clip($0, 100) } } ?? [job.completedAt == nil ? "not back yet" : "no reply text retained"]
        if replyText == nil, deliveredLive(job) {
            reply = ["Delivered to \(job.agent)'s live session; this job retains no reply. Open the agent's conversation."]
            let done = job.completedAt.flatMap(date) ?? .distantPast
            if let chat = bridgeChats(dataRoot: dataRoot).filter({ $0.who == job.agent && $0.at >= done }).last {
                let n = withNames(dataRoot) { $0.number("chat", id: chat.id) { [chat.id] } }
                reply.append("later conversation: chat.\(n) " + clip(chat.title, 60) + " · " + age(now.timeIntervalSince(chat.at)))
            }
        }
        if job.agentReplyTruncated { reply.append("(reply cut; the full text: app agent.read agent \(job.agent))") }
        var about: [String] = []
        if let error = nonEmpty(job.executionError) { about.append(jobFailure(job, error: error)) }
        if let handle = job.deskHandle, let desk = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState(),
           let item = desk.items.first(where: { $0.handle == handle }) {
            about.append("desk." + item.alias + " " + clip(item.title, 60))
        }
        let took = job.elapsedSeconds.flatMap { $0 > 0 && !deliveredLive(job) ? $0 : nil }.map { (job.completedAt == nil ? "running " : "took ") + age(TimeInterval($0)) }
        return screen([name, job.agent, jobState(job, now: now)] + (took.map { [$0] } ?? []),
            [section("STATUS", [jobState(job, now: now)]), section("ASKED", asked), section("REPLY", reply), section("ABOUT", about)],
            verbs: [(job.agent + ".say", "follow up (text)"), (job.agent, "the whole conversation"), ("delegations", "every job")],
            back: "Back: home · delegations.")
    }

    private static func jobFailure(_ job: DelegationJobProjection, error: String) -> String {
        var args: [String: JSONValue] = ["agent": .string(job.agent)]
        args["message_id"] = job.acceptedMessageIDs.sorted().first.map(JSONValue.string)
        return failureFace(.object(["status": .string(job.runStatus ?? job.status ?? "failed"), "reason": .string("agent_execution_error"),
            "detail": .string(error), "effects": .string("unknown"),
            "remedy": Repair.reconcile(instruction: "Read execution and delivery evidence before sending more work.",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.jobs"),
                    "args": .object(args)])]))]))
    }
}
