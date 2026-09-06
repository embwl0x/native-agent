import Foundation
import NativeAgentCore
import PersistenceCore

// Per-session archive of each turn's volatile block (v2Prefix, clear_at lanes).
//
// WHY THIS EXISTS. v2 delivers the per-turn volatile mass as a turn-scoped
// system message that ends the request. Anthropic's rule for those: once a
// later user message arrives the message is CLEARED — it costs 0 input tokens
// — but it must STAY in `messages`, byte-for-byte, on every later request.
//
// The first v2 build dropped it instead. Turn N sent
//
//     … user(N) ‖ system(volatile N)
//
// and turn N+1 rebuilt its prefix from the TRANSCRIPT, which has no record of
// that system message:
//
//     … user(N) ‖ assistant(N) ‖ user(N+1) ‖ system(volatile N+1)
//
// The two requests agree up to `user(N)` and diverge at the very next element,
// so the cached prefix died there and the provider re-created the previous
// turn's tool rounds and reply on every turn — the exact cost v2 exists to
// remove, hidden behind a correct-looking reply.
//
// So each turn's block is persisted here, keyed by the RUN ID of the turn that
// produced it, and replayed at its original position (immediately after that
// turn's user message, before the assistant reply) on later requests.
//
// BOUNDED BY THE SAME WINDOW AS THE PREFIX. Entries are pruned to the run ids
// the projection actually replayed this turn, so when the window cursor drops
// a turn its archived block goes with it. A block outside the replayed window
// is not merely dead weight — replaying one would corrupt the prefix.
//
// File shape, actor discipline, per-file lock and hourly orphan sweep mirror
// `HistoryWindowCursorStore` / `ActiveToolsStore` deliberately: one pattern to
// reason about across all three sidecars.

/// One mid-conversation system message a past turn sent, held so later turns
/// can re-send it byte-for-byte.
///
/// TWO kinds ride here, and both must stay:
///   - the TURN-SCOPED volatile block (`text`, clear_at) — cleared by the
///     provider once a later user message arrives, costing 0 input tokens, but
///     required to remain in `messages`;
///   - the mid-conversation TOOL-CHANGE message (`toolChanges`,
///     `tool_addition`/`tool_removal`), which is NOT turn-scoped. Removing an
///     already-sent one invalidates the prefix from that point, so dropping it
///     is the same defect as dropping the volatile block.
public struct ArchivedVolatileBlock: Sendable, Equatable {
    /// Run id of the turn that produced this message. The projection matches it
    /// against the run id recorded on each replayed user row.
    public let runId: String
    /// Position within that turn's replayable tail, so the pair is replayed in
    /// the order it was sent (tool changes, then the volatile block).
    public let order: Int
    /// The block VERBATIM. Byte-for-byte is the whole contract — a re-rendered
    /// or re-wrapped block is a cache miss with extra steps. Empty on a
    /// tool-change message.
    public let text: String
    /// Turn-scoped marker. Mutually exclusive with `toolChanges` (the API
    /// rejects that pairing, and `LLMMessage` enforces it).
    public let clearAtNextUserMessage: Bool
    /// Provider-visible tool names, already validated against the request's
    /// `tools` array by the producer. Empty on a volatile block.
    public let toolChanges: [LLMToolChange]
    public let recordedAt: String

    public init(
        runId: String,
        order: Int,
        text: String,
        clearAtNextUserMessage: Bool,
        toolChanges: [LLMToolChange],
        recordedAt: String
    ) {
        self.runId = runId
        self.order = order
        self.text = text
        self.clearAtNextUserMessage = clearAtNextUserMessage
        self.toolChanges = toolChanges
        self.recordedAt = recordedAt
    }

    /// Rebuild the exact message that was sent.
    public var message: LLMMessage {
        toolChanges.isEmpty
            ? .system(text, clearAtNextUserMessage: clearAtNextUserMessage)
            : .toolChanges(toolChanges)
    }

    /// Only a `.system` message with content this archive can reproduce is
    /// archivable; anything else is skipped rather than approximated.
    public static func from(
        _ message: LLMMessage,
        runId: String,
        order: Int,
        recordedAt: String
    ) -> ArchivedVolatileBlock? {
        guard message.role == .system else { return nil }
        if !message.toolChanges.isEmpty {
            return ArchivedVolatileBlock(
                runId: runId, order: order, text: "",
                clearAtNextUserMessage: false,
                toolChanges: message.toolChanges, recordedAt: recordedAt
            )
        }
        let text = message.content.compactMap {
            if case .text(let value) = $0 { return value }
            return nil
        }.joined()
        guard !text.isEmpty else { return nil }
        return ArchivedVolatileBlock(
            runId: runId, order: order, text: text,
            clearAtNextUserMessage: message.turnScopedClearAtNextUserMessage,
            toolChanges: [], recordedAt: recordedAt
        )
    }
}

