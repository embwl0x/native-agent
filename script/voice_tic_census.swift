#!/usr/bin/env swift
import Foundation

// Voice tic census: measures LLM-ism density in Agent's assistant messages.
//
// Run before/after VOICE.md speech changes to verify that the density moved.
// Usage: script/voice_tic_census.swift [--days 14]

struct TicPattern {
    let name: String
    let regex: NSRegularExpression
}

let ticPatterns: [TicPattern] = [
    ("em-dash", #"—"#),
    ("*starred emphasis*", #"\*[a-z][^*]{2,40}\*"#),
    ("genuinely", #"\bgenuinely\b"#),
    ("honestly", #"\bhonestly\b"#),
    ("it's not X, it's Y flip", #"(?:isn'?t|not) (?:a |an |the )?\w+ *[—,-]+ *(?:it'?s|that'?s)"#),
    ("load-bearing", #"\bload[- ]bearing\b"#),
    ("literally", #"\bliterally\b"#),
    ("solid (adj)", #"\bsolid\b"#),
    ("that tracks", #"\bthat tracks\b"#),
    ("here's the thing", #"here'?s the thing"#),
    ("great question", #"\bgreat question\b"#),
    ("certainly", #"\bcertainly\b"#),
    ("absolutely", #"\babsolutely\b"#),
    ("vibe(s)", #"\b(banger|vibes?|vibing)\b"#),
].map { name, pattern in
    TicPattern(
        name: name,
        regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    )
}

func usage() {
    print("Usage: script/voice_tic_census.swift [--days 14]")
}

func parseDays(_ args: [String]) -> Int? {
    var days = 14
    var index = 1
    while index < args.count {
        let arg = args[index]
        if arg == "--help" || arg == "-h" {
            usage()
            exit(0)
        }
        guard arg == "--days", index + 1 < args.count, let parsed = Int(args[index + 1]), parsed > 0 else {
            return nil
        }
        days = parsed
        index += 2
    }
    return days
}

guard let days = parseDays(CommandLine.arguments) else {
    usage()
    exit(2)
}

let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let messagesDir = repo
    .appendingPathComponent("data", isDirectory: true)
    .appendingPathComponent("chat", isDirectory: true)
    .appendingPathComponent("messages", isDirectory: true)
let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)

let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let isoFormatterNoFraction = ISO8601DateFormatter()
isoFormatterNoFraction.formatOptions = [.withInternetDateTime]

func parseDate(_ raw: String) -> Date? {
    if let date = isoFormatter.date(from: raw) {
        return date
    }
    if let date = isoFormatterNoFraction.date(from: raw) {
        return date
    }
    let normalized = raw.hasSuffix("Z") ? String(raw.dropLast()) : raw
    let fallback = DateFormatter()
    fallback.locale = Locale(identifier: "en_US_POSIX")
    fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return fallback.date(from: normalized)
}

func jsonlFiles(in directory: URL) -> [URL] {
    guard let walker = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    return walker.compactMap { entry -> URL? in
        guard let url = entry as? URL, url.pathExtension == "jsonl" else {
            return nil
        }
        return url
    }
}

var messages: [String] = []
for url in jsonlFiles(in: messagesDir) {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        continue
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard
            let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            obj["role"] as? String == "assistant",
            let content = obj["content"] as? String,
            !content.isEmpty,
            let rawDate = obj["createdAt"] as? String,
            let createdAt = parseDate(rawDate),
            createdAt >= cutoff
        else {
            continue
        }
        messages.append(content)
    }
}

guard !messages.isEmpty else {
    print("no assistant messages in window")
    exit(0)
}

var counts: [String: Int] = [:]
for content in messages {
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    for pattern in ticPatterns {
        counts[pattern.name, default: 0] += pattern.regex.numberOfMatches(in: content, range: range)
    }
}

let wordCount = messages.reduce(0) { total, message in
    total + message.split(whereSeparator: \.isWhitespace).count
}

print("\(messages.count) assistant messages / \(wordCount) words, last \(days) days\n")
for (name, count) in counts.sorted(by: { lhs, rhs in
    if lhs.value == rhs.value {
        return lhs.key < rhs.key
    }
    return lhs.value > rhs.value
}) {
    let paddedName = name.padding(toLength: 28, withPad: " ", startingAt: 0)
    print(String(format: "  %@ %5d  (%.2f/msg)", paddedName, count, Double(count) / Double(messages.count)))
}
