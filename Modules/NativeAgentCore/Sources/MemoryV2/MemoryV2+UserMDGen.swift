// Swift-native cutover mem-m7: regenerate USER.md from the SQLite memory store.
//
// Canonical path: the active persona root's `USER.md`. MemoryV2 owns the
// contents, but it writes into the same persona doc the compiler and tools read.
// No fallback to the legacy `<dataRoot>/memory/USER.md`.
//
// MemoryV2 owns the truth (SQLite); USER.md is a derived, human-readable +
// LLM-injected projection. This generator regenerates it from active memories
// for a persona, preserving any human-edited preamble between
// `<!-- USER_PREAMBLE_START -->` ... `<!-- USER_PREAMBLE_END -->` markers.
// MemoryStorage pokes `requestRegeneration` on insertMemory / acceptProposal,
// debounced to once per 30s.

import Darwin
import Foundation
import NativeAgentCore
import PersistenceCore

public actor UserMDGenerator {
    // One owner: `UserMDAutogenMarkers` in NativeAgentCore. The Context
    // compiler cuts per-fact atoms on these exact strings and the flow
    // coordinator gates precoverage on them; a private literal here would
    // drift silently.
    public static let preambleStartMarker = UserMDAutogenMarkers.preambleStart
    public static let preambleEndMarker = UserMDAutogenMarkers.preambleEnd
    public static let bodyStartMarker = UserMDAutogenMarkers.bodyStart
    public static let bodyEndMarker = UserMDAutogenMarkers.bodyEnd

    private let storage: MemoryStorage
    private let dataRoot: URL
    private let personaRoot: URL?
    private let debounceInterval: TimeInterval
    private let nowProvider: @Sendable () -> Date
    private var lastRegen: Date?
    /// U5 W-G trailing-edge fix (2026-06-11): personas whose regeneration
    /// was debounced and is owed a trailing run when the window closes.
    private var pendingPersonas: Set<String> = []
    /// Single in-flight trailing-edge timer task; nil when none scheduled.
    /// Lifecycle: set in `scheduleTrailingEdge`, cleared in `flushPending`.
    private var pendingTask: Task<Void, Never>?

    public init(
        storage: MemoryStorage,
        dataRoot: URL,
        personaRoot: URL? = nil,
        debounceInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.dataRoot = dataRoot
        self.personaRoot = personaRoot
        self.debounceInterval = debounceInterval
        self.nowProvider = now
    }

    /// Path the generator writes to for a given persona. A resolved persona
    /// root is one active document, so it deliberately does not vary by the
    /// storage partition supplied by a caller.
    public nonisolated func userMDPath(persona: String) -> URL {
        if let personaRoot {
            return personaRoot.appendingPathComponent("USER.md")
        }
        return dataRoot
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent(persona, isDirectory: true)
            .appendingPathComponent("USER.md")
    }

    /// Skip if the last regeneration was within the debounce window. Returns
    /// the URL when a regeneration actually ran, nil when debounced.
    ///
    /// U5 W-G fix (2026-06-11): debounced pokes used to be DROPPED — a burst
    /// of inserts right after a regen left USER.md stale until some future
    /// poke happened to land outside the window (trailing-edge loss). Now a
    /// debounced poke schedules exactly one trailing regeneration at window
    /// expiry, coalescing every poke that arrives meanwhile.
    @discardableResult
    public func requestRegeneration(persona: String = MemoryV2Defaults.personaID) async throws -> URL? {
        let projectionPersona = projectionPersona(for: persona)
        if let last = lastRegen {
            let elapsed = nowProvider().timeIntervalSince(last)
            if elapsed < debounceInterval {
                scheduleTrailingEdge(persona: projectionPersona, after: debounceInterval - elapsed)
                return nil
            }
        }
        return try await regenerate(persona: projectionPersona)
    }

    /// The app writes one active persona document. Its memory partition is a
    /// stable runtime identity, not the configurable display name or a legacy
    /// partition that happened to trigger a mutation.
    private func projectionPersona(for requestedPersona: String) -> String {
        guard personaRoot != nil else { return requestedPersona }
        return MemoryV2Defaults.personaID
    }

    private func scheduleTrailingEdge(persona: String, after delay: TimeInterval) {
        pendingPersonas.insert(persona)
        guard pendingTask == nil else { return }
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            await self?.flushPending()
        }
    }

    private func flushPending() async {
        pendingTask = nil
        let personas = pendingPersonas
        pendingPersonas.removeAll()
        for persona in personas {
            do {
                _ = try await regenerate(persona: persona)
            } catch {
                NSLog("UserMDGenerator: trailing-edge regeneration failed for %@: %@",
                      persona, String(describing: error))
            }
        }
    }

    /// Unconditionally regenerate USER.md from active memories for `persona`.
    /// Called on app launch and by `requestRegeneration` after debounce.
    @discardableResult
    public func regenerate(persona: String = MemoryV2Defaults.personaID) async throws -> URL {
        let projectionPersona = projectionPersona(for: persona)
        let target = userMDPath(persona: projectionPersona)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let memories = try await storage.listMemories(persona: projectionPersona, status: "active", limit: nil)
        let now = nowProvider()
        let body = Self.renderBody(memories: memories, now: now)

        let core = SwiftNativePersistenceCore()
        try await core.withFileLock(target) { [body, target] in
            let preamble = Self.extractPreamble(at: target)
            let payload = Self.assemble(preamble: preamble, body: body)
            try Self.atomicReplace(payload, at: target)
        }
        lastRegen = now
        return target
    }

    /// `rename(2)` replaces the destination in one filesystem operation. The
    /// previous remove-then-move sequence exposed a transient missing USER.md
    /// to prompt assembly and other readers.
    private static func atomicReplace(_ payload: String, at target: URL) throws {
        let temporary = target.appendingPathExtension("tmp.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data(payload.utf8).write(to: temporary, options: .atomic)

        let result: Int32 = temporary.withUnsafeFileSystemRepresentation { source -> Int32 in
            guard let source else { return -1 }
            return target.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let destination else { return -1 }
                return rename(source, destination)
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "rename(\(temporary.path) -> \(target.path)) failed: \(String(cString: strerror(code)))"
                ]
            )
        }
    }

    // MARK: - Rendering

    static func renderBody(memories: [StoredMemory], now: Date) -> String {
        _ = now

        var out = ""
        out += "# User Facts (auto-generated from memory SQLite)\n\n"

        // Flat list, newest first — no provenance grouping, no per-fact dates.
        // Clean single-signal facts are the substrate Agent reasons from; the
        // `## From <source>` headers, counters, and regenerated timestamps were
        // machine cruft.
        let items = memories.sorted { $0.createdAt > $1.createdAt }
        for m in items {
            // Skill pointers are recall-only surfacing rows, not user facts.
            // USER.md rides every prompt — rendering them here would re-crea-
            // te the per-turn tax the skills-recall rework exists to avoid
            // (gpt-5.5 review HIGH, 2026-07-03).
            if m.id.hasPrefix(SwiftNativeMemoryV2.skillPointerIDPrefix) { continue }
            if Self.memoryKind(m) == "skill" { continue }
            // Admission parity with the memory CONTEXT projection
            // (2026-07-24). USER.md is a projection of the same rows the
            // context projection compiles into memory atoms, and
            // ContextFlowCoordinator suppresses USER.md only when every
            // generated line is carried by an eligible atom. A row rendered
            // here but rejected there made that all-or-nothing join fail for
            // the WHOLE document — USER.md and the identical memory atoms both
            // rode every turn.
            //
            // Both gates are corrections in their own right, independent of the
            // join:
            //   * lifecycle — `corrected` / `contradicted` / `deleted` rows are
            //     recall-INELIGIBLE everywhere else in the system. Publishing
            //     them into a doc that rides every prompt re-states superseded
            //     facts next to the ones that superseded them. (Live 2026-07-24:
            //     7 of 50 active rows, all superseded sleep-schedule variants,
            //     were queued to land in USER.md on the next regeneration.)
            //   * durability — the same precision gate every other write path
            //     applies; a row that is not durable memory is not a user fact.
            //
            // Gates the projection ALSO applies but this cannot reach from
            // MemoryV2 (secret-shape policy, per-surface disclosure, atom size)
            // stay uncovered here on purpose. They are handled the safe way:
            // the join stays all-or-nothing, so an uncovered fact keeps USER.md
            // injected in full rather than silently dropping the fact.
            guard MemoryLifecycle.isRecallEligible(m.lifecycle) else { continue }
            guard MemoryCandidateQuality.isDurableCandidate(
                text: m.content,
                source: m.source,
                kind: Self.memoryKind(m)
            ) else { continue }
            let content = MemoryTextClip.memoryDisplayText(
                m.content.replacingOccurrences(of: "\n", with: " "),
                kind: Self.memoryKind(m)
            )
            guard !content.isEmpty else { continue }
            out += "- \(content)\n"
        }
        out += "\n"
        return out
    }

    private static func memoryKind(_ memory: StoredMemory) -> String? {
        guard case .object(let obj)? = memory.metadata,
              case .string(let kind)? = obj["kind"] else {
            return nil
        }
        let trimmed = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func extractPreamble(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let existing = String(data: data, encoding: .utf8) else { return nil }
        guard let startRange = existing.range(of: preambleStartMarker),
              let endRange = existing.range(of: preambleEndMarker),
              startRange.upperBound <= endRange.lowerBound else { return nil }
        let inner = existing[startRange.upperBound..<endRange.lowerBound]
        return String(inner)
    }

    static func assemble(preamble: String?, body: String) -> String {
        var out = ""
        if let preamble {
            out += "\(preambleStartMarker)"
            out += preamble
            out += "\(preambleEndMarker)\n\n"
        }
        out += "\(bodyStartMarker)\n"
        out += body
        if !body.hasSuffix("\n") { out += "\n" }
        out += "\(bodyEndMarker)\n"
        return out
    }
}
