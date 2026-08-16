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

public enum UserMDGeneratorError: Error, CustomStringConvertible {
    /// USER.md was requested on an install that has not completed onboarding.
    /// Not a failure: writing it there would fabricate the identity anchor
    /// onboarding is about to create.
    case onboardingIncomplete
    /// A file that carries evidence of the generator's preamble contract is
    /// unreadable or only partially marked. Regeneration must leave it untouched
    /// instead of treating damage as an intentionally absent preamble.
    case damagedExistingDocument(String)

    public var description: String {
        switch self {
        case .onboardingIncomplete:
            return "USER.md generation is gated until onboarding completes"
        case .damagedExistingDocument(let reason):
            return "USER.md generation refused because the existing document is damaged: \(reason)"
        }
    }
}

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

    /// True once this install has finished onboarding, and therefore owns a
    /// real identity that USER.md is allowed to project.
    ///
    /// Two accepted proofs, in order:
    ///   * `<dataRoot>/.onboarded` — the completion sentinel onboarding
    ///     publishes last, after every persona doc verifies.
    ///   * `SOUL.md` in the persona root — installs that predate the sentinel
    ///     still carry their identity docs, and must keep regenerating.
    ///
    /// USER.md itself is deliberately NOT a proof: it is the file this
    /// generator writes, so accepting it would be circular — exactly the
    /// self-satisfying loop that hid the onboarding wizard on blank installs.
    ///
    /// gpt-5.5 review NEEDS_FIX 3 (2026-08-02) asked whether that contradicts
    /// `Onboarding.startOnboarding`, which at the time counted a prose-bearing
    /// USER.md as already-onboarded. It did, and the contradiction was resolved
    /// in the OTHER direction: onboarding's start gate no longer accepts USER.md
    /// either. Both gates now recognize exactly `.onboarded` and `SOUL.md`, so
    /// no install can be "onboarded enough to hide the wizard" while also
    /// "un-onboarded enough to refuse regeneration" — the stuck state the review
    /// described.
    ///
    /// The alternative (teach this gate to accept identity-bearing USER.md
    /// content) was rejected: `regenerate` REPLACES the whole document with its
    /// own autogen body, so onboarding's prose survives only until the first
    /// regeneration. A proof this generator can erase — and, with bullets in the
    /// body, re-forge — is not a proof. An install carrying only a USER.md is
    /// therefore treated as incomplete, and the wizard (which is now reachable
    /// for it) is the recovery path.
    public nonisolated var onboardingHasCompleted: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dataRoot.appendingPathComponent(".onboarded").path) {
            return true
        }
        let soul = (personaRoot ?? dataRoot
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent(MemoryV2Defaults.personaID, isDirectory: true))
            .appendingPathComponent("SOUL.md")
        return fm.fileExists(atPath: soul.path)
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
        // Checked before the debounce bookkeeping so a pre-onboarding poke
        // cannot schedule a trailing-edge task that will only fail later.
        guard onboardingHasCompleted else {
            throw UserMDGeneratorError.onboardingIncomplete
        }
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

    /// Regenerate USER.md from active memories for `persona`. Called on app
    /// launch and by `requestRegeneration` after debounce.
    ///
    /// Throws `UserMDGeneratorError.onboardingIncomplete` on a machine that has
    /// not finished onboarding — see `onboardingHasCompleted`.
    @discardableResult
    public func regenerate(persona: String = MemoryV2Defaults.personaID) async throws -> URL {
        // fix-blank-install-onboarding (2026-08-02): USER.md is one of
        // onboarding's OWN transaction targets, and its mere existence used to
        // satisfy onboarding's `hasExisting`/`hasIdentityAnchor` checks. Launch
        // called this generator unconditionally, so on a blank machine it
        // created the persona dir and wrote a USER.md containing nothing but
        // the autogen header — and that empty file made the install look
        // already-onboarded. Whether the wizard ever appeared came down to
        // which task won a race at launch: launch-first meant no wizard at all
        // (unnamed agent, no SOUL/VOICE), wizard-first meant a Build that died
        // on `persona_already_exists`. Gating generation on onboarding having
        // completed removes the race entirely — before completion there is
        // simply nothing to write, in either order.
        guard onboardingHasCompleted else {
            throw UserMDGeneratorError.onboardingIncomplete
        }
        let projectionPersona = projectionPersona(for: persona)
        let target = userMDPath(persona: projectionPersona)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let memories = try await storage.listMemories(persona: projectionPersona, status: "active", limit: nil)
        let now = nowProvider()
        let body = Self.renderBody(memories: memories, now: now)

        let core = SwiftNativePersistenceCore()
        try await core.withFileLock(target) { [body, target] in
            let preamble = try Self.loadPreambleForRegeneration(at: target)
            let payload = Self.assemble(preamble: preamble, body: body)
            try Self.atomicReplace(payload, at: target)
        }
        lastRegen = now
        return target
    }

    /// Durable atomic replacement through the shared persistence core. This is
    /// the same temp-fsync + rename + parent-directory-fsync contract used by
    /// canonical chat/session state; a successful regeneration must survive a
    /// power loss, not merely a process crash.
    private static func atomicReplace(_ payload: String, at target: URL) throws {
        try SwiftNativePersistenceCore.writeDataAtomicDurable(Data(payload.utf8), to: target)
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
            // Workshop execution outcomes are the AGENT'S work journal —
            // legitimate durable memories (E-2 writes them so she remembers
            // what she built), but they are facts about her work, not about
            // the USER. Without this gate they flooded the identity doc: 46
            // of ~60 bullets were "Workshop execution X completed/failed"
            // rows (User, 2026-08-06). Provenance-gated, not content-sniffed:
            // the literal must equal WorkshopExecutionMemory.sourcePrefix
            // ("workshop:") — MemoryV2 cannot import WorkshopExecution
            // (dependency direction), so the two spellings are pinned by
            // convention only. If sourcePrefix ever changes, this literal
            // and UserMDGenTests must change with it.
            if (m.source ?? "").hasPrefix("workshop:") { continue }
            // USER.md is User's IDENTITY doc, not the agent's working memory.
            // The workshop gate above killed one pollution source; the disease
            // was that renderBody projected EVERY active row, and the store
            // legitimately holds the agent's own operational knowledge —
            // corrections, procedures, delegation forensics, build decisions
            // (2026-08-06 live read: ~45 of 60 rendered bullets were agent ops,
            // zero about User). Kind labels are model-chosen at commit time, so
            // a denylist of "bad" kinds leaks on every new label; this is a
            // fail-closed ALLOWLIST of person-kinds instead. A row with no
            // kind, an unknown kind, or an ops kind stays fully recallable —
            // it just doesn't ride the identity doc. Cost accepted: a genuine
            // User-fact mislabeled `decision` drops out until relabeled; a
            // 100%-about-User doc beats a complete-but-70%-noise one.
            guard let kind = Self.memoryKind(m),
                  Self.userIdentityKinds.contains(kind) else { continue }
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

    /// Kinds that describe the PERSON (or the User↔Agent relationship) rather
    /// than the agent's work. The union observed live 2026-08-06 across
    /// chat.commit_memory and adaptive-promoter rows; extend deliberately,
    /// never automatically — every addition puts rows on a doc that rides
    /// every prompt.
    static let userIdentityKinds: Set<String> = [
        "user_fact", "user_preference", "preference", "relationship",
        "identity", "attribute", "moment", "experience",
    ]

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

    private static func loadPreambleForRegeneration(at url: URL) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UserMDGeneratorError.damagedExistingDocument("unreadable: \(error)")
        }
        guard let existing = String(data: data, encoding: .utf8) else {
            throw UserMDGeneratorError.damagedExistingDocument("not valid UTF-8")
        }
        let startCount = existing.components(separatedBy: preambleStartMarker).count - 1
        let endCount = existing.components(separatedBy: preambleEndMarker).count - 1
        if startCount == 0 && endCount == 0 { return nil }
        guard startCount == 1, endCount == 1,
              let startRange = existing.range(of: preambleStartMarker),
              let endRange = existing.range(of: preambleEndMarker),
              startRange.upperBound <= endRange.lowerBound else {
            throw UserMDGeneratorError.damagedExistingDocument(
                "preamble markers are missing, duplicated, or out of order"
            )
        }
        return String(existing[startRange.upperBound..<endRange.lowerBound])
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
