#!/usr/bin/env swift
import Foundation
import Darwin

// Only marked table bodies are generated. Headings, prose and policy stay put.
let arguments = Array(CommandLine.arguments.dropFirst())
let check = arguments.contains("--check")
let repoIndex = arguments.firstIndex(of: "--repo")
// realpath, not resolvingSymlinksInPath: Foundation maps /private/tmp back to
// /tmp, while the enumerator hands back /private/tmp paths.
let repo = URL(fileURLWithPath: realpath(repoIndex.map { arguments[$0 + 1] } ?? FileManager.default.currentDirectoryPath, nil)
    .map { defer { free($0) }; return String(cString: $0) } ?? FileManager.default.currentDirectoryPath)
let document = repo.appendingPathComponent("docs/ARCHITECTURE_BLUEPRINT.md")
let original = try String(contentsOf: document, encoding: .utf8)
struct Scope: Decodable { let blueprintRoots: [String] }
let policy = original.components(separatedBy: "```json architecture-policy\n")
guard policy.count == 2 else { fatalError("expected one architecture-policy block") }
let scope = try JSONDecoder().decode(Scope.self, from: Data(policy[1].components(separatedBy: "\n```")[0].utf8))
var rows: [String: String] = [:]
var missing: [String] = []
// Her parts are hers byte for byte (a changed turn.js stops matching its shipped
// digest, and upgrades stop): a part's row is its own header's declaration.
func partRow(_ file: URL, _ text: String) -> String? {
    guard let open = text.range(of: "/*"), let close = text.range(of: "*/", range: open.upperBound..<text.endIndex),
          let brace = text[open.upperBound..<close.lowerBound].firstIndex(of: "{"),
          let json = try? JSONSerialization.jsonObject(with: Data(text[brace..<close.lowerBound].utf8)) as? [String: Any] else { return nil }
    let id = json["id"] as? String ?? file.deletingPathExtension().lastPathComponent
    let declared = (json["record"] as? [String: Any])?["description"] as? String
        ?? text[close.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).drop { !$0.hasPrefix("// ") }
            .prefix { $0.hasPrefix("// ") }.map { $0.dropFirst(3) }.joined(separator: " ")
    var words = declared.trimmingCharacters(in: .whitespaces)
    guard !words.isEmpty else { return nil }
    // One sentence: the second when the first is only a name ("Her turn.").
    if let stop = words.range(of: ". ") {
        let rest = words[stop.upperBound...]
        let next = rest.range(of: ". ").map { rest[..<$0.lowerBound] + "." } ?? rest
        words = stop.lowerBound.utf16Offset(in: words) < 24 ? String(next) : String(words[..<stop.lowerBound]) + "."
    }
    return "| `\(file.lastPathComponent)` | \(json["kind"] as? String ?? "part") `\(id)`: \(words.replacingOccurrences(of: "|", with: "/")) |"
}
for root in scope.blueprintRoots {
    let files = FileManager.default.enumerator(at: repo.appendingPathComponent(root), includingPropertiesForKeys: nil)!
    for case let file as URL in files {
        if [".build", "Tests", "tests"].contains(file.lastPathComponent) { files.skipDescendants(); continue }
        guard ["swift", "js", "sh", "rb", "py", "yml", "yaml"].contains(file.pathExtension) else { continue }
        let path = String(file.path.dropFirst(repo.path.count + 1))
        let prefix = ["sh", "rb", "py", "yml", "yaml"].contains(file.pathExtension) ? "# Blueprint: " : "// Blueprint: "
        if file.pathExtension == "js", root == "Resources/abilities" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard !text.contains("// Blueprint: ") else { fatalError("parts carry no Blueprint line: \(path)") }
            if let row = partRow(file, text) { rows[path] = row } else { missing.append(path) }
            continue
        }
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        let headers = lines.filter { $0.hasPrefix(prefix) }
        guard headers.count <= 1 else { fatalError("multiple Blueprint lines: \(file.path)") }
        if let header = headers.first {
            let row = String(header.dropFirst(prefix.count))
            guard row.hasPrefix("| `\(file.lastPathComponent)` | ") || row.hasPrefix("| `\(path)` | "), row.hasSuffix(" |") else {
                fatalError("Blueprint row must name its own file: \(path)")
            }
            rows[path] = row
        } else if (file.pathExtension == "swift" && (path.hasPrefix("Modules/") || path.hasPrefix("Sources/")))
                    || (file.pathExtension == "js" && root == "Resources/abilities") {
            missing.append(path)
        }
    }
}
if !missing.isEmpty {
    fputs("[blueprint] missing source-owned Blueprint headers:\n" + missing.sorted().joined(separator: "\n") + "\n", stderr)
    exit(1)
}
let begin = "<!-- BEGIN GENERATED BLUEPRINT: "
let end = "<!-- END GENERATED BLUEPRINT -->"
var output: [String] = []
var selected: Set<String> = []
var inside = false
var body: [String] = []
var generatedRows: [String] = []
for line in original.components(separatedBy: "\n") {
    if line.hasPrefix(begin), line.hasSuffix(" -->") {
        guard !inside else { fatalError("nested Blueprint region") }
        inside = true
        output.append(line)
        body = []
        generatedRows = []
        // Directories select basename rows; path globs split existing family tables.
        let selectors = line.dropFirst(begin.count).dropLast(4).split(separator: " ").map(String.init)
        for path in rows.keys.sorted() {
            let directory = (path as NSString).deletingLastPathComponent + "/"
            let qualified = rows[path]!.hasPrefix("| `\(path)` | ")
            let included = selectors.filter { !$0.hasPrefix("!") }.contains {
                (!qualified && $0 == directory) || fnmatch($0, path, FNM_PATHNAME) == 0
            }
            let excluded = selectors.filter { $0.hasPrefix("!") }.contains {
                fnmatch(String($0.dropFirst()), path, FNM_PATHNAME) == 0
            }
            if included && !excluded {
                guard selected.insert(path).inserted else { fatalError("Blueprint file selected twice: \(path)") }
                generatedRows.append(rows[path]!)
            }
        }
    } else if line == end {
        guard inside else { fatalError("unmatched Blueprint end marker") }
        inside = false
        var inserted = false
        for row in body {
            if row.range(of: #"^\| `[^`]+\.[^`/]+` \|"#, options: .regularExpression) != nil {
                if !inserted { output += generatedRows; inserted = true }
            } else {
                output.append(row)
            }
        }
        if !inserted { output += generatedRows }
        output.append(line)
    } else if inside {
        body.append(line)
    } else {
        output.append(line)
    }
}
guard !inside, selected == Set(rows.keys) else { fatalError("unclosed region or unplaced Blueprint lines: \(Set(rows.keys).subtracting(selected).sorted())") }
let generated = output.joined(separator: "\n")
if check {
    guard generated == original else {
        fputs("[blueprint] generated tables differ; run swift script/generate_architecture_blueprint.swift\n", stderr)
        exit(1)
    }
} else if generated != original {
    try generated.write(to: document, atomically: true, encoding: .utf8)
}
print("[blueprint] \(check ? "checked" : "generated") \(selected.count) source-owned rows")
