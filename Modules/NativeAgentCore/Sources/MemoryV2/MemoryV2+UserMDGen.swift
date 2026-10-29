// Regenerate the active persona root's USER.md from canonical SQLite memory,
// preserving its marked human preamble. MemoryStorage requests coalesced refreshes.

import Darwin
import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
import NativeAgentShared

// Blueprint: | `MemoryV2+UserMDGen.swift` | `UserMDGenerator`: coalesced regeneration of derived USER.md at the active canonical persona root; SQLite remains truth; admits `MemoryKindStamp.personKinds`, bounded at `UserMDAutogenMarkers.promptByteCap` |

public enum UserMDGeneratorError: Error, CustomStringConvertible, LocalizedError {
    /// Onboarding must create the identity anchor before regeneration can project it.
    case onboardingIncomplete
    /// Preserve unreadable documents or damaged preamble markers without overwriting them.
    case damagedExistingDocument(String)

    public var failure: ToolFailureError {
        switch self {
        case .onboardingIncomplete:
            return ToolFailureError("USER.md generation requires completed setup.", effects: .none,
                owner: "Setup", tap: "Setup", personDecides: true,
                code: "user_projection_setup_required", status: .refused,
                instruction: "Complete setup before generating USER.md.")
        case .damagedExistingDocument(let reason):
            return ToolFailureError("Existing USER.md is damaged: \(reason)", effects: .none, owner: "USER.md",
                nextCall: ToolFailureError.call("app", ["action": .string("persona.read"), "args": .object(["kind": .string("user")])]),
                code: "user_projection_document_damaged", status: .refused,
                instruction: "Inspect USER.md; repair its encoding or paired preamble markers while preserving all authored text.")
        }
    }

    public var description: String { MemoryV2Error.describe(failure) }
    public var errorDescription: String? { description }
}