public actor TurnVolatileArchive {
    /// Hard ceiling independent of the cursor, so a session that somehow stops
    /// pruning cannot grow this file without bound. The cursor's own window is
    /// far smaller in practice; this is the backstop, not the rule.
    static let maxEntries = 128

    /// Orphan-sweep contract, identical to the sibling sidecars.
    private static let ttlSeconds: TimeInterval = 24 * 60 * 60
    private static let sweepIntervalSeconds: TimeInterval = 60 * 60

    private static func makeISO8601() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    nonisolated private static func iso8601Now() -> String {
        makeISO8601().string(from: Date())
    }

    private let persistence = SwiftNativePersistenceCore()
    private let dataRootOverride: URL?
    private var lastSweepAt: Date?

    public init(dataRoot: URL? = nil) {
        self.dataRootOverride = dataRoot
    }

    private func dataRoot() -> URL {
        if let dataRootOverride { return dataRootOverride }
        return PersistenceCore.defaultDataRoot()
    }

    private func sessionDirectory(_ sessionId: String) -> URL? {
        guard let safe = NativeAgentChatSessionID.normalizedPathComponent(sessionId) else {
            return nil
        }
        return dataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("prefix_window", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
    }

    private func pathFor(sessionId: String) -> URL? {
        sessionDirectory(sessionId)?.appendingPathComponent("volatile.jsonl")
    }

    // MARK: - Reads

    /// run id → the messages that turn sent after its user turn, in order.
    public func load(sessionId: String) async -> [String: [ArchivedVolatileBlock]] {
        await sweepOrphansIfDue()
        guard let path = pathFor(sessionId: sessionId) else { return [:] }
        let entries = await readLocked(path: path)
        return Dictionary(grouping: entries, by: \.runId)
            .mapValues { $0.sorted { $0.order < $1.order } }
    }

    // MARK: - Writes

    /// Record THIS turn's block.
    ///
    /// Window-bounded pruning is `prune(sessionId:keeping:)`'s job and runs on
    /// the BUILD path, which is the only place that knows which turns the
    /// prefix still replays. Splitting them keeps each caller honest about what
    /// it actually knows; this one only knows its own block. `maxEntries` is
    /// the independent backstop.
    public func record(
        sessionId: String,
        runId: String,
        messages: [LLMMessage]
    ) async {
        let trimmedRun = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Self.iso8601Now()
        let archivable = messages.enumerated().compactMap {
            ArchivedVolatileBlock.from(
                $0.element, runId: trimmedRun, order: $0.offset, recordedAt: stamp
            )
        }
        guard !trimmedRun.isEmpty, !archivable.isEmpty,
              let path = pathFor(sessionId: sessionId),
              let directory = sessionDirectory(sessionId) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? await persistence.withFileLock(path) {
            var entries = await self.readLocked(path: path)
            entries.removeAll { $0.runId == trimmedRun }
            entries.append(contentsOf: archivable)
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
            try? await self.writeLocked(entries, path: path)
        }
    }

    /// Prune alone, for the build path: it knows the replayed window before the
    /// turn's own block exists.
    public func prune(sessionId: String, keeping: Set<String>) async {
        guard let path = pathFor(sessionId: sessionId),
              FileManager.default.fileExists(atPath: path.path) else { return }
        try? await persistence.withFileLock(path) {
            let entries = await self.readLocked(path: path)
            let kept = entries.filter { keeping.contains($0.runId) }
            guard kept.count != entries.count else { return }
            try? await self.writeLocked(kept, path: path)
        }
    }

    // MARK: - Orphan sweep

    private func sweepOrphansIfDue() async {
        let now = Date()
        if let last = lastSweepAt, now.timeIntervalSince(last) < Self.sweepIntervalSeconds {
            return
        }
        lastSweepAt = now
        let dir = dataRoot()
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("prefix_window", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in entries {
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .contentModificationDateKey,
            ])
            guard values?.isDirectory == true else { continue }
            let file = url.appendingPathComponent("volatile.jsonl")
            guard let stamp = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = stamp.contentModificationDate,
                  now.timeIntervalSince(mtime) > Self.ttlSeconds else { continue }
            // 2026-09-06: the sweep used to reap `volatile.jsonl` and leave its
            // lock sidecar and the per-session directory behind — one empty
            // directory and one lock file per session ever created, kept
            // forever. Lock sidecars are reapable by design (the acquire path
            // in PersistenceCore+FileLock validates the inode it locked), which
            // is what HistoryWindowCursor's sweep already relies on.
            let reaped = (try? await persistence.withFileLock(file) { () -> Bool in
                guard let recheck = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ),
                      let mtime = recheck.contentModificationDate,
                      now.timeIntervalSince(mtime) > Self.ttlSeconds else { return false }
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: file.path + ".lock")
                )
                return true
            }) ?? false
            // 2026-09-06: removing the PARENT directory is outside any lock —
            // the file lock we just held covers `volatile.jsonl`, not the
            // directory holding it. A writer that arrives for a new turn creates
            // the directory, and if the sweep unlinks it in between, the
            // writer's lock open fails with ENOENT and its volatile block is
            // silently lost. Only reap a directory whose own mtime is older than
            // the same staleness threshold the transcript had to pass: a
            // directory a writer has just touched is left for the next sweep.
            // `values` was sampled BEFORE this pass unlinked anything inside the
            // directory — our own removals bump the directory's mtime, so a
            // re-stat here would report every directory as freshly touched.
            if reaped,
               let dirMtime = values?.contentModificationDate,
               now.timeIntervalSince(dirMtime) > Self.ttlSeconds,
               let leftovers = try? fm.contentsOfDirectory(atPath: url.path),
               leftovers.isEmpty {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers (called while holding the file lock, except the read in load())

    private func readLocked(path: URL) async -> [ArchivedVolatileBlock] {
        guard let rows = try? await persistence.readJSONL(path) else { return [] }
        return rows.compactMap { row in
            guard case .object(let object) = row,
                  case .string(let runId)? = object["runId"], !runId.isEmpty else { return nil }
            let text: String = {
                if case .string(let value)? = object["text"] { return value }
                return ""
            }()
            let order: Int = {
                if case .int(let value)? = object["order"] { return Int(value) }
                return 0
            }()
            let clearAt: Bool = {
                if case .bool(let value)? = object["clearAt"] { return value }
                return false
            }()
            var changes: [LLMToolChange] = []
            if case .array(let rawChanges)? = object["toolChanges"] {
                for entry in rawChanges {
                    guard case .object(let change) = entry,
                          case .string(let kind)? = change["kind"],
                          case .string(let name)? = change["name"], !name.isEmpty,
                          let parsed = LLMToolChange.Kind(rawValue: kind) else { continue }
                    changes.append(LLMToolChange(kind: parsed, name: name))
                }
            }
            // A row that reproduces neither kind of message is dropped rather
            // than replayed as something it was not.
            guard !text.isEmpty || !changes.isEmpty else { return nil }
            let recordedAt: String = {
                if case .string(let value)? = object["recordedAt"] { return value }
                return ""
            }()
            return ArchivedVolatileBlock(
                runId: runId, order: order, text: text,
                clearAtNextUserMessage: clearAt, toolChanges: changes,
                recordedAt: recordedAt
            )
        }
    }

    private func writeLocked(_ entries: [ArchivedVolatileBlock], path: URL) async throws {
        // Full rewrite rather than append: pruning is the common case (every
        // turn re-records this turn's block and drops what left the window), so
        // an append-only file would grow and then need compaction anyway.
        let rows = entries.map { entry in
            JSONValue.object([
                "schema": .string("chat.prefix_window.volatile.v2"),
                "runId": .string(entry.runId),
                "order": .int(Int64(entry.order)),
                "text": .string(entry.text),
                "clearAt": .bool(entry.clearAtNextUserMessage),
                "toolChanges": .array(entry.toolChanges.map { change in
                    .object([
                        "kind": .string(change.kind.rawValue),
                        "name": .string(change.name),
                    ])
                }),
                "recordedAt": .string(entry.recordedAt),
            ])
        }
        let body = try rows
            .map { try $0.serializedData(pretty: false) }
            .map { String(data: $0, encoding: .utf8) ?? "" }
            .joined(separator: "\n")
        let payload = body.isEmpty ? "" : body + "\n"
        try payload.write(to: path, atomically: true, encoding: .utf8)
    }
}

/// Per-data-root registry, for the same reason the cursor store has one: the
/// hourly sweep throttle is instance state, so a fresh actor per turn would
/// re-sweep the directory every turn.
public actor TurnVolatileArchiveRegistry {
    public static let shared = TurnVolatileArchiveRegistry()
    private var archives: [String: TurnVolatileArchive] = [:]

    public func archive(dataRoot: URL?) -> TurnVolatileArchive {
        let key = dataRoot?.standardizedFileURL.path ?? ""
        if let existing = archives[key] { return existing }
        let created = TurnVolatileArchive(dataRoot: dataRoot)
        archives[key] = created
        return created
    }
}
