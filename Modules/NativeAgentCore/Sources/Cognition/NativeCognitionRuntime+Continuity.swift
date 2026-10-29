// On-device cue reads distinguish absent sources from unreadable evidence;
// neither invokes a provider or writes a memory.

import AgentConversations
import ChatTurnRuntime
import CognitiveSubstrate
import Desk
import DreamREMCycle
import Foundation
import os
import MemoryV2
import NativeAgentCore
import PersistenceCore
import NativeAgentShared

// Blueprint: | `NativeCognitionRuntime+Continuity.swift` | `NativeCognitionRuntime` continuity reads: dream residue, local gap cues and builder activity; absent and unreadable sources remain distinct |

extension NativeCognitionRuntime {
    // MARK: - Dream residue

    /// The newest diary's residue: up to five of its own theme lines, chosen
    /// and embedded with the local memory embedder. A CACHE, not memory: the
    /// next diary replaces it, and nothing reads it as something that happened.
    struct DreamThemeFile: Codable, Equatable, Sendable {
        var diary: String
        var stamp: Double
        var root: String?
        var epoch: MemoryEmbeddingEpoch?
        var phrases: [Phrase]
        struct Phrase: Codable, Equatable, Sendable {
            var id: String
            var text: String
            var vector: [Float]
        }
    }

    /// A diary lives two and a half days after it is written: last night's
    /// dream, still faintly there the night after.
    nonisolated static let dreamThemeLife: TimeInterval = 60 * 3_600
    nonisolated static let dreamThemeMaxPhrases = 5
    /// Cosine floor between this message and a residue phrase (bge-large).
    nonisolated static let dreamThemeScoreFloor = 0.62

    nonisolated static func dreamThemeURL(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("cognition/dream_themes.json")
    }

    /// Return residue phrases best first; absent or fully spent diaries need no embedding.
    /// The embedder is used only when warm, never loaded during turn preparation; and
    /// the message vector is kept for a recompile of the same turn. A missing
    /// or different-width cache asks its builder; this turn carries no residue.
    /// Both caches name the root and canonical embedding epoch, including
    /// equal-width model changes.
    nonisolated static func dreamThemes(
        message: String,
        excluding: Set<String>,
        dataRoot: URL,
        now: Date,
        isWarm: @Sendable () async -> Bool,
        embeddingEpoch: @Sendable () async -> MemoryEmbeddingEpoch?,
        embed: @escaping @Sendable ([String]) async throws -> MemoryEmbeddingBatch,
        embedQuery: @Sendable ([String]) async throws -> MemoryEmbeddingBatch
    ) async -> CognitiveCueRead<[CognitiveDreamTheme]> {
        let diary: LivingDiary?
        do { diary = try livingDiary(dataRoot: dataRoot, now: now) } catch {
            return CognitiveCueRead([], unreadable: ["last night's dream diary (\(error.localizedDescription))"])
        }
        guard let diary else { return CognitiveCueRead([]) }
        guard let epoch = await embeddingEpoch(), await isWarm() else { return CognitiveCueRead([]) }
        let space = DreamThemeSpace(root: dataRoot.standardizedFileURL.resolvingSymlinksInPath().path, epoch: epoch)
        let cached: DreamThemeFile?
        do { cached = try cachedDreamTheme(dataRoot: dataRoot, diary: diary, space: space) } catch {
            requestDreamThemeExtraction(dataRoot: dataRoot, diary: diary, space: space, embed: embed)
            return CognitiveCueRead([], unreadable: ["the dream theme cache (\(error.localizedDescription)); it is being rebuilt"])
        }
        if let cached, cached.phrases.allSatisfy({ excluding.contains($0.id) }) { return CognitiveCueRead([]) }
        guard let file = cached else {
            requestDreamThemeExtraction(dataRoot: dataRoot, diary: diary, space: space, embed: embed)
            return CognitiveCueRead([])
        }
        let query: [Float]
        do { query = try await messageVector(message, space: space, embed: embedQuery) } catch {
            return CognitiveCueRead([], unreadable: ["this message's meaning for the dream cue (\(error.localizedDescription))"])
        }
        guard !file.phrases.contains(where: { $0.vector.count != query.count }) else {
            requestDreamThemeExtraction(dataRoot: dataRoot, diary: diary, space: space, embed: embed)
            return CognitiveCueRead([])
        }
        return CognitiveCueRead(file.phrases
            .filter { !excluding.contains($0.id) }
            .map { CognitiveDreamTheme(id: $0.id, text: $0.text, score: VectorMath.cosine($0.vector, query)) }
            .filter { $0.score >= dreamThemeScoreFloor }
            .sorted { $0.score > $1.score })
    }

