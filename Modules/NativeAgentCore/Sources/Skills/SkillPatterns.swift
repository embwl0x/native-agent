import Foundation
import NativeAgentCore
import PersistenceCore

/// Repeated work, noticed (skills-as-code 4b, User 10-03: "she and anyone's
/// agent should notice repeated work"). Each turn's landed app calls, minus
/// scaffolding, become shapes: every contiguous 2–5 call window as its action
/// ids and sorted argument NAMES, never values. A shape done on 3 distinct
/// turns that no on or drafted skill's script covers is offered once, as one
/// quiet MY QUEUE line of hers; a skill run usually followed by the same
/// calls offers to take them in. Nothing is created here; she writes the
/// skill or drops the line. One small file per install, per agent:
/// `skills/patterns.json`.
public enum SkillPatterns {
    /// One landed app call, as a step of a shape.
    public struct Call: Sendable, Equatable {
        public let action: String
        public let args: [String]
        /// The skill a skill.run ran.
        public let skill: String?
        var step: String { args.isEmpty ? action : action + "(" + args.joined(separator: ",") + ")" }
    }

    /// A line to queue: the words, and the shape it offers (nil for a follow-up).
    public struct Line: Sendable, Equatable {
        public let words: String
        public let agent: String
        public let shape: String?
        /// The skill a follow-up names, whose origin decides whose words it is.
        public var skill: String? = nil
    }