/// USER.md is backed up/exported under the persona PrivacyMap scope, never
/// phone-synced. Onboarding supplies its initial bytes to this commit owner.
public actor UserMDGenerator {
    // Share exact section markers with the Context compiler and prompt rendering.
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
    /// Personas owed a trailing regeneration when the debounce window closes.
    private var pendingPersonas: Set<String> = []
    /// Owns the deadline AND regeneration, until the flight actually exits.
    private var pendingTask: Task<Void, Never>?
    private var pendingTaskWaiting = false
    private var stopped = false
    private var shutdownTask: Task<Void, Never>?

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

    /// Require the completion sentinel or complete legacy identity bundle; USER.md alone is insufficient.
    /// Pending completion/reset manifests block regeneration to preserve their exact transaction bytes.
    public nonisolated var onboardingHasCompleted: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dataRoot.appendingPathComponent("onboarding/pending-completion.json").path)
            || fm.fileExists(atPath: dataRoot.appendingPathComponent("onboarding/pending-reset.json").path) {
            return false
        }
        if fm.fileExists(atPath: dataRoot.appendingPathComponent(".onboarded").path) {
            return true
        }
        let root = personaRoot ?? dataRoot
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent(MemoryV2Defaults.personaID, isDirectory: true)
        return NativeAgentPublicSafety.hasLegacyCompletionAnchor(
            personaRoot: root,
            profileURL: dataRoot.appendingPathComponent("memory/profile.json"),
            allowMissingProfile: true
        )
    }

    /// A resolved persona root names one document regardless of the requested storage partition.
    public nonisolated func userMDPath(persona: String) -> URL {
        if let personaRoot {
            return personaRoot.appendingPathComponent("USER.md")
        }
        return dataRoot
            .appendingPathComponent("persona", isDirectory: true)
            .appendingPathComponent(persona, isDirectory: true)
            .appendingPathComponent("USER.md")
    }

    /// Return the regenerated URL, or nil when coalesced into one owed trailing run.
    @discardableResult
    public func requestRegeneration(persona: String = MemoryV2Defaults.personaID) async throws -> URL? {
        guard !stopped else { throw CancellationError() }
        guard onboardingHasCompleted else {
            throw UserMDGeneratorError.onboardingIncomplete
        }
        let projectionPersona = projectionPersona(for: persona)
        if pendingTask != nil {
            pendingPersonas.insert(projectionPersona)
            return nil
        }
        if let last = lastRegen {
            let elapsed = nowProvider().timeIntervalSince(last)
            if elapsed < debounceInterval {
                scheduleTrailingEdge(persona: projectionPersona, after: debounceInterval - elapsed)
                return nil
            }
        }
        return try await regenerateDocument(persona: projectionPersona)
    }

    /// The active document uses the stable runtime persona, independent of display names or mutation sources.
    private func projectionPersona(for requestedPersona: String) -> String {
        guard personaRoot != nil else { return requestedPersona }
        return MemoryV2Defaults.personaID
    }

    private func scheduleTrailingEdge(persona: String, after delay: TimeInterval) {
        guard delay.isFinite, delay >= 0,
              let nanoseconds = UInt64(exactly: (delay * 1_000_000_000).rounded(.towardZero)) else {
            nativeLog("UserMDGenerator: invalid trailing-edge delay %@", String(describing: delay))
            return
        }
        pendingPersonas.insert(persona)
        guard pendingTask == nil else { return }
        pendingTaskWaiting = true
        pendingTask = Task {
            defer {
                pendingTaskWaiting = false
                pendingTask = nil
                if !stopped, let persona = pendingPersonas.first {
                    let elapsed = lastRegen.map { nowProvider().timeIntervalSince($0) } ?? debounceInterval
                    scheduleTrailingEdge(persona: persona, after: max(0, debounceInterval - elapsed))
                }
            }
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
            }
            catch { return }
            pendingTaskWaiting = false
            await flushPending()
        }
    }

    private func flushPending() async {
        let personas = pendingPersonas
        pendingPersonas.removeAll()
        for persona in personas {
            do {
                _ = try await regenerateDocument(persona: persona)
            } catch {
                nativeLog("UserMDGenerator: trailing-edge regeneration failed for %@: %@",
                      persona, String(describing: error))
            }
        }
    }

    /// Stop future pokes, cancel only a sleeping deadline, then flush accepted
    /// requests. A regeneration already writing is joined without cancellation.
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        guard !stopped else { return }
        stopped = true
        if pendingTaskWaiting { pendingTask?.cancel() }
        let trailing = pendingTask
        let drain = Task {
            await trailing?.value
            await flushPending()
        }
        shutdownTask = drain
        await drain.value
        shutdownTask = nil
    }

    /// Regenerate from active memories; refuse until onboarding has completed.
    @discardableResult
    public func regenerate(persona: String = MemoryV2Defaults.personaID) async throws -> URL {
        guard !stopped else { throw CancellationError() }
        return try await regenerateDocument(persona: persona)
    }

    private func regenerateDocument(persona: String) async throws -> URL {
        let projectionPersona = projectionPersona(for: persona)
        let target = userMDPath(persona: projectionPersona)
        let parent = target.deletingLastPathComponent()

        let manifestPath = dataRoot.appendingPathComponent("onboarding/pending-completion.json")
        // Match onboarding's lock order and hold its manifest lock from the
        // completion check through replacement of the derived document.
        do {
            let generatedAt = try await SwiftNativePersistenceCore.withFileLock(manifestPath) { [self, storage, nowProvider, target] in
                guard onboardingHasCompleted else {
                    throw UserMDGeneratorError.onboardingIncomplete
                }
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                return try await SwiftNativePersistenceCore.withFileLock(target) {
                    // Read memory under the projection lock; listMemories never acquires the USER lock.
                    let memories = try await storage.listMemories(
                        persona: projectionPersona, status: "active", limit: nil
                    )
                    let now = nowProvider()
                    let body = Self.renderBody(memories: memories, now: now, dataRoot: dataRoot)
                    let existing = try Self.loadPreambleForRegeneration(at: target)
                    let payload = Self.assemble(preamble: existing.preamble, body: body)
                    try Self.atomicReplaceIfChanged(payload, existingBytes: existing.bytes, at: target)
                    return now
                }
            }
            lastRegen = generatedAt
            RepairOwed.settle(dataRoot, operation: "memory.user_projection", evidence: .init(source: "memory", id: projectionPersona))
            return target
        } catch UserMDGeneratorError.onboardingIncomplete {
            throw UserMDGeneratorError.onboardingIncomplete  // expected on a blank install; onboarding supplies the initial content
        } catch {
            RepairOwed.owe(dataRoot, id: "user-projection:" + UUID().uuidString, kind: .act, operation: "memory.user_projection",
                owner: target.path, words: "USER.md regeneration failed: \(error)")
            throw error
        }
    }

    /// Durable atomic replacement under the caller's target lock; onboarding verifies its exact base bytes.
    package static func atomicReplaceIfChanged(_ payload: String, existingBytes: Data?, at target: URL) throws {
        let bytes = Data(payload.utf8)
        // Identical bytes must not wake document watchers; compare under the write lock.
        if existingBytes == bytes { return }
        try SwiftNativePersistenceCore.writeDataAtomicDurable(bytes, to: target)
    }

    // MARK: - Rendering

    /// Bound newest-first facts at promptByteCap; facts beyond it remain recallable.
    static func renderBody(memories: [StoredMemory], now: Date, dataRoot: URL) -> String {
        var budget = UserMDAutogenMarkers.promptByteCap - "# USER\n".utf8.count
        var lines: [String] = []
        for fact in userFacts(memories: memories, now: now, dataRoot: dataRoot) {
            let line = "- \(fact)\n"
            guard line.utf8.count <= budget else { break }
            lines.append(line)
            budget -= line.utf8.count
        }
        return "# User Facts (auto-generated from memory SQLite)\n\n" + lines.joined() + "\n"
    }

    static func userFacts(memories: [StoredMemory], now: Date = Date(), dataRoot: URL) -> some Sequence<String> {
        memories.lazy.compactMap { m -> String? in
            // Admit only known person kinds; excluded kinds remain recallable outside USER.md.
            guard let kind = MemoryRecallScoring.kind(of: m.metadata),
                  Self.userIdentityKinds.contains(kind) else { return nil }
            // Require eligible lifecycle, unexpired validity, completed admission and durable content.
            // The document is surface-independent; prompt rendering applies disclosure filtering.
            guard MemoryLifecycle.isRecallEligible(m.lifecycle) else { return nil }
            guard MemoryRecordDisclosurePolicy.isTemporallyEligible(validTo: m.validTo, at: now) else { return nil }
            // A cold write is not a fact until its vector lands and passes admission.
            guard !MemoryStorage.metadataFlag(m.metadata, MemoryStorage.pendingAdmissionKey) else { return nil }
            guard MemoryCandidateQuality.isDurableCandidate(
                text: m.content,
                source: m.source,
                kind: MemoryRecallScoring.kind(of: m.metadata)
            ) else { return nil }
            let content = MemoryTextClip.memoryDisplayText(
                m.content.replacingOccurrences(of: "\n", with: " "),
                kind: MemoryRecallScoring.kind(of: m.metadata)
            )
            guard !content.isEmpty else { return nil }
            return MemoryDataProvenance.presentation(
                MemorySenseProvenance.presentation(content, metadata: m.metadata), metadata: m.metadata, dataRoot: dataRoot)
        }
    }

    /// USER.md and userPromptCore share person-kind admission; moments, experiences and ops stay in recall.
    static let userIdentityKinds: Set<String> = MemoryKindStamp.personKinds

    /// Why a memory of `kind` cannot be pinned, or nil when it can. The pinned
    /// core carries only `userIdentityKinds`; every pin writer (the chat tool,
    /// the Memories page, the phone) refuses with these words.
    public static func pinFailure(kind: String?) -> ToolFailureError? {
        if userIdentityKinds.contains(kind ?? "") { return nil }
        return ToolFailureError("Pins carry owner facts; \(kind ?? "a memory with no kind") is excluded.", effects: .none,
            nextCall: ToolFailureError.call("app", ["action": .string("memory.list")]),
            code: "memory_pin_kind_excluded", status: .refused,
            instruction: "Leave it unpinned; read saved memories with memory.list.", recovery: .inspect)
    }


    private static func loadPreambleForRegeneration(at url: URL) throws -> (preamble: String?, bytes: Data?) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return (nil, nil) }
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
        if startCount == 0 && endCount == 0 { return (nil, data) }
        guard startCount == 1, endCount == 1,
              let startRange = existing.range(of: preambleStartMarker),
              let endRange = existing.range(of: preambleEndMarker),
              startRange.upperBound <= endRange.lowerBound else {
            throw UserMDGeneratorError.damagedExistingDocument(
                "preamble markers are missing, duplicated, or out of order"
            )
        }
        return (String(existing[startRange.upperBound..<endRange.lowerBound]), data)
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

extension UserMDGenerator {
    /// Zero-arg shorthand the launch hook uses.
    public func regenerate() async throws -> URL {
        try await self.regenerate(persona: MemoryV2Defaults.personaID)
    }
}
