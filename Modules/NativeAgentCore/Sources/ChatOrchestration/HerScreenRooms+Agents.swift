import Foundation
import PersistenceCore

/// Her screen, agents slice (2026-09-24, User: "get it all in her workspace").
/// Crews (every swarm, not only a live one), delegations (the jobs Claude,
/// Codex and Omp ran for her) and a helper's pause/resume, each by a stable
/// name. Local file reads on open only; nothing here runs on home.
extension HerScreen {
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

    /// Every crew, live first, then the newest finished runs: task, state,
    /// workers, age. `crew.N` opens one (crewPage reads live and finished alike).
    static func crewsRoom(dataRoot: URL, now: Date = Date()) -> String {
        let live = rows(dataRoot.appendingPathComponent("swarms/live.json"))
        let runs = rows(dataRoot.appendingPathComponent("swarms/runs.json"))
        let liveIDs = Set(live.compactMap { $0["id"] as? String })
        let all = live + runs.filter { !liveIDs.contains($0["id"] as? String ?? "") }
        let lines: [String] = withNames(dataRoot) { book in
            all.prefix(10).compactMap { row -> String? in
                guard let id = row["id"] as? String else { return nil }
                let workers = row["workers"] as? [[String: Any]] ?? []
                let working = workers.filter { ($0["status"] as? String ?? "working") == "working" }.count
                let status = liveIDs.contains(id) ? "\(working) of \(workers.count) working" : crewState(row, fallback: "done") + " · \(workers.count) workers"
                let at = (row["completedAt"] as? String ?? row["createdAt"] as? String).flatMap(date)
                let n = book.number("crew", id: id) { Set(all.compactMap { $0["id"] as? String }) }
                return pad("crew.\(n)", 10) + clip(firstLine(row["objective"] as? String ?? "A task"), 44) + " · " + status
                    + (at.map { " · " + age(now.timeIntervalSince($0)) } ?? "")
            }
        }
        return screen(["CREWS", "\(live.count) running", "\(all.count) in the record"] + (all.count > 10 ? ["10 newest shown"] : []),
            [lines.isEmpty ? ["no crews yet"] : lines],
            verbs: [("crew.N", "open one: its task, each worker's state and words"), ("agent_swarm", "start a new crew (tool)")])
    }

    // MARK: Delegations

    private static func jobs(now: Date) -> [DelegationJobProjection] {
        DelegationStatusProjector().recentJobs(now: now, limit: 12)
    }

    /// Handed straight into the agent's live session (Claude): no reply
    /// comes back on the job; she answers in a bridge chat of her own.
    private static func deliveredLive(_ job: DelegationJobProjection) -> Bool {
        (job.runStatus ?? job.status) == "delivered_live"
    }

    private static func jobState(_ job: DelegationJobProjection, now: Date) -> String {
        if deliveredLive(job), let done = job.completedAt.flatMap(date) { return "✓ delivered live " + age(now.timeIntervalSince(done)) }
        guard let done = job.completedAt.flatMap(date) else {
            let started = (job.startedAt ?? job.claimedAt ?? job.createdAt).flatMap(date)
            return (job.stalled ? "✗ stalled" : "⟳ running") + (started.map { " " + age(now.timeIntervalSince($0)) } ?? "")
        }
        let failed = job.executionError != nil || ["failed", "error", "interrupted"].contains((job.runStatus ?? job.status ?? "").lowercased())
        return (failed ? "✗ failed " : "✓ done ") + age(now.timeIntervalSince(done))
            + (job.deliveryOutcome == "lost" ? " · reply lost" : job.deliveryOutcome == "unknown" ? " · delivery unconfirmed" : "")
    }

    private static func jobTitle(_ job: DelegationJobProjection) -> String {
        nonEmpty(job.requestTextHead).map(firstLine) ?? nonEmpty(job.topicSlug)?.replacingOccurrences(of: "claude:", with: "") ?? "work for \(job.agent)"
    }

