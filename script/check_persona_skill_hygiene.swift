#!/usr/bin/env swift

import Foundation

struct Options {
    var repo: URL
}

struct BannedPattern {
    let label: String
    let regex: NSRegularExpression
}

func parseOptions() -> Options {
    var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--repo":
            guard !args.isEmpty else {
                fatalError("--repo requires a path")
            }
            repo = URL(fileURLWithPath: args.removeFirst())
        case "--help", "-h":
            print("""
            Persona hygiene check

            Usage:
              script/check_persona_skill_hygiene.swift [--repo PATH]

            Checks active persona docs, persona skill bodies, and runtime-generated skill bodies for stale assumptions.
            Historical workspace notes may mention retired paths; live persona context may not.
            """)
            exit(0)
        default:
            fatalError("unknown argument: \(arg)")
        }
    }
    return Options(repo: repo)
}

func makePattern(_ label: String, _ pattern: String) throws -> BannedPattern {
    BannedPattern(
        label: label,
        regex: try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    )
}

func lineNumber(for location: Int, in text: String) -> Int {
    var line = 1
    var utf16Index = 0
    for scalar in text.unicodeScalars {
        if utf16Index >= location { break }
        if scalar == "\n" { line += 1 }
        utf16Index += scalar.utf16.count
    }
    return line
}

func firstNonEmptyLine(in text: String) -> String? {
    text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

func firstUsefulBodyLine(in text: String) -> String? {
    text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty && !$0.hasPrefix("#") }
}

func markdownFiles(in dir: URL, required: Bool, label: String) -> [URL] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        if required {
            fputs("[persona] ERROR: missing \(label) directory: \(dir.path)\n", stderr)
            exit(1)
        }
        return []
    }
    return files
        .filter { $0.pathExtension == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

let options = parseOptions()
let patterns = try [
    makePattern("python", #"\bpython\b"#),
    makePattern("daemon", #"\bdaemons?\b"#),
    makePattern("native_agentd", #"native_agentd"#),
    makePattern("old local port", #"127\.0\.0\.1:8765|:8765\b|\b8766\b"#),
    makePattern("old tool proposal route", #"/v1/tools/propose"#),
    makePattern("python cache artifact", #"\.pyc\b|\.pyo\b|__pycache__"#),
    makePattern("old introspection tool names", #"daemon_introspect|daemon_status|daemon_logs"#),
]

let fm = FileManager.default
let personaDir = options.repo.appendingPathComponent("persona", isDirectory: true)
let livePersonaFiles = [
    "SOUL.md",
    "VOICE.md",
    "AGENTS.md",
    "SOUL.template.md",
    "AGENTS.template.md",
]
    .map { personaDir.appendingPathComponent($0) }
    .filter { fm.fileExists(atPath: $0.path) }

let bodiesDir = personaDir
    .appendingPathComponent("skills", isDirectory: true)
    .appendingPathComponent("bodies", isDirectory: true)
let runtimeBodiesDir = options.repo
    .appendingPathComponent("data", isDirectory: true)
    .appendingPathComponent("skills", isDirectory: true)
    .appendingPathComponent("bodies", isDirectory: true)

let personaSkillBodyFiles = markdownFiles(in: bodiesDir, required: true, label: "persona skill bodies")
let runtimeSkillBodyFiles = markdownFiles(in: runtimeBodiesDir, required: false, label: "runtime skill bodies")
let scanFiles = (livePersonaFiles + personaSkillBodyFiles + runtimeSkillBodyFiles)

var violations: [String] = []

for file in scanFiles {
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    let relative = file.path.replacingOccurrences(of: options.repo.path + "/", with: "")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        violations.append("\(relative):1: empty skill body")
        continue
    }
    if let first = firstNonEmptyLine(in: text), !first.hasPrefix("#") {
        violations.append("\(relative):1: first non-empty line must be a markdown heading")
    }
    if firstUsefulBodyLine(in: text) == nil {
        violations.append("\(relative):1: skill body must include non-heading guidance")
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for pattern in patterns {
        for match in pattern.regex.matches(in: text, range: range) {
            let line = lineNumber(for: match.range.location, in: text)
            violations.append("\(relative):\(line): stale active-skill term: \(pattern.label)")
        }
    }
}

if !violations.isEmpty {
    fputs("[persona] ERROR: stale active persona context detected\n", stderr)
    for violation in violations {
        fputs("  \(violation)\n", stderr)
    }
    exit(1)
}

print("[persona] hygiene check passed (\(livePersonaFiles.count) live docs, \(personaSkillBodyFiles.count) persona skill bodies, \(runtimeSkillBodyFiles.count) runtime skill bodies)")
