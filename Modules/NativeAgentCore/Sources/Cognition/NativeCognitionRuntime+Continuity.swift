// Cue reads distinguish absent sources from unreadable evidence without provider calls or memory writes.

import AgentConversations
import Experiences
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

// Blueprint: | `NativeCognitionRuntime+Continuity.swift` | `NativeCognitionRuntime`. |

extension NativeCognitionRuntime {
    // MARK: - Dream residue

    /// Dream residue is a replaceable diary-derived cache, never evidence that its themes happened.
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

    /// Retain a diary for two and a half days so its residue can still color the following night.
    nonisolated static let dreamThemeLife: TimeInterval = 60 * 3_600
    nonisolated static let dreamThemeMaxPhrases = 5
    nonisolated static let dreamThemeScoreFloor = 0.62

    nonisolated static func dreamThemeURL(_ dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("cognition/dream_themes.json")
    }

    /// Use only a warm embedder so turn preparation cannot load it; reuse the message vector within a turn.
    /// Missing or incompatible themes queue a rebuild and carry no residue now.
    /// Key both caches by root and embedding epoch so equal-width model changes cannot reuse stale vectors.
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
            return CognitiveCueRead([], unreadable: ["the dream theme cache (\(error.localizedDescription)); " + dreamThemeExtractionStatus(
                dataRoot: dataRoot, diary: diary, space: space)])
        }
        if let cached, cached.phrases.allSatisfy({ excluding.contains($0.id) }) { return CognitiveCueRead([]) }
        guard let file = cached else {
            requestDreamThemeExtraction(dataRoot: dataRoot, diary: diary, space: space, embed: embed)
            return CognitiveCueRead([], unreadable: [dreamThemeExtractionStatus(dataRoot: dataRoot, diary: diary, space: space)])
        }
        let query: [Float]
        do { query = try await messageVector(message, space: space, embed: embedQuery) } catch {
            return CognitiveCueRead([], unreadable: ["this message's meaning for the dream cue (\(error.localizedDescription))"])
        }
        guard !file.phrases.contains(where: { $0.vector.count != query.count }) else {
            requestDreamThemeExtraction(dataRoot: dataRoot, diary: diary, space: space, embed: embed)
            return CognitiveCueRead([], unreadable: [dreamThemeExtractionStatus(dataRoot: dataRoot, diary: diary, space: space)])
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

    /// Absence is nil; an unreadable diary throws.
    nonisolated static func livingDiary(dataRoot: URL, now: Date) throws -> LivingDiary? {
        guard let newest = try FileBackedDreamDiary(dataRoot: dataRoot)
            .discover(in: .active, matching: .nightly).max(by: { $0.name < $1.name })
        else { return nil }
        let url = newest.url
        guard let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
              now.timeIntervalSince(written) < dreamThemeLife else { return nil }
        return LivingDiary(url: url, name: newest.stem, written: written)
    }

    /// Reuse themes only for the exact diary; absent or mismatched caches are nil, unreadable caches throw.
    nonisolated static func cachedDreamTheme(dataRoot: URL, diary: LivingDiary, space: DreamThemeSpace) throws -> DreamThemeFile? {
        let url = dreamThemeURL(dataRoot).standardizedFileURL
        guard let stamp = SnapshotTailOpLog.fileStamp(url) else {
            throw PersistenceCoreError.ioFailure("Dream theme cache metadata is unavailable: " + url.path)
        }
        guard case .present = stamp else { lastDreamTheme.withLock { $0 = nil }; return nil }
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

    private struct DreamThemeExtractionState: Sendable {
        let diary: String
        let stamp: Double
        let space: DreamThemeSpace
        var failure: String?
        var running: Bool
        func matches(_ diary: LivingDiary, _ space: DreamThemeSpace) -> Bool {
            self.diary == diary.name && stamp == diary.written.timeIntervalSince1970 && self.space == space
        }
    }
    private static let dreamThemeExtractions = OSAllocatedUnfairLock<[String: DreamThemeExtractionState]>(initialState: [:])

    nonisolated static func dreamThemeExtractionStatus(dataRoot: URL, diary: LivingDiary, space: DreamThemeSpace) -> String {
        let state = dreamThemeExtractions.withLock { $0[space.root] }
        if let state, state.matches(diary, space), let failure = state.failure {
            return "dream theme extraction unavailable: " + failure + "; repair the diary or embedding source, then relaunch NativeAgent"
        }
        return "dream theme extraction is still being read; no residue is claimed for this turn"
    }

    /// Allow one detached extraction at a time; turns consume only published results.
    nonisolated static func requestDreamThemeExtraction(
        dataRoot: URL,
        diary: LivingDiary,
        space: DreamThemeSpace,
        embed: @escaping @Sendable ([String]) async throws -> MemoryEmbeddingBatch
    ) {
        let claimed = dreamThemeExtractions.withLock { states in
            if let state = states[space.root], state.running || state.matches(diary, space) { return false }
            states[space.root] = DreamThemeExtractionState(diary: diary.name,
                stamp: diary.written.timeIntervalSince1970, space: space, failure: nil, running: true)
            return true
        }
        guard claimed else { return }
        Task.detached(priority: .utility) {
            do {
                _ = try await extractDreamTheme(dataRoot: dataRoot, diary: diary, space: space, embed: embed)
                dreamThemeExtractions.withLock { $0[space.root] = nil }
            } catch {
                let cause = error.localizedDescription
                dreamThemeExtractions.withLock { states in
                    states[space.root]?.running = false
                    states[space.root]?.failure = cause
                }
                RepairOwed.owe(dataRoot, id: "dream-themes:" + UUID().uuidString, kind: .run,
                    operation: "cognition.dream.themes", owner: diary.url.path,
                    words: "Dream theme extraction or publication is unavailable: " + cause,
                    tap: "Repair the diary or embedding owner, preserving the diary, then relaunch NativeAgent.")
            }
        }
    }

    /// Extract once per diary identity with an already-warm embedder.
    nonisolated static func extractDreamTheme(
        dataRoot: URL,
        diary: LivingDiary,
        space: DreamThemeSpace,
        embed: @Sendable ([String]) async throws -> MemoryEmbeddingBatch
    ) async throws -> DreamThemeFile {
        let markdown = try String(contentsOf: diary.url, encoding: .utf8)
        let (candidates, gist) = dreamThemeCandidates(markdown)
        let vectors: [[Float]]
        let kept: [Int]
        if candidates.isEmpty || gist.isEmpty {
            vectors = []
            kept = []
        } else {
            let batch = try await embed(candidates + [gist])
            guard batch.epoch == space.epoch, batch.vectors.count == candidates.count + 1 else {
                throw PersistenceCoreError.ioFailure("Dream theme embedding epoch or vector count changed during extraction.")
            }
            vectors = batch.vectors
            let center = vectors[candidates.count]
            kept = candidates.indices
                .sorted { VectorMath.cosine(vectors[$0], center) > VectorMath.cosine(vectors[$1], center) }
                .prefix(dreamThemeMaxPhrases).sorted()
        }
        let file = DreamThemeFile(
            diary: diary.name,
            stamp: diary.written.timeIntervalSince1970,
            root: space.root, epoch: space.epoch,
            phrases: kept.map { .init(id: "\(diary.name)#\($0 + 1)", text: candidates[$0], vector: vectors[$0]) })
        let cacheURL = dreamThemeURL(dataRoot)
        guard let written = try FileManager.default.attributesOfItem(atPath: diary.url.path)[.modificationDate] as? Date,
              written == diary.written else {
            throw PersistenceCoreError.ioFailure("Dream diary changed before its theme cache committed.")
        }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(JSONEncoder().encode(file), to: cacheURL)
        return file
    }

    /// Rank only the diary's own theme lines against its gist; no themes means no invented candidates.
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
                gist.append(String(line.dropFirst(2).dropLast(2)))
            } else if line.hasPrefix("_Mood:") {
                gist.append(line.trimmingCharacters(in: CharacterSet(charactersIn: "_")))
            } else if !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("_"), !line.hasPrefix("**"),
                      !line.hasPrefix("- "), gist.count < 3 {
                gist.append(line)
            }
        }
        let text = gist.joined(separator: " ")
        return (themes.map { clipped($0, 160) }.filter { $0.count >= 8 }, clipped(text, 2_000))
    }

    /// Return the latest trusted Desk completion and count; name unreadable sources separately.
    nonisolated static func sinceGapItems(
        from: Date,
        to: Date,
        surface: String,
        dataRoot: URL
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

        // Use real Desk titles rather than machine-step labels.
        if let state = deskState {
            let done = state.items
                .filter {
                    $0.status == .done && inGap($0.closedAt.flatMap(DeskClock.parseISO)) && isRealTitle($0.title)
                        && Self.deskProvenanceTrusted($0, trusts: { PeerTrust.ownerTrusts($0, dataRoot: dataRoot) })
                }
                .sorted { ($0.closedAt ?? "") > ($1.closedAt ?? "") }
            if let first = done.first {
                items.append("Desk \"\(clipped(first.title, 70))\" done" + (done.count > 1 ? " (+\(done.count - 1) more)" : ""))
            }
        }
        return CognitiveCueRead(items, unreadable: unreadable)
    }

    /// A Desk item speaks for the person only when every step it carries was steered by peers the owner trusts.
    nonisolated static func deskProvenanceTrusted(_ item: DeskItem, trusts: (String) -> Bool) -> Bool {
        item.refs.allSatisfy { ref in
            guard case .step(let step) = ref.kind else { return true }
            return (step.peers + step.elevated).allSatisfy(trusts)
        }
    }

    nonisolated static func isRealTitle(_ title: String) -> Bool {
        title.count >= 8
            && title.range(of: #"peer:|[0-9a-f]{8}-[0-9a-f]{4}|\btest\b|delete me"#,
                           options: [.regularExpression, .caseInsensitive]) == nil
    }

    // MARK: - Small helpers

    nonisolated static func clipped(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let cut = flat.prefix(limit - 1)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

}
