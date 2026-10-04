// NativeCognitionRuntime+Continuity.swift
// Phase 5 B (2026-10-03) — the local reads behind the two continuity cues.
// Every read here is on-device and fail-open: a missing or unreadable source
// contributes nothing, never a provider call, never a memory write.

import AgentConversations
import CognitiveSubstrate
import Desk
import Foundation
import os
import MemoryV2
import NativeAgentCore

extension NativeCognitionRuntime {
    // MARK: - B1 dream residue

    /// The newest diary's residue: up to five of its own theme lines, chosen
    /// and embedded with the local memory embedder. A CACHE, not memory: the
    /// next diary replaces it, and nothing reads it as something that happened.
    struct DreamThemeFile: Codable, Equatable {
        var diary: String
        var stamp: Double
        var phrases: [Phrase]
        struct Phrase: Codable, Equatable {
            var id: String
            var text: String
            var vector: [Float]
        }
    }

    /// A diary lives two and a half days after it is written: last night's
    /// dream, still faintly there the night after.
    nonisolated static let dreamThemeLife: TimeInterval = 60 * 3_600
    nonisolated static let dreamThemeMaxPhrases = 5
    /// Cosine floor between this message and a residue phrase (bge-large;
    /// calibrated on the diaries and User's messages of 09-26…10-03).
    nonisolated static let dreamThemeScoreFloor = 0.62

    nonisolated static func dreamThemeURL(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("cognition/dream_themes.json")
    }

    /// The residue phrases this message is close to, best first. Cheap by
    /// construction (Sol, 10-03): no living diary, or every phrase already
    /// spent (`excluding`), returns before any embedding; the embedder is used
    /// only when it is already warm, never loaded during turn preparation; and
    /// the message vector is kept for a recompile of the same turn.
    nonisolated static func dreamThemes(
        message: String,
        excluding: Set<String>,
        dataRoot: URL,
        now: Date,
        isWarm: @Sendable () async -> Bool,
        embed: @Sendable ([String]) async throws -> [[Float]]
    ) async -> [CognitiveDreamTheme] {
        guard let diary = livingDiary(dataRoot: dataRoot, now: now) else { return [] }
        let cached = cachedDreamTheme(dataRoot: dataRoot, diary: diary)
        if let cached, cached.phrases.allSatisfy({ excluding.contains($0.id) }) { return [] }
        guard await isWarm() else { return [] }
        var extracted = cached
        if extracted == nil { extracted = await extractDreamTheme(dataRoot: dataRoot, diary: diary, embed: embed) }
        guard var file = extracted, let query = await messageVector(message, embed: embed) else { return [] }
        // The embedder changed under the cache: extract again in its space.
        if file.phrases.contains(where: { $0.vector.count != query.count }) {
            guard let fresh = await extractDreamTheme(dataRoot: dataRoot, diary: diary, embed: embed) else { return [] }
            file = fresh
        }
        return file.phrases
            .filter { !excluding.contains($0.id) }
            .map { CognitiveDreamTheme(id: $0.id, text: $0.text, score: Double(cosine($0.vector, query))) }
            .filter { $0.score >= dreamThemeScoreFloor }
            .sorted { $0.score > $1.score }
    }

    /// One message vector, kept: the same turn recompiled asks again.
    private static let lastMessageVector = OSAllocatedUnfairLock<(String, [Float])?>(initialState: nil)

    nonisolated static func messageVector(
        _ message: String,
        embed: @Sendable ([String]) async throws -> [[Float]]
    ) async -> [Float]? {
        if let hit = lastMessageVector.withLock({ $0 }), hit.0 == message { return hit.1 }
        guard let vector = try? await embed([message]).first, !vector.isEmpty else { return nil }
        lastMessageVector.withLock { $0 = (message, vector) }
        return vector
    }

    struct LivingDiary: Sendable {
        let url: URL
        let name: String
        let written: Date
    }

    /// The newest diary, while it still lives.
    nonisolated static func livingDiary(dataRoot: URL, now: Date) -> LivingDiary? {
        let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let newest = names.filter({ $0.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil }).max()
        else { return nil }
        let url = dir.appendingPathComponent(newest)
        guard let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(written) < dreamThemeLife else { return nil }
        return LivingDiary(url: url, name: String(newest.dropLast(3)), written: written)
    }

    /// The cached themes, when they were extracted from exactly this diary.
    nonisolated static func cachedDreamTheme(dataRoot: URL, diary: LivingDiary) -> DreamThemeFile? {
        guard let data = try? Data(contentsOf: dreamThemeURL(dataRoot)),
              let cached = try? JSONDecoder().decode(DreamThemeFile.self, from: data),
              cached.diary == diary.name, cached.stamp == diary.written.timeIntervalSince1970 else { return nil }
        return cached
    }

