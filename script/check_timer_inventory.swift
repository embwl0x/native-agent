#!/usr/bin/env swift
import Foundation

enum TimerInventoryError: Error, CustomStringConvertible {
    case usage(String)
    case invalidRule(String)
    case duplicateMatch(String)
    case unclassified(String)
    case countMismatch(String)

    var description: String {
        switch self {
        case .usage(let value), .invalidRule(let value), .duplicateMatch(let value),
             .unclassified(let value), .countMismatch(let value):
            return value
        }
    }
}

struct Rule {
    let path: String
    let needle: String
    let expectedCount: Int
    let classification: String
    let owner: String
}

let validClasses: Set<String> = [
    "external_protocol_poll",
    "timeout_retry_deadline",
    "user_schedule",
    "visible_ui",
    "integrity_sweep",
    "event_deadline",
]
let primitiveNeedles = [
    "Task.sleep(",
    "Task.sleep(for:",
    "Thread.sleep(",
    "usleep(",
    ".asyncAfter(",
    "Timer.publish(",
    "Timer.scheduledTimer(",
    "DispatchSource.makeTimerSource(",
]

func normalized(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\t", with: " ")
}

func productionFiles(repo: URL) -> [URL] {
    let roots = [
        "Sources/NativeAgentApp",
        "Modules/NativeAgentCore/Sources",
        "iOS/NativeAgentMobile/Sources",
    ]
    let fm = FileManager.default
    return roots.flatMap { relative -> [URL] in
        let root = repo.appendingPathComponent(relative, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }.sorted { $0.path < $1.path }
}

func occurrences(repo: URL) -> [(path: String, line: Int, source: String)] {
    let canonicalRepo = repo.resolvingSymlinksInPath().standardizedFileURL
    let repoPrefix = canonicalRepo.path.hasSuffix("/")
        ? canonicalRepo.path
        : canonicalRepo.path + "/"
    return productionFiles(repo: repo).flatMap { file -> [(String, Int, String)] in
        guard let body = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalFile.hasPrefix(repoPrefix) else { return [] }
        let relative = String(canonicalFile.dropFirst(repoPrefix.count))
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { offset, raw in
                let line = normalized(String(raw))
                guard !line.hasPrefix("//"),
                      primitiveNeedles.contains(where: line.contains) else { return nil }
                return (relative, offset + 1, line)
            }
    }
}

func loadRules(_ path: URL) throws -> [Rule] {
    let raw = try String(contentsOf: path, encoding: .utf8)
    return try raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { row in
        if row.hasPrefix("#") { return nil }
        let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5,
              let count = Int(fields[2]), count > 0,
              validClasses.contains(fields[3]),
              !fields[0].isEmpty, !fields[1].isEmpty, !fields[4].isEmpty else {
            throw TimerInventoryError.invalidRule("invalid timer inventory row: \(row)")
        }
        return Rule(
            path: fields[0], needle: fields[1], expectedCount: count,
            classification: fields[3], owner: fields[4]
        )
    }
}

let arguments = CommandLine.arguments.dropFirst()
var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var printCandidates = false
var iterator = arguments.makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--repo":
        guard let value = iterator.next() else {
            throw TimerInventoryError.usage("--repo requires a path")
        }
        repo = URL(fileURLWithPath: value).standardizedFileURL
    case "--print-candidates": printCandidates = true
    default: throw TimerInventoryError.usage("unknown argument: \(argument)")
    }
}

let found = occurrences(repo: repo)
if printCandidates {
    for item in found {
        print("\(item.path):\(item.line)\t\(item.source)")
    }
    exit(0)
}

let manifest = repo.appendingPathComponent("script/timer_inventory.tsv")
do {
    let rules = try loadRules(manifest)
    var counts = Array(repeating: 0, count: rules.count)
    for item in found {
        let matches = rules.indices.filter {
            rules[$0].path == item.path
                && (rules[$0].needle == "*" || item.source.contains(rules[$0].needle))
        }
        guard matches.count == 1 else {
            let location = "\(item.path):\(item.line): \(item.source)"
            if matches.isEmpty { throw TimerInventoryError.unclassified("unclassified production timer: \(location)") }
            throw TimerInventoryError.duplicateMatch("timer matches multiple inventory rows: \(location)")
        }
        counts[matches[0]] += 1
    }
    for (index, rule) in rules.enumerated() where counts[index] != rule.expectedCount {
        throw TimerInventoryError.countMismatch(
            "timer inventory count changed for \(rule.path) [\(rule.needle)]: "
                + "expected \(rule.expectedCount), found \(counts[index])"
        )
    }
    let classes = Set(rules.map(\.classification)).sorted().joined(separator: ", ")
    print("[timers] classified \(found.count) production timer/sleep sites across \(rules.count) ownership rules (\(classes))")
} catch {
    fputs("[timers] ERROR: \(error)\n", stderr)
    exit(1)
}