    /// The call as a step, or nil: it did not land, or it is scaffolding
    /// (home, find, a bare page or item read, a script, a preview, page.show,
    /// a screenshot).
    public static func call(input: [String: JSONValue], landed: Bool) -> Call? {
        guard landed, input["preview"] != .bool(true), text(input["script"]).isEmpty,
              case .string(let raw)? = input["action"] else { return nil }
        let action = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(64))
        guard !action.isEmpty, action != "page.show", !action.hasSuffix("screenshot") else { return nil }
        let args = if case .object(let given)? = input["args"] { given } else { [String: JSONValue]() }
        let skill = String(text(args["name"]).prefix(120))
        return Call(action: action, args: Array(args.keys.filter { !$0.hasPrefix("__") }.sorted().prefix(12).map { String($0.prefix(32)) }),
                    skill: action == "skill.run" && !skill.isEmpty ? skill : nil)
    }

    static let windows = 2...5
    static let turnsToNotice = 3
    static let keptTurns = 10
    static let keptDays = 30.0
    static let shapeCap = 500
    static let skillCap = 100
    /// The whole file never grows past this: pruned oldest first, else not written.
    static let byteCap = 512 * 1024

    /// Record one of an agent's own turns; the lines it now earns (at most
    /// one notice a day, and one follow-up per skill until its shape changes).
    /// `name` is how a line names an agent other than her (nil for her).
    public static func observe(turn: String, agent: String, name: String?, calls: [Call],
                               root: URL, now: Date = Date()) -> [Line] {
        guard !calls.isEmpty else { return [] }
        return update(root) { file in
            var mind = file.agents[agent] ?? Agent()
            let cutoff = now.addingTimeInterval(-keptDays * 86_400)
            mind.shapes = mind.shapes.filter { $0.value.last >= cutoff }
            mind.followups = mind.followups.filter { $0.value.last >= cutoff }
            for start in calls.indices {
                for length in windows where start + length <= calls.count {
                    let window = Array(calls[start..<start + length])
                    // One call repeated is not a workflow.
                    guard Set(window.map(\.action)).count > 1 else { continue }
                    let steps = window.map(\.step)
                    var shape = mind.shapes[key(steps)] ?? Shape(steps: steps, turns: [], first: now, last: now)
                    if !shape.turns.contains(turn) { shape.turns = Array((shape.turns + [turn]).suffix(keptTurns)) }
                    shape.last = now
                    mind.shapes[key(steps)] = shape
                }
            }
            if mind.shapes.count > shapeCap {
                let oldest = mind.shapes.sorted { $0.value.last < $1.value.last }.prefix(mind.shapes.count - shapeCap)
                for (key, _) in oldest { mind.shapes.removeValue(forKey: key) }
            }
            var lines: [Line] = []
            let who = name.map { "\($0.prefix(30)) has" } ?? "You've"
            // Follow-ups: the calls after each skill.run, up to the next one.
            for (index, call) in calls.enumerated() where call.action == "skill.run" {
                guard let skill = call.skill else { continue }
                let after = calls[(index + 1)...].prefix { $0.action != "skill.run" }.prefix(3).map(\.step)
                var follow = mind.followups[skill] ?? Followup(runs: [], raised: nil, last: now)
                follow.runs = Array((follow.runs + [after]).suffix(3))
                follow.last = now
                if let usual = usual(follow.runs), key(usual) != follow.raised {
                    follow.raised = key(usual)
                    lines.append(Line(words: fit(usual) { "\(skill.prefix(40)) is usually followed by \($0); add them to it?" },
                                      agent: agent, shape: nil, skill: skill))
                }
                mind.followups[skill] = follow
            }
            if mind.followups.count > skillCap {
                let oldest = mind.followups.sorted { $0.value.last < $1.value.last }.prefix(mind.followups.count - skillCap)
                for (skill, _) in oldest { mind.followups.removeValue(forKey: skill) }
            }
            // The notice: the longest shape on 3 turns, none it overlaps already offered.
            let today = mind.noticedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
            if !today {
                let offered = mind.shapes.values.filter { $0.state != nil }.map(\.steps)
                let ready = mind.shapes.filter { _, shape in
                    shape.state != "noticed" && shape.turns.count >= turnsToNotice
                        && !offered.contains { $0 != shape.steps && (contains($0, shape.steps) || contains(shape.steps, $0)) }
                }.sorted { ($1.value.steps.count, $1.value.turns.count, $0.key) < ($0.value.steps.count, $0.value.turns.count, $1.key) }
                let scripts = ready.isEmpty ? [] : coveringScripts(root)
                if let pick = ready.first(where: { _, shape in
                    let ids = Set(shape.steps.map(action))
                    return !scripts.contains { ids.isSubset(of: $0) }
                }) {
                    mind.shapes[pick.key]?.state = "noticed"
                    mind.shapes[pick.key]?.item = nil
                    mind.noticedAt = now
                    lines.append(Line(words: fit(pick.value.steps) { "\(who) done \($0) in \(pick.value.turns.count) turns; worth a skill?" },
                                      agent: agent, shape: pick.key))
                }
            }
            file.agents[agent] = mind
            return lines
        } ?? []
    }

    /// The MY QUEUE item a notice became, or nil when it could not be queued
    /// (it may be offered again another day).
    public static func queued(_ line: Line, item: String?, root: URL) {
        guard let shape = line.shape else { return }
        _ = update(root) { file in
            guard var record = file.agents[line.agent]?.shapes[shape] else { return () }
            if let item { record.item = item } else {
                record.state = nil
                file.agents[line.agent]?.noticedAt = nil
            }
            file.agents[line.agent]?.shapes[shape] = record
        }
    }

    /// Her notice line closed. Dropped: dismissed, quiet until 3 more turns.
    /// Done: she wrote the skill, so it is covered and no longer tracked.
    public static func closed(item: String, dropped: Bool, root: URL) {
        guard FileManager.default.fileExists(atPath: file(root).path) else { return }
        _ = update(root) { file in
            for (agent, mind) in file.agents {
                for (key, shape) in mind.shapes where shape.item == item {
                    if dropped {
                        file.agents[agent]?.shapes[key] = Shape(steps: shape.steps, turns: [], first: shape.first,
                                                                last: shape.last, state: "dismissed")
                    } else {
                        file.agents[agent]?.shapes.removeValue(forKey: key)
                    }
                }
            }
        }
    }

    public static func file(_ root: URL) -> URL { root.appendingPathComponent("skills/patterns.json") }

    // MARK: - Store

    struct Store: Codable { var agents: [String: Agent] = [:] }
    struct Agent: Codable {
        var shapes: [String: Shape] = [:]
        var followups: [String: Followup] = [:]
        var noticedAt: Date?
    }
    struct Shape: Codable {
        var steps: [String]
        var turns: [String]
        var first: Date
        var last: Date
        /// nil, "noticed" (its line is open) or "dismissed".
        var state: String?
        var item: String?
    }
    struct Followup: Codable {
        var runs: [[String]]
        var raised: String?
        var last: Date
    }

    private static let lock = NSLock()

    private static func update<T>(_ root: URL, _ change: (inout Store) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        let url = file(root)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var store = (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Store.self, from: $0) } ?? Store()
        let result = change(&store)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        do {
            var data = try encoder.encode(store)
            // Over the cap: the oldest tenth of every agent's shapes go, until a
            // quarter is free (so the next turns don't prune again) or none are left.
            let target = data.count > byteCap ? byteCap * 3 / 4 : byteCap
            while data.count > target, store.agents.values.contains(where: { !$0.shapes.isEmpty }) {
                for (agent, mind) in store.agents {
                    let oldest = mind.shapes.sorted { $0.value.last < $1.value.last }.prefix(max(1, mind.shapes.count / 10))
                    for (key, _) in oldest { store.agents[agent]?.shapes.removeValue(forKey: key) }
                }
                data = try encoder.encode(store)
            }
            guard data.count <= byteCap else {
                NSLog("[skill-patterns] not saved: over \(byteCap) bytes")
                return nil
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[skill-patterns] not saved: \(error)")
            return nil
        }
        return result
    }

    // MARK: - Shapes

    static func key(_ steps: [String]) -> String { steps.joined(separator: " ") }
    static func action(_ step: String) -> String { String(step.prefix { $0 != "(" }) }
    /// The line with its calls by action id, kept to `lineLimit`: a long
    /// chain keeps its first and last calls.
    static func fit(_ steps: [String], _ line: (String) -> String) -> String {
        let ids = steps.map(action)
        let full = line(ids.joined(separator: " → "))
        guard full.count > lineLimit, ids.count > 2 else { return full }
        return line("\(ids[0]) → … → \(ids[ids.count - 1]) (\(ids.count) calls)")
    }

    static let lineLimit = 120

    /// Whether `inner` is a contiguous run of `outer`.
    static func contains(_ outer: [String], _ inner: [String]) -> Bool {
        guard inner.count <= outer.count else { return false }
        return (0...(outer.count - inner.count)).contains { Array(outer[$0..<$0 + inner.count]) == inner }
    }

    /// The longest 1–3 calls that open the follow of 2 of these runs.
    static func usual(_ runs: [[String]]) -> [String]? {
        for length in (1...3).reversed() {
            let heads = runs.filter { $0.count >= length }.map { Array($0.prefix(length)) }
            if let head = heads.first(where: { head in heads.filter { $0 == head }.count >= 2 }) { return head }
        }
        return nil
    }

    /// The action sets of the scripts of skills on or drafted; a guidance
    /// skill (no script) covers nothing.
    static func coveringScripts(_ root: URL) -> [Set<String>] {
        ((try? InstalledSkillInventory.entries(dataRoot: root)) ?? []).compactMap { entry in
            guard case .string(let status)? = entry.row["status"],
                  ["active", "installed", "draft"].contains(status.lowercased()),
                  case .object(let script)? = entry.row["script"], case .array(let ids)? = script["actions"] else { return nil }
            return Set(ids.compactMap { if case .string(let id) = $0 { id.lowercased() } else { nil } })
        }
    }

    private static func text(_ value: JSONValue?) -> String {
        if case .string(let text)? = value { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }
}