    /// Extracted once per diary (keyed by file name and modification time),
    /// with the embedder already warm, then cached.
    nonisolated static func extractDreamTheme(
        dataRoot: URL,
        diary: LivingDiary,
        embed: @Sendable ([String]) async throws -> [[Float]]
    ) async -> DreamThemeFile? {
        guard let markdown = try? String(contentsOf: diary.url, encoding: .utf8) else { return nil }
        let (candidates, gist) = dreamThemeCandidates(markdown)
        guard !candidates.isEmpty, !gist.isEmpty,
              let vectors = try? await embed(candidates + [gist]),
              vectors.count == candidates.count + 1 else { return nil }
        // Which of her own themes sit closest to the night's whole entry: the
        // embedder picks, the diary supplies every word.
        let center = vectors[candidates.count]
        let kept = candidates.indices
            .sorted { cosine(vectors[$0], center) > cosine(vectors[$1], center) }
            .prefix(dreamThemeMaxPhrases)
            .sorted()
        let file = DreamThemeFile(
            diary: diary.name,
            stamp: diary.written.timeIntervalSince1970,
            phrases: kept.map { .init(id: "\(diary.name)#\($0 + 1)", text: candidates[$0], vector: vectors[$0]) })
        let cacheURL = dreamThemeURL(dataRoot)
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: cacheURL, options: .atomic) }
        return file
    }

    /// The diary's own theme lines, and its gist (title, entry and mood) to
    /// rank them against. A diary without themes offers its own sentences.
    nonisolated static func dreamThemeCandidates(_ markdown: String) -> (phrases: [String], gist: String) {
        var themes: [String] = []
        var gist: [String] = []
        var inThemes = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("**Emerging themes") { inThemes = true; continue }
            if inThemes {
                if line.hasPrefix("- ") { themes.append(String(line.dropFirst(2))); continue }
                if line.isEmpty { continue }
                inThemes = false
            }
            if line.hasPrefix("**"), line.hasSuffix("**"), !line.hasSuffix(":**") {
                gist.append(String(line.dropFirst(2).dropLast(2)))   // the title
            } else if line.hasPrefix("_Mood:") {
                gist.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "_")))
            } else if !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("_"), !line.hasPrefix("**"),
                      !line.hasPrefix("- "), gist.count < 3 {
                gist.append(line)
            }
        }
        let text = gist.joined(separator: " ")
        if themes.isEmpty {
            themes = text.components(separatedBy: ". ").filter { $0.count >= 30 }
        }
        return (themes.map { clipped($0, 160) }.filter { $0.count >= 8 }, clipped(text, 2_000))
    }

    // MARK: - B2 since we last talked

    /// What actually happened between `from` and `to`, as short items with
    /// real content, in order: a moment she kept, a Desk outcome, then what
    /// each trusted builder shipped, newest first. Nothing happened → [].
    nonisolated static func sinceGapItems(
        from: Date,
        to: Date,
        surface: String,
        dataRoot: URL,
        worklogURL: URL? = nil,
        codexURL: URL? = nil
    ) async -> [String] {
        var items: [String] = []
        let inGap: (Date?) -> Bool = { date in date.map { $0 > from && $0 <= to } ?? false }

        // A moment she kept from while he was away (her peer threads, mostly),
        // through the same disclosure rule recall applies on this surface.
        if let records = try? await SwiftNativeMemoryV2.resolvedOwner(dataRoot: dataRoot).listMemory(kind: "moment") {
            let kept = records.filter { record in
                (record.status ?? "active") == "active"
                    && inGap(MemoryMoments.parseTimestamp(record.observedAt ?? record.createdAt))
                    && MemoryRecordDisclosurePolicy.classify(record)?.permits(surface: surface, personaID: nil) == true
            }
            if let newest = kept.max(by: { $0.createdAt < $1.createdAt }) {
                items.append("a moment: \"\(clipped(newest.text, 90))\"")
            }
        }

        // A Desk outcome: an item finished in the gap that has a real title
        // (not a machine step like "A step from peer:…").
        if let state = try? await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() {
            let done = state.items
                .filter {
                    $0.status == .done && inGap($0.closedAt.flatMap(DeskClock.parseISO)) && isRealTitle($0.title)
                        && Reach.deskProvenanceTrusted($0, trusts: { PeerTrust.ownerTrusts($0, dataRoot: dataRoot) })
                }
                .sorted { ($0.closedAt ?? "") > ($1.closedAt ?? "") }
            if let first = done.first {
                items.append("Desk \"\(clipped(first.title, 70))\" done" + (done.count > 1 ? " (+\(done.count - 1) more)" : ""))
            }
        }

        // What the builders shipped (User, 10-03: their news is hers, and
        // through her his). One item per builder, newest first, the rest
        // counted. Only a builder User elevated in Trust speaks here: these are
        // its own words, and an un-elevated agent's must not be laundered into
        // her inner voice, so it is left out.
        let builders: [(name: String, lane: String, shipped: [(Date, String)])] = [
            ("Claude", "claude", claudeShipped(worklogURL ?? defaultClaudeWorklog())),
            ("Codex", "codex", codexShipped(codexURL ?? defaultCodexRecord())),
        ]
        let news = builders.compactMap { builder -> (Date, String)? in
            let inside = builder.shipped.filter { inGap($0.0) && $0.1.count >= 6 }
            guard let newest = inside.max(by: { $0.0 < $1.0 }),
                  PeerTrust.ownerTrusts(builder.lane, dataRoot: dataRoot) else { return nil }
            return (newest.0, "\(builder.name) shipped \"\(newest.1)\""
                + (inside.count > 1 ? " (+\(inside.count - 1) more)" : ""))
        }
        items += news.sorted { $0.0 > $1.0 }.map(\.1)
        return items
    }

    nonisolated static func defaultClaudeWorklog() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/state/claude-worklog.jsonl")
    }

    /// Claude's worklog: shipped features and fixes, headline only.
    nonisolated static func claudeShipped(_ url: URL, kinds: Set<String> = ["feature", "fix"]) -> [(Date, String)] {
        claudeWorklogTail(url).compactMap { object -> (Date, String)? in
            guard kinds.contains(object["kind"] as? String ?? ""),
                  let at = MemoryMoments.parseTimestamp(object["ts"] as? String),
                  let summary = object["summary"] as? String else { return nil }
            return (at, headline(summary))
        }
    }

    /// Phase 5 E1: Claude's newest worklog line of any kind — User is
    /// probably working with her.
    nonisolated static func claudeLastActivity(_ url: URL) -> Date? {
        claudeWorklogTail(url).compactMap { MemoryMoments.parseTimestamp($0["ts"] as? String) }.max()
    }

    nonisolated static func claudeWorklogTail(_ url: URL) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return tail.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// Codex's own record of its work (the handoff the `codex.work_journal`
    /// connector reads): `~/CODEX_HANDOFF.md`, else `~/CODEX_HANDOFF_FOR_*.md`.
    nonisolated static func defaultCodexRecord() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let generic = home.appendingPathComponent("CODEX_HANDOFF.md")
        if FileManager.default.fileExists(atPath: generic.path) { return generic }
        let named = (try? FileManager.default.contentsOfDirectory(atPath: home.path))?
            .filter { $0.hasPrefix("CODEX_HANDOFF_FOR_") && $0.hasSuffix(".md") && !$0.contains("ARCHIVE") }
            .sorted().first
        return named.map { home.appendingPathComponent($0) } ?? generic
    }

    /// Entries shaped `### 2026-09-30 11:38 MDT - Title` followed by a
    /// `Status: completed|committed…` line: what Codex finished, titled.
    nonisolated static func codexShipped(_ url: URL) -> [(Date, String)] {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var out: [(Date, String)] = []
        var pending: (Date, String)?
        for raw in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                pending = nil
                let parts = line.dropFirst(4).components(separatedBy: " - ")
                guard parts.count >= 2 else { continue }
                var when: Date?
                for format in ["yyyy-MM-dd HH:mm zzz", "yyyy-MM-dd HH:mm"] where when == nil {
                    formatter.dateFormat = format
                    when = formatter.date(from: parts[0].trimmingCharacters(in: .whitespaces))
                }
                if let when { pending = (when, clipped(parts.dropFirst().joined(separator: " - "), 70)) }
            } else if line.lowercased().hasPrefix("status:"), let entry = pending {
                let status = line.dropFirst(7).trimmingCharacters(in: .whitespaces).lowercased()
                if status.hasPrefix("completed") || status.hasPrefix("committed") { out.append(entry) }
                pending = nil
            }
        }
        return out
    }

    nonisolated static func isRealTitle(_ title: String) -> Bool {
        title.count >= 8
            && title.range(of: #"peer:|[0-9a-f]{8}-[0-9a-f]{4}|\btest\b|delete me"#,
                           options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// A worklog summary's headline: up to its first "(" or ":", clipped.
    nonisolated static func headline(_ summary: String) -> String {
        let head = summary.split(whereSeparator: { $0 == "(" || $0 == ":" }).first.map(String.init) ?? summary
        return clipped(head.trimmingCharacters(in: .whitespaces), 70)
    }

    // MARK: - Small helpers

    nonisolated static func clipped(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit - 1)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}
