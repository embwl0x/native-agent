import Foundation
import PersistenceCore
import Desk
import SwarmRuns
// Blueprint: | `HerScreenRooms+Agents.swift` | `HerScreen`: `agentsTarget`, `crewsRoom`, `delegationsRoom`; crews reuse canonical SwarmCrew liveness; delegation pages carry owner source availability and matched counts, saved job numbers use exact uncapped owner lookup; missing completion time stays unknown |

/// Crews, delegations and helper controls open by stable name; local reads happen only on open.
extension HerScreen {
    static let crewStoreRemedy = Repair.remedy(owner: "SwarmRuns", nextCall: nil, tap: nil,
        instruction: "Inspect only the reported swarm-store file; restore access or repair its data, preserving original bytes and worker results.")

    /// `crews`, `delegations`, `job.N`, `<helper>.pause` / `.resume`; nil for any other name.
    static func agentsTarget(_ name: String, dataRoot: URL) async -> Target? {
        do {
            switch name {
            case "crews": return .page(crewsRoom(dataRoot: dataRoot))
            case "delegations": return .page(delegationsRoom(dataRoot: dataRoot))
            default: break
            }
            if name.hasPrefix("job."), let n = Int(name.dropFirst(4)), let id = try withNames(dataRoot, { $0.id("job", n) }) {
                return .page(await jobRoom(id: id, name: name, dataRoot: dataRoot)
                    ?? "\(name) has no matching record in the available delegation sources; this does not establish removal.\nBack: home · delegations.")
            }
            for (verb, paused) in [(".pause", true), (".resume", false)] where name.hasSuffix(verb) {
                let slug = String(name.dropLast(verb.count))
                guard let entry = try withNames(dataRoot, { $0.slugs[slug] }), entry.id.lowercased().hasPrefix("bot:") else { return nil }
                return .action(.perform(tool: "bot_pause", input: ["id": .string(String(entry.id.dropFirst(4))), "paused": .bool(paused)],
                                        title: (paused ? "Pause " : "Resume ") + entry.name, textField: nil, isEffect: true))
            }
            return nil
        } catch { return .page(nameFailure(error)) }
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

    private static func jobs(dataRoot: URL, now: Date, jobID: String? = nil) -> DelegationStatusReadSnapshot {
        DelegationStatusProjector(configRoot: InstallPaths.current.bridgeConfigRoot(dataRoot: dataRoot), dataRoot: dataRoot)
            .readSnapshot(now: now, limit: jobID == nil ? 12 : nil, jobID: jobID)
    }

    private static func sourceRows(_ snapshot: DelegationStatusReadSnapshot) -> [String] {
        snapshot.sources.map { source in
            source.source + ": " + source.status + (source.detail.map { " · " + $0 } ?? "")
        }
    }

    /// Handed straight into the agent's live session (Claude): no reply
    /// comes back on the job; she answers in a bridge chat of her own.
    private static func deliveredLive(_ job: DelegationReadout) -> Bool {
        (job.runStatus ?? job.status) == "delivered_live"
    }

    static func jobState(_ job: DelegationReadout, now: Date) -> String {
        let state = job.runStatus ?? job.status ?? job.state ?? "not recorded"
        var parts = ["execution: " + (deliveredLive(job) ? "not recorded (live handoff)" : state)]
        if job.executionError != nil {
            parts.append(state == "observation_unavailable" ? "completion observation unavailable" : "execution error recorded")
        }
        if let delivery = job.deliveryOutcome { parts.append("delivery: " + delivery) }
        if deliveredLive(job) { parts.append("handoff: in inbox; delivery unconfirmed") }
        if job.completedAt == nil { parts.append("completion time not recorded") }
        if job.stalled(at: now) { parts.append("stalled") }
        if let at = (job.completedAt ?? job.startedAt ?? job.claimedAt ?? job.createdAt).flatMap(date) {
            parts.append(age(now.timeIntervalSince(at)))
        }
        return parts.joined(separator: " · ")
    }

    private static func jobTitle(_ job: DelegationReadout) -> String {
        nonEmpty(job.requestTextHead).map(firstLine) ?? nonEmpty(job.topicSlug)?.replacingOccurrences(of: "claude:", with: "") ?? "work for \(job.agent)"
    }

    /// The newest jobs across the three builder lanes: who, what she asked,
    /// its state. `job.N` opens one; the lane's own room holds the talk.
    static func delegationsRoom(dataRoot: URL, now: Date = Date()) -> String {
        do {
            let snapshot = jobs(dataRoot: dataRoot, now: now)
            let all = snapshot.jobs
            let list = all.prefix(12)
            let lines: [String] = try withNames(dataRoot) { book in
                try list.map { job in
                    let n = try book.number("job", id: job.id) {
                        Set(all.map(\.id))
                    }
                    return pad("job.\(n)", 8) + pad(job.agent, 9) + clip(jobTitle(job), 44) + " · " + jobState(job, now: now)
                }
            }
            let stalled = list.filter(\.stalled).count
            let complete = snapshot.sources.allSatisfy { ["available", "absent"].contains($0.status) }
            return screen(["DELEGATIONS", complete ? "available sources" : "partial sources"] + (stalled > 0 ? ["\(stalled) stalled"] : []) + ["\(list.count) newest of \(snapshot.matchedCount) observed"],
                [lines.isEmpty ? [complete ? "no jobs found in the available sources" : "job census unavailable; no empty verdict"] : lines,
                 section("SOURCES", sourceRows(snapshot)),
                 ["Replies come back to you by themselves; there is nothing to poll."]],
                verbs: [("job.N", "open one: what you asked, its reply, its Desk item"), ("claude / codex / omp", "that agent's conversation"),
                        ("<agent>.say", "sends it new work now; queues behind a pending reply (text)")])
        } catch { return nameFailure(error) }
    }

    static func jobRoom(id: String, name: String, dataRoot: URL, now: Date = Date()) async -> String? {
        do {
            let snapshot = jobs(dataRoot: dataRoot, now: now, jobID: id)
            guard let job = snapshot.jobs.first(where: { $0.id == id }) else {
                return screen([name, "record not observed"], [["An exact lookup found no matching record in the readable sources. Absence does not establish removal; the recent list is only a page."],
                    section("SOURCES", sourceRows(snapshot))], verbs: [("delegations", "newest observed jobs")])
            }
            let asked = nonEmpty(job.requestTextHead).map { plainLines($0).prefix(3).map { clip($0, 100) } } ?? [clip(jobTitle(job), 100)]
            let replyText = nonEmpty(job.agentReplyText) ?? nonEmpty(job.agentReplyTextHead) ?? nonEmpty(job.completionTextHead)
            if let replyText {
                ContactThread.consume(.init(text: replyText, stamp: .init(source: job.agent.isEmpty ? nil : job.agent, steeredBy: [], contact: true)),
                    mark: { peer, _ in AgentWorkspacePorts.current.tools.markConsumed(peer: peer) })
            }
            var reply = replyText.map { plainLines($0).prefix(5).map { clip($0, 100) } } ?? ["no reply text retained; read the recorded execution and delivery state"]
            if replyText == nil, deliveredLive(job) {
                reply = ["Handed to \(job.agent)'s inbox; this job retains no confirmed delivery or reply. Open the agent's conversation."]
                if let done = job.completedAt.flatMap(date), let chat = try bridgeChats(dataRoot: dataRoot).filter({ $0.who == job.agent && $0.at >= done }).last {
                    let n = try withNames(dataRoot) { try $0.number("chat", id: chat.id) { [chat.id] } }
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
            let took = job.elapsedSeconds.flatMap { $0 > 0 && !deliveredLive(job) ? $0 : nil }.map { "observed elapsed " + age(TimeInterval($0)) }
            return screen([name, job.agent, jobState(job, now: now)] + (took.map { [$0] } ?? []),
                [section("STATUS", [jobState(job, now: now)]), section("ASKED", asked), section("REPLY", reply), section("ABOUT", about), section("SOURCES", sourceRows(snapshot))],
                verbs: [(job.agent + ".say", "follow up (text)"), (job.agent, "the whole conversation"), ("delegations", "newest observed jobs")],
                back: "Back: home · delegations.")
        } catch { return nameFailure(error) }
    }

    private static func jobFailure(_ job: DelegationReadout, error: String) -> String {
        var args: [String: JSONValue] = ["agent": .string(job.agent)]
        args["message_id"] = job.acceptedMessageIDs.sorted().first.map(JSONValue.string)
        let observationUnavailable = job.runStatus == "observation_unavailable"
        return failureFace(.object(["status": .string(job.runStatus ?? job.status ?? "failed"), "reason": .string(observationUnavailable ? "agent_observation_unavailable" : "agent_execution_error"),
            "detail": .string(error), "effects": .string("unknown"),
            "remedy": Repair.reconcile(instruction: observationUnavailable
                ? "Repair the completion evidence source and inspect the existing turn; do not interrupt or replay it from silence."
                : "Read execution and delivery evidence before sending more work.",
                nextCall: .object(["tool": .string("app"), "input": .object(["action": .string("agent.jobs"),
                    "args": .object(args)])]))]))
    }
}
