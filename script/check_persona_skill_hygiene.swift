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

            Checks tracked persona templates and shipped skill guidance for exact retired mechanisms.
            Never reads live persona identity or runtime-generated guidance.
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

let options = parseOptions()
let patterns = try [
    makePattern("native_agentd", #"native_agentd"#),
    makePattern("old local port", #"127\.0\.0\.1:8765|:8765\b|\b8766\b"#),
    makePattern("old tool proposal route", #"/v1/tools/propose"#),
    makePattern("old introspection tool names", #"daemon_introspect|daemon_status|daemon_logs"#),
]

let listing = Process()
listing.executableURL = URL(fileURLWithPath: "/usr/bin/git")
listing.arguments = ["-C", options.repo.path, "ls-files", "-z", "--",
                     "persona/*.template.md", "persona/skills/bodies/*.md"]
let output = Pipe()
listing.standardOutput = output
try listing.run()
let paths = output.fileHandleForReading.readDataToEndOfFile()
listing.waitUntilExit()
guard listing.terminationStatus == 0 else { fatalError("cannot list tracked persona guidance") }
let scanFiles = String(decoding: paths, as: UTF8.self).split(separator: "\0")
    .map { options.repo.appendingPathComponent(String($0)) }
guard !scanFiles.isEmpty else { fatalError("no tracked persona guidance found") }

var violations: [String] = []

for file in scanFiles {
    let text = try String(contentsOf: file, encoding: .utf8)
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
            violations.append("\(relative):\(line): retired mechanism: \(pattern.label)")
        }
    }
}

if !violations.isEmpty {
    fputs("[persona] ERROR: shipped guidance hygiene violation\n", stderr)
    for violation in violations {
        fputs("  \(violation)\n", stderr)
    }
    exit(1)
}

print("[persona] hygiene check passed (\(scanFiles.count) tracked templates/guidance files)")