    struct DreamThemeSpace: Hashable, Sendable {
        let root: String
        let epoch: MemoryEmbeddingEpoch
    }
    private static let lastMessageVector = OSAllocatedUnfairLock<(space: DreamThemeSpace, message: String, vector: [Float])?>(initialState: nil)
    private static let lastDreamTheme = OSAllocatedUnfairLock<(
        url: URL, stamp: SnapshotTailOpLog.FileStamp, file: DreamThemeFile
    )?>(initialState: nil)

    nonisolated static func messageVector(
        _ message: String,
        space: DreamThemeSpace,
        embed: @Sendable ([String]) async throws -> MemoryEmbeddingBatch
    ) async throws -> [Float] {
        if let hit = lastMessageVector.withLock({ $0 }), hit.space == space, hit.message == message { return hit.vector }
        let batch = try await embed([message])
        guard batch.epoch == space.epoch, let vector = batch.vectors.first, !vector.isEmpty else {
            throw CocoaError(.coderInvalidValue)
        }
        lastMessageVector.withLock { $0 = (space, message, vector) }
        return vector
    }

    struct LivingDiary: Sendable {
        let url: URL
        let name: String
        let written: Date
    }

    /// The newest diary, while it still lives; a diary that is not there is
    /// nil, one that cannot be read throws.
    nonisolated static func livingDiary(dataRoot: URL, now: Date) throws -> LivingDiary? {
        let dir = dataRoot.appendingPathComponent("dream_diary", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        guard let newest = try FileBackedDreamDiary(dataRoot: dataRoot)
            .discover(in: .active, matching: .nightly).max(by: { $0.name < $1.name })
        else { return nil }
        let url = newest.url
        guard let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
              now.timeIntervalSince(written) < dreamThemeLife else { return nil }
        return LivingDiary(url: url, name: newest.stem, written: written)
    }

    /// The cached themes, when they were extracted from exactly this diary;
    /// nil when absent or for another diary, a throw when it cannot be read.
    nonisolated static func cachedDreamTheme(dataRoot: URL, diary: LivingDiary, space: DreamThemeSpace) throws -> DreamThemeFile? {
        let url = dreamThemeURL(dataRoot).standardizedFileURL
        guard let stamp = SnapshotTailOpLog.fileStamp(url), case .present = stamp else {
            lastDreamTheme.withLock { $0 = nil }
            return nil
        }
        if let hit = lastDreamTheme.withLock({ $0 }), hit.url == url, hit.stamp == stamp,
           hit.file.root == space.root, hit.file.epoch == space.epoch,
           hit.file.diary == diary.name, hit.file.stamp == diary.written.timeIntervalSince1970 {
            return hit.file
        }
        let cached = try JSONDecoder().decode(DreamThemeFile.self, from: Data(contentsOf: url))
        guard cached.diary == diary.name, cached.stamp == diary.written.timeIntervalSince1970,
              cached.root == space.root, cached.epoch == space.epoch,
              SnapshotTailOpLog.fileStamp(url) == stamp else { return nil }
        lastDreamTheme.withLock { $0 = (url, stamp, cached) }
        return cached
    }

    private static let dreamThemeExtractionInFlight = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// One detached extraction at a time; the next turn reads what it published.
    nonisolated static func requestDreamThemeExtraction(
        dataRoot: URL,
        diary: LivingDiary,
        space: DreamThemeSpace,
        embed: @escaping @Sendable ([String]) async throws -> MemoryEmbeddingBatch
    ) {
        let claimed = dreamThemeExtractionInFlight.withLock { inFlight in
            inFlight.insert(space.root).inserted
        }
        guard claimed else { return }
        Task.detached(priority: .utility) {
            _ = await extractDreamTheme(dataRoot: dataRoot, diary: diary, space: space, embed: embed)
            _ = dreamThemeExtractionInFlight.withLock { $0.remove(space.root) }
        }
    }

    /// Extracted once per diary (keyed by file name and modification time),
    /// with the embedder already warm, then cached.
    nonisolated static func extractDreamTheme(
        dataRoot: URL,
        diary: LivingDiary,
        space: DreamThemeSpace,
        embed: @Sendable ([String]) async throws -> MemoryEmbeddingBatch
    ) async -> DreamThemeFile? {
        guard let markdown = try? String(contentsOf: diary.url, encoding: .utf8) else { return nil }
        let (candidates, gist) = dreamThemeCandidates(markdown)
        guard !candidates.isEmpty, !gist.isEmpty,
              let batch = try? await embed(candidates + [gist]), batch.epoch == space.epoch,
              batch.vectors.count == candidates.count + 1 else { return nil }
        let vectors = batch.vectors
        // Which of her own themes sit closest to the night's whole entry: the
        // embedder picks, the diary supplies every word.
        let center = vectors[candidates.count]
        let kept = candidates.indices
            .sorted { VectorMath.cosine(vectors[$0], center) > VectorMath.cosine(vectors[$1], center) }
            .prefix(dreamThemeMaxPhrases)
            .sorted()
        let file = DreamThemeFile(
            diary: diary.name,
            stamp: diary.written.timeIntervalSince1970,
            root: space.root, epoch: batch.epoch,
            phrases: kept.map { .init(id: "\(diary.name)#\($0 + 1)", text: candidates[$0], vector: vectors[$0]) })
        let cacheURL = dreamThemeURL(dataRoot)
        do {
            try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(file), to: cacheURL)
        } catch {
            // A flush failure may leave replacement bytes; the next read validates the cache.
            nativeLog("[dream-themes] cache publication failed: %@", error.localizedDescription)
        }
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

    /// What actually happened between `from` and `to`, as short items with
    /// real content, in order: a Desk outcome, then what each trusted builder
    /// shipped, newest first (what moved her is the substrate's, from her cares). Nothing happened → []; a
    /// source that could not be read is named in `unreadable`.
    nonisolated static func sinceGapItems(
        from: Date,
        to: Date,
        surface: String,
        dataRoot: URL,
        worklogURL: URL? = nil,
        codexURL: URL? = nil
    ) async -> CognitiveCueRead<[String]> {
        async let deskRead = Result { try await SwiftNativeDeskStore(dataRoot: dataRoot).liveState() }
        var items: [String] = []
        var unreadable: [String] = []
        let deskState: DeskState?
        switch await deskRead {
        case .success(let state): deskState = state
        case .failure(let error): deskState = nil; unreadable.append("the Desk (\(error.localizedDescription))")
        }
        let inGap: (Date?) -> Bool = { date in date.map { $0 > from && $0 <= to } ?? false }

        // A Desk outcome: an item finished in the gap that has a real title
        // (not a machine step like "A step from peer:…").
        if let state = deskState {
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

        // Only trusted builders contribute news: one newest item each, with the rest counted.
        let (builders, unreadBuilders) = builderNews(dataRoot: dataRoot, worklogURL: worklogURL, codexURL: codexURL)
        unreadable += unreadBuilders
        let news = builders.compactMap { builder -> (Date, String)? in
            let inside = builder.shipped.filter { inGap($0.0) && $0.1.count >= 6 }
            guard let newest = inside.max(by: { $0.0 < $1.0 }),
                  PeerTrust.ownerTrusts(builder.lane, dataRoot: dataRoot) else { return nil }
            return (newest.0, "\(builder.name) shipped \"\(newest.1)\""
                + (inside.count > 1 ? " (+\(inside.count - 1) more)" : ""))
        }
        items += news.sorted { $0.0 > $1.0 }.map(\.1)
        return CognitiveCueRead(items, unreadable: unreadable)
    }

    nonisolated static func builderNews(dataRoot: URL, worklogURL: URL? = nil, codexURL: URL? = nil, unseenOnly: Bool = false)
        -> (builders: [(name: String, lane: String, shipped: [(Date, String)])], unreadable: [String]) {
        var unreadable: [String] = []
        let peers: [AgentPeerContact]
        do { peers = try AgentPeerStore(dataRoot: dataRoot).list() } catch {
            return ([], ["the peer list (\(error.localizedDescription))"])
        }
        let quietWindow = unseenOnly ? TurnQuietHoursWindow.read(dataRoot: dataRoot) : nil
        let builders = peers.filter { peer in !peers.contains { $0.id == peer.who } }.compactMap { who -> (name: String, lane: String, shipped: [(Date, String)])? in
            let key = "peer:" + who.id
            guard PeerTrust.ownerTrusts(key, dataRoot: dataRoot),
                  let door = AgentConversationDelivery.door(for: key, dataRoot: dataRoot) else { return nil }
            let shipped: [(Date, String)]
            do {
                switch door.tool {
                case "claude_message": shipped = try claudeShipped(worklogURL ?? defaultClaudeWorklog(), kinds: unseenOnly ? ["feature"] : ["feature", "fix"])
                    .filter { !unseenOnly || quietWindow?.contains(hour: Calendar.current.component(.hour, from: $0.0)) == true }
                case "codex_message": shipped = try codexShipped(codexURL ?? defaultCodexRecord())
                default: return nil
                }
            } catch {
                unreadable.append("\(who.name)'s record of its work (\(error.localizedDescription))")
                return nil
            }
            return (who.name, key, shipped)
        }
        return (builders, unreadable)
    }

    /// A record that is not there is an empty one; any other failure throws.
    private nonisolated static func absentIsEmpty<T>(_ empty: T, _ read: () throws -> T) throws -> T {
        do { return try read() } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { return empty }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return empty }
    }

    nonisolated static func defaultClaudeWorklog() -> URL {
        AgentConversationView.claudeWorklogURL
    }

    /// Claude's worklog: shipped features and fixes, headline only.
    nonisolated static func claudeShipped(_ url: URL, kinds: Set<String> = ["feature", "fix"]) throws -> [(Date, String)] {
        try absentIsEmpty([]) { try AgentConversationView.claudeWorklogTail(url) }.compactMap { object -> (Date, String)? in
            guard kinds.contains(object["kind"] as? String ?? ""),
                  let at = MemoryMoments.parseTimestamp(object["ts"] as? String),
                  let summary = object["summary"] as? String else { return nil }
            return (at, headline(summary))
        }
    }

    /// Claude's newest worklog line of any kind indicates User may be working with her.
    nonisolated static func claudeLastActivity(_ url: URL) -> Date? {
        ((try? AgentConversationView.claudeWorklogTail(url)) ?? []).compactMap { MemoryMoments.parseTimestamp($0["ts"] as? String) }.max()
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
    nonisolated static func codexShipped(_ url: URL) throws -> [(Date, String)] {
        let data = try absentIsEmpty(Data()) { try Data(contentsOf: url) }
        guard data.count <= 1_048_576 else { return [] }
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

}
