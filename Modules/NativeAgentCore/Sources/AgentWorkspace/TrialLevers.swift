import AuthoredCapabilities
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
// Blueprint: | `TrialLevers.swift` | `TrialLevers`: the night's trials as the person's levers, one producer for every page that draws them (Home, Today) |

/// A part of the agent's on trial, with the agent's why and Set aside: the person's own forward revision of it, one tap at any posture, back to
/// the version the trial keeps. A trial kept or set aside within a day shows its verdict; a superseded one does not show. Every page that draws
/// the person's levers draws these rows, so wherever the person is, the lever is.
public enum TrialLevers {
    /// A part's open trial (`verdict` nil), or its latest closed one with its verdict, when and by whom, as the stem's record holds it.
    public struct Line: Sendable {
        let part: String
        let why: String
        let opened: String
        let verdict: String?
        let closed: Date?
        let by: String?
        let setAsideWhy: String?
    }

    /// A trial closed this long ago still shows, kept or set aside.
    static let shown: TimeInterval = 86_400
    public static let sectionID = "night", sectionTitle = "Trying a change"

    /// The stem's trial record: one line per part with an open trial or a closed one; when a closed one still shows is `rows`'s to judge.
    public static func read(dataRoot: URL) throws -> [Line] {
        try AbilityStore(dataRoot: dataRoot).states().sorted { $0.key < $1.key }.compactMap { id, value -> Line? in
            let row = value.objectValue
            if let open = row?["trial"]?.objectValue {
                return Line(part: id, why: open["why"]?.stringValue ?? "", opened: open["opened"]?.stringValue ?? "", verdict: nil, closed: nil,
                    by: nil, setAsideWhy: nil)
            }
            guard let last = row?["trials"]?.arrayValue?.last?.objectValue,
                  let closed = last["closed"]?.stringValue.flatMap(NativeTimestampFormat.parseISO8601) else { return nil }
            return Line(part: id, why: last["why"]?.stringValue ?? "", opened: last["opened"]?.stringValue ?? "", verdict: last["verdict"]?.stringValue,
                closed: closed, by: last["by"]?.stringValue, setAsideWhy: last["set_aside_why"]?.stringValue)
        }
    }

    /// Only trial fields identify this reading; run counters in the same file are not trial changes.
    public static func reading(dataRoot: URL) throws -> JSONValue {
        .array(try read(dataRoot: dataRoot).map { line in
            .object(["part": .string(line.part), "why": .string(line.why), "opened": .string(line.opened),
                "verdict": line.verdict.map(JSONValue.string) ?? .null, "closed": line.closed.map { .double($0.timeIntervalSince1970) } ?? .null,
                "by": line.by.map(JSONValue.string) ?? .null, "setAsideWhy": line.setAsideWhy.map(JSONValue.string) ?? .null])
        })
    }

    /// The rows for `lines`, worded with the agent's `name`.
    public static func rows(_ lines: [Line], agent name: String, now: Date) -> [PartFace.Row] {
        lines.compactMap { trial -> PartFace.Row? in
            let part = trial.part == "turn" ? "its turn program" : trial.part
            guard let verdict = trial.verdict else {
                let aside = PartFace.Call("ability.save", ["id": .string(trial.part), "set_aside": .bool(true),
                    "why": .string("The person set it aside.")])
                return PartFace.Row(id: "trial:" + trial.part, title: "\(name) is trying a change to \(part)",
                    detail: AgentScreen.clip(ContextSecretContentPolicy.redactedFragment(trial.why), 160), value: "On trial",
                    at: NativeTimestampFormat.parseISO8601(trial.opened).map { $0.formatted(.iso8601) }, tone: .attention,
                    actions: [.init(id: "set_aside", label: "Set aside", role: .destructive, call: aside)])
            }
            guard let closed = trial.closed, now.timeIntervalSince(closed) < Self.shown, verdict == "kept" || verdict == "set_aside" else {
                return nil
            }
            let kept = verdict == "kept"
            let value = kept ? "Kept" : trial.by == "person" ? "You set it aside" : trial.by == "agent" ? "\(name) set it aside" : "Set aside"
            return PartFace.Row(id: "trial:" + trial.part, title: (kept ? "Kept the change to " : "Set aside the change to ") + part,
                detail: AgentScreen.clip(ContextSecretContentPolicy.redactedFragment(kept ? trial.why : trial.setAsideWhy ?? trial.why), 160),
                value: value, at: closed.formatted(.iso8601),
                tone: kept ? .done : .quiet)
        }
    }

    /// The section a page's levers carry: the rows, or the stem's words for a record that did not read; nil when there is nothing to show.
    public static func section(_ read: Result<[Line], Error>, agent name: String, now: Date) -> PartFace.Section? {
        let rows: [PartFace.Row]
        switch read {
        case .success(let lines): rows = Self.rows(lines, agent: name, now: now)
        case .failure(let error):
            rows = [.init(id: "trials:failed", title: "Trials unavailable", detail: "The trial record did not read: "
                + ContextSecretContentPolicy.redactedFragment(error.localizedDescription),
                tone: .failed)]
        }
        return rows.isEmpty ? nil : .init(id: Self.sectionID, title: Self.sectionTitle, style: .list, rows: rows)
    }
}