    /// The newest jobs across the three builder lanes: who, what she asked,
    /// its state. `job.N` opens one; the lane's own room holds the talk.
    static func delegationsRoom(dataRoot: URL, now: Date = Date()) -> String {
        let list = jobs(now: now)
        // Numbered in the order shown, newest first (the desk walk read 13-15 then 1-9).
        let numbers = Dictionary(list.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        withNames(dataRoot) { book in book.numbers["job"] = numbers; book.next["job"] = list.count + 1 }
        let lines: [String] = list.map { job in
                let n = numbers[job.id] ?? 0
                return pad("job.\(n)", 8) + pad(job.agent, 9) + clip(jobTitle(job), 44) + " · " + jobState(job, now: now)
        }
        let open = list.filter { $0.completedAt == nil }.count, stalled = list.filter(\.stalled).count
        return screen(["DELEGATIONS", "\(open) open"] + (stalled > 0 ? ["\(stalled) stalled"] : []) + ["\(list.count) newest"],
            [lines.isEmpty ? ["nothing delegated yet"] : lines,
             ["Replies come back to you by themselves; there is nothing to poll."]],
            verbs: [("job.N", "open one: what you asked, its reply, its Desk item"), ("claude / codex / omp", "that agent's conversation"),
                    ("<agent>.say", "send it new work (text)")])
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
            if let reply { return sent + [row(back, slug, reply)] }
            // No words back: the send's own outcome, not words from them.
            let outcome = nonEmpty(job.executionError).map { "✗ " + failureReason($0) } ?? jobState(job, now: now)
            return (sent.isEmpty ? [row(asked, "me", "(message text not kept)")] : sent) + [row(back, "", outcome)]
        }
    }

    static func jobRoom(id: String, name: String, dataRoot: URL, now: Date = Date()) async -> String? {
        guard let job = jobs(now: now).first(where: { $0.id == id })
            ?? DelegationStatusProjector().recentJobs(now: now, limit: DelegationStatusProjector.maxLimit).first(where: { $0.id == id }) else { return nil }
        let asked = nonEmpty(job.requestTextHead).map { plainLines($0).prefix(3).map { clip($0, 100) } } ?? [clip(jobTitle(job), 100)]
        let replyText = nonEmpty(job.agentReplyText) ?? nonEmpty(job.agentReplyTextHead) ?? nonEmpty(job.completionTextHead)
        var reply = replyText.map { plainLines($0).prefix(5).map { clip($0, 100) } } ?? [job.completedAt == nil ? "not back yet" : "no reply text retained"]
        if replyText == nil, deliveredLive(job) {
            reply = ["Delivered straight into \(job.agent.capitalized)'s live session; the answer comes as a chat of their own."]
            let done = job.completedAt.flatMap(date) ?? .distantPast
            if let chat = bridgeChats(dataRoot: dataRoot).filter({ $0.who == job.agent && $0.at >= done }).last {
                let n = withNames(dataRoot) { $0.number("chat", id: chat.id) { [chat.id] } }
                reply.append("answer: chat.\(n) " + clip(chat.title, 60) + " · " + age(now.timeIntervalSince(chat.at)))
            }
        }
        if job.agentReplyTruncated { reply.append("(reply cut; the full text: agent_read agent \(job.agent))") }
        var about: [String] = []
        if let error = nonEmpty(job.executionError) { about.append("error: " + clip(error, 100)) }
        if let handle = job.deskHandle, let desk = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState(),
           let item = desk.items.first(where: { $0.handle == handle }) {
            about.append("desk." + item.alias + " " + clip(item.title, 60))
        }
        let took = job.elapsedSeconds.flatMap { $0 > 0 && !deliveredLive(job) ? $0 : nil }.map { (job.completedAt == nil ? "running " : "took ") + age(TimeInterval($0)) }
        return screen([name, job.agent, jobState(job, now: now)] + (took.map { [$0] } ?? []),
            [section("ASKED", asked), section("REPLY", reply), section("ABOUT", about)],
            verbs: [(job.agent + ".say", "follow up (text)"), (job.agent, "the whole conversation"), ("delegations", "every job")],
            back: "Back: home · delegations.")
    }
}
