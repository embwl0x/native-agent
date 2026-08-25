#!/usr/bin/env swift
import Foundation

// Swift companion for opus5_baseline_report.sh.  It keeps the report's JSONL
// parsing in the project's runtime language instead of hiding Python heredocs
// inside a shell report.

enum ReportError: Error, CustomStringConvertible {
    case usage
    case unreadable(URL, Error)

    var description: String {
        switch self {
        case .usage:
            return "Usage: opus5_baseline_report.swift <models|circulation|morning-brief|loop-failures> <data-root>"
        case let .unreadable(url, error):
            return "cannot read \(url.path): \(error.localizedDescription)"
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    fputs("\(ReportError.usage)\n", stderr)
    exit(2)
}

let command = arguments[0]
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
let fileManager = FileManager.default

func jsonl(_ url: URL) throws -> [[String: Any]] {
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    let contents: String
    do {
        contents = try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw ReportError.unreadable(url, error)
    }
    return contents.split(whereSeparator: \.isNewline).compactMap { line in
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

func string(_ value: Any?) -> String? { value as? String }
func display(_ value: Any?) -> String { string(value) ?? "?" }

func recentTraceFiles() throws -> [URL] {
    let directory = root.appendingPathComponent("data/turn_traces", isDirectory: true)
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    do {
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(2)
            .map { $0 }
    } catch {
        throw ReportError.unreadable(directory, error)
    }
}

func runModels() throws {
    var counts: [String: Int] = [:]
    for trace in try recentTraceFiles() {
        for row in try jsonl(trace) where string(row["kind"]) == "context.snapshot" {
            let payload = row["payload"] as? [String: Any]
            let key = "\(display(row["surface"]))\u{1F}\(display(payload?["model"]))"
            counts[key, default: 0] += 1
        }
    }
    if counts.isEmpty {
        print("  (no context.snapshot rows in the two newest traces)")
        return
    }
    for (key, count) in counts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
        let fields = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        print(String(format: "  %-10@ %-22@ %d turns", fields[0] as NSString, fields[1] as NSString, count))
    }
}

func runCirculation() throws {
    var rows: [(String, String, String, String)] = []
    for trace in try recentTraceFiles() {
        for row in try jsonl(trace) where string(row["kind"]) == "context.summary" {
            let payload = row["payload"] as? [String: Any]
            let counts = payload?["counts"] as? [String: Any]
            rows.append((display(row["ts"]), display(counts?["contextFlow.memoryRecords"]), display(counts?["contextFlow.selectedAtoms"]), display(counts?["persona.docCount"])))
        }
    }
    print("  ts                    memRecords atoms personaDocs")
    for (timestamp, memory, atoms, docs) in rows.suffix(12) {
        let trimmed = String(timestamp.prefix(19))
        print(String(format: "  %-19@ %9@ %6@ %10@", trimmed as NSString, memory as NSString, atoms as NSString, docs as NSString))
    }
    print("  (memRecords was 0 on EVERY turn 07-15..07-24 while the lane was dead)")
}

func runMorningBrief() throws {
    let inbox = root.appendingPathComponent("data/notifications/inbox.jsonl")
    let wanted: Set<String> = ["trigger:morning_brief", "agent_morning_warmup", "dream_cycle", "rem_cycle"]
    let briefs = try jsonl(inbox).filter { wanted.contains(string($0["source"]) ?? "") }
    if briefs.isEmpty {
        print("  (no morning_brief card found)")
    }
    for brief in briefs.suffix(2) {
        print("  \(display(brief["created_at"]))  status=\(display(brief["status"]))  \(display(brief["title"]))")
        print("    \(String((string(brief["summary"]) ?? "").prefix(300)))")
    }
}

func runLoopFailures() throws {
    let failures = root.appendingPathComponent("data/logs/background_loop_failures.jsonl")
    let recent = try jsonl(failures).filter { row in
        let date = string(row["createdAt"]) ?? string(row["pushedAt"]) ?? ""
        return date >= "2026-07-24T20"
    }
    print("  \(recent.count) failure/push receipts since 20:00")
    for row in recent.suffix(8) {
        let date = string(row["createdAt"]) ?? string(row["pushedAt"]) ?? "?"
        print("    \(date)  \(display(row["loopId"]))  \(display(row["kind"]))  \(String((string(row["error"]) ?? "").prefix(70)))")
    }
}

do {
    switch command {
    case "models": try runModels()
    case "circulation": try runCirculation()
    case "morning-brief": try runMorningBrief()
    case "loop-failures": try runLoopFailures()
    default: throw ReportError.usage
    }
} catch {
    fputs("opus5 baseline report: \(error)\n", stderr)
    exit(1)
}
