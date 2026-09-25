import Foundation

/// An approval's name in plain words, shared by the Today page and the
/// agent's home (2026-09-23). A skill proposal's own title is a tool sequence
/// ("Keep this as a skill: workspace → workspace"), which is not a name: say
/// what would be kept and from how many runs.
public enum ApprovalWords {
    public static func title(action: String, title: String, reason: String) -> String {
        guard action == "skill.proposal" else { return title }
        let tail = title.firstIndex(of: ":").map { title[title.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? ""
        if !tail.isEmpty, !tail.contains("→") { return "Save a repeatable step as a skill: \(tail)" }
        let steps = tail.components(separatedBy: "→").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var tools: [String] = []
        for step in steps where !tools.contains(step) { tools.append(step) }
        let routine = steps.isEmpty ? "a routine" : "a \(steps.count)-step \(tools.joined(separator: " + ")) routine"
        let runs = reason.firstMatch(of: /ran (\d+) times across (\d+) days?/).map { " I ran \($0.1) times over \($0.2) days" }
            ?? reason.firstMatch(of: /ran (\d+) times/).map { " I ran \($0.1) times" } ?? " I keep repeating"
        return "Save \(routine)\(runs) as a skill"
    }
}
