import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ProactiveAssistantSpeech.swift` | `speakProactively` owns proactive transcript writes, claims, quota and destination reconciliation; Reach and chat.post share reachOut, inbox Act uses morningBrief |

// One owner for assistant speech outside a user turn. Inbox-card Act uses
// morningBrief/userRequested; Reach and app chat.post share reachOut/scheduled.
// Only userRequested skips the persisted hourly quota. All callers share the
// durable idempotency claim and destination reconciliation: duplicates never
// write again. Claim, reconciliation and append share one lock; only a
// committed transcript row proves posting, and only clean absence permits recovery.

/// The exhaustive list of code paths allowed to speak unprompted.
/// Adding a case here is the review gate for widening the seam.
public enum ProactiveSpeechCaller: String, Sendable, CaseIterable, Equatable {
    case morningBrief = "morning_brief"
    /// Her own speech, from Reach or chat.post. Both use the scheduled route
    /// and the same hourly quota; Reach also retains its own initiative gates.
    case reachOut = "reach_out"
}

/// Who asked for this message. Determines whether the hourly proactive quota
/// applies — see property 2 in the file header.
public enum ProactiveSpeechInitiative: String, Sendable, Equatable {
    /// A background lane speaking on its own initiative. Rate limited.
    case scheduled
    /// User pressed a button that means "say this to me". Not rate limited,
    /// still deduplicated.
    case userRequested
}

/// What a `speakProactively` attempt actually did. Never `Void` — a caller that
/// can't tell "posted" from "suppressed" will eventually claim the former.
public enum ProactiveSpeechOutcome: Sendable, Equatable {
    /// A new assistant row is durably in the transcript.
    case posted(sessionId: String, messageRunId: String)
    /// This caller already posted this exact key; nothing was written.
    case duplicate(sessionId: String)
    /// Proactive quota not yet expired; nothing was written.
    case rateLimited(secondsRemaining: Int)

}

public enum ProactiveSpeechError: Error, LocalizedError {
    case duplicateDestinationUnavailable
    case damagedState

    public var errorDescription: String? {
        switch self {
        case .duplicateDestinationUnavailable:
            return "This message was already claimed. Its original conversation could not be found, so it will not be posted again."
        case .damagedState:
            return "Proactive speech state is malformed. Its bytes were preserved; posting could not proceed."
        }
    }
}

/// Persisted limiter + idempotency state, one row per caller.
struct ProactiveSpeechClaim: Sendable, Equatable {
    /// Last UNPROMPTED post. nil when this caller has only ever been driven by
    /// an explicit user action.
    var lastProactivePostAt: Date?
    /// Recently used idempotency keys, oldest first, bounded by `recentKeyCap`.
    var recentKeys: [String]
    /// Where each claimed message belongs, including an uncertain append.
    var destinations: [String: Destination]

    struct Destination: Sendable, Equatable {
        let sessionId: String
        let runId: String
        /// Older claims released the claim lock before append. Absence cannot
        /// establish that one of those appenders has finished.
        var appendSerialized = false

        var jsonValue: JSONValue {
            .object(["sessionId": .string(sessionId), "runId": .string(runId),
                     "appendSerialized": .bool(appendSerialized)])
        }
    }

    /// Bounded recent claims, shared by every entry point for this caller.
    static let recentKeyCap = 16

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "recentKeys": .array(recentKeys.map { .string($0) }),
            "destinations": .object(destinations.mapValues { $0.jsonValue }),
        ]
        if let lastProactivePostAt {
            object["lastProactivePostAt"] = .string(NativeTimestampFormat.fractionalZulu(lastProactivePostAt))
        }
        return .object(object)
    }

    init(lastProactivePostAt: Date?, recentKeys: [String], destinations: [String: Destination] = [:]) {
        self.lastProactivePostAt = lastProactivePostAt
        self.recentKeys = recentKeys
        self.destinations = destinations
    }

    /// Existing state is evidence: invalid fields never become an empty claim.
    init(_ value: JSONValue) throws {
        guard case .object(let object) = value,
              case .array(let keys)? = object["recentKeys"] else { throw ProactiveSpeechError.damagedState }
        if let timestamp = object["lastProactivePostAt"] {
            guard case .string(let raw) = timestamp,
                  let date = NativeTimestampFormat.parseISO8601FractionalFirst(raw) else { throw ProactiveSpeechError.damagedState }
            self.lastProactivePostAt = date
        } else {
            self.lastProactivePostAt = nil
        }
        self.recentKeys = try keys.map {
            guard case .string(let key) = $0, !key.isEmpty else { throw ProactiveSpeechError.damagedState }
            return key
        }
        guard Set(recentKeys).count == recentKeys.count else { throw ProactiveSpeechError.damagedState }
        self.destinations = [:]
        if let value = object["destinations"] {
            guard case .object(let rows) = value else { throw ProactiveSpeechError.damagedState }
            for (key, value) in rows {
                guard recentKeys.contains(key), case .object(let row) = value,
                      case .string(let sessionId)? = row["sessionId"],
                      NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId,
                      case .string(let runId)? = row["runId"], !runId.isEmpty else { throw ProactiveSpeechError.damagedState }
                let serialized: Bool
                if let value = row["appendSerialized"] {
                    guard case .bool(let flag) = value else { throw ProactiveSpeechError.damagedState }
                    serialized = flag
                } else { serialized = false }
                destinations[key] = Destination(sessionId: sessionId, runId: runId, appendSerialized: serialized)
            }
        }
    }

    func appending(key: String, sessionId: String, runId: String) -> ProactiveSpeechClaim {
        var keys = recentKeys.filter { $0 != key }
        keys.append(key)
        if keys.count > Self.recentKeyCap {
            keys.removeFirst(keys.count - Self.recentKeyCap)
        }
        var destinations = destinations.filter { keys.contains($0.key) }
        destinations[key] = Destination(sessionId: sessionId, runId: runId, appendSerialized: true)
        return ProactiveSpeechClaim(lastProactivePostAt: lastProactivePostAt, recentKeys: keys, destinations: destinations)
    }
}

enum ProactiveSpeechState {
    static func rows(_ value: JSONValue) throws -> [String: JSONValue] {
        guard case .object(let rows) = value else { throw ProactiveSpeechError.damagedState }
        // Validate all callers before any write can replace the store.
        for row in rows.values { _ = try ProactiveSpeechClaim(row) }
        return rows
    }

    static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("proactive_speech.json")
    }

}

extension SwiftNativeChatOrchestrationClient {

    /// Minimum wall-clock gap between two PROACTIVE posts by the same caller.
    /// Config constant, not a magic number at the call site.
    public static let proactiveSpeechMinimumIntervalSeconds: TimeInterval = 60 * 60

    /// Stable idempotency key: a scope (e.g. the brief's day label) plus a
    /// digest of the content. Identical content in the same scope is one post;
    /// re-rendered content in the same scope is a different one.
    public nonisolated static func proactiveSpeechIdempotencyKey(
        scope: String,
        content: String
    ) -> String {
        // FNV-1a keeps the key short and stable without pulling a crypto digest
        // into a path that has no adversary — this key never gates trust, only
        // repetition.
        let hash = fnv1a64(content.trimmingCharacters(in: .whitespacesAndNewlines))
        return "\(scope.trimmingCharacters(in: .whitespacesAndNewlines))#\(String(hash, radix: 16))"
    }

    /// Post ONE assistant-authored message into `sessionId`. See the file
    /// header for the three properties that keep this narrow.
    ///
    /// - Throws: `ChatOrchestrationError.emptyMessage` for blank content, and
    ///   whatever `appendMessage` throws for a transcript/index failure. A throw
    ///   means "not proven posted", never "proven not posted".
    @discardableResult
    public func speakProactively(
        content: String,
        caller: ProactiveSpeechCaller,
        idempotencyKey: String,
        sessionId: String,
        initiative: ProactiveSpeechInitiative = .scheduled,
        persona: String? = nil
    ) async throws -> ProactiveSpeechOutcome {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatOrchestrationError.emptyMessage }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        let statePath = ProactiveSpeechState.path(dataRoot: dataRoot)
        let now = clock()
        let interval = Self.proactiveSpeechMinimumIntervalSeconds

        // The lock includes append: a clean absent transcript row cannot race
        // another claimant's still-running append. A crash releases the lock,
        // leaving its exact destination/run available for reconciliation.
        return try await SwiftNativePersistenceCore.withFileLock(statePath) {
            let existing = try await SwiftNativePersistenceCore.readJSON(statePath, ifMissing: .object([:]))
            var rows = try ProactiveSpeechState.rows(existing)
            var previous = try rows[caller.rawValue].map { try ProactiveSpeechClaim($0) }
            if let legacy = previous, legacy.recentKeys.contains(idempotencyKey),
               legacy.destinations[idempotencyKey] == nil {
                do {
                    let reconciled = try await reconcileProactiveSpeechDestinations(legacy, caller: caller)
                    if reconciled != legacy {
                        rows[caller.rawValue] = reconciled.jsonValue
                        try await SwiftNativePersistenceCore.writeJSON(.object(rows), to: statePath)
                        previous = reconciled
                    }
                } catch {
                    throw ProactiveSpeechError.duplicateDestinationUnavailable
                }
            }
            let destination: ProactiveSpeechClaim.Destination
            if let previous, previous.recentKeys.contains(idempotencyKey) {
                guard let recorded = previous.destinations[idempotencyKey] else {
                    throw ProactiveSpeechError.duplicateDestinationUnavailable
                }
                let committed = try await Self.readProactiveSpeechCommitment(
                    dataRoot: dataRoot, sessionId: recorded.sessionId
                ) { object in
                    guard case .object(let metadata)? = object["metadata"] else { return false }
                    return object["runId"] == .string(recorded.runId)
                        && object["source"] == .string(caller.rawValue)
                        && metadata["proactiveSpeechIdempotencyKey"] == .string(idempotencyKey)
                }
                if committed { return .duplicate(sessionId: recorded.sessionId) }
                guard recorded.appendSerialized else {
                    throw ChatOrchestrationError.underlying("This older proactive claim has no committed row. Its append may still be in flight; the outcome remains unknown.")
                }
                // Clean absence under the same lock proves the prior append
                // ended without this row. Complete that claim at its original destination.
                destination = recorded
            } else {
                if initiative == .scheduled, let last = previous?.lastProactivePostAt {
                    let elapsed = now.timeIntervalSince(last)
                    if elapsed < interval {
                        guard let remaining = Int(exactly: (interval - elapsed).rounded(.up)) else {
                            throw ProactiveSpeechError.damagedState
                        }
                        return .rateLimited(secondsRemaining: max(1, remaining))
                    }
                }
                destination = .init(sessionId: resolvedSession, runId: UUID().uuidString)
                var next = (previous ?? ProactiveSpeechClaim(lastProactivePostAt: nil, recentKeys: []))
                    .appending(key: idempotencyKey, sessionId: destination.sessionId, runId: destination.runId)
                if initiative == .scheduled { next.lastProactivePostAt = now }
                rows[caller.rawValue] = next.jsonValue
                try await SwiftNativePersistenceCore.writeJSON(.object(rows), to: statePath)
            }
            try await appendMessage(
                sessionId: destination.sessionId,
                role: "assistant",
                content: trimmed,
                runId: destination.runId,
                attachments: [],
                persona: persona,
                source: caller.rawValue,
                // A notification belongs in the transcript, without claiming
                // it was a moment the agent lived.
                mechanicalRow: .attentionNotice,
                proactiveSpeechIdempotencyKey: idempotencyKey
            )
            // Failures retain the pending claim. Its next attempt must prove
            // commitment or clean absence before doing anything else.
            return .posted(sessionId: destination.sessionId, messageRunId: destination.runId)
        }
    }

    /// Recover destinations only from independently recorded exact keys.
    /// Content alone cannot identify an inbox item; unstamped rows stay unresolved.
    private func reconcileProactiveSpeechDestinations(
        _ claim: ProactiveSpeechClaim,
        caller: ProactiveSpeechCaller
    ) async throws -> ProactiveSpeechClaim {
        let missing = claim.recentKeys.filter { claim.destinations[$0] == nil }
        let directory = dataRoot.appendingPathComponent("chat/messages", isDirectory: true)
        let paths: [URL]
        do {
            paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return claim
        }
        var recovered: [String: ProactiveSpeechClaim.Destination] = [:]
        var ambiguous: Set<String> = []
        for path in paths where path.pathExtension == "jsonl" {
            let sessionId = path.deletingPathExtension().lastPathComponent
            guard NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId else { continue }
            let transcript = try await SwiftNativePersistenceCore.withFileLock(path) {
                try await SwiftNativePersistenceCore.readJSONLReporting(path).rows
            }
            for row in transcript {
                guard case .object(let object) = row,
                      object["role"] == .string("assistant"),
                      object["source"] == .string(caller.rawValue),
                      object["sessionId"] == .string(sessionId),
                      case .object(let metadata)? = object["metadata"],
                      case .string(let key)? = metadata["proactiveSpeechIdempotencyKey"],
                      missing.contains(key),
                      case .string(let runId)? = object["runId"], !runId.isEmpty else { continue }
                let destination = ProactiveSpeechClaim.Destination(sessionId: sessionId, runId: runId)
                if let existing = recovered[key], existing != destination {
                    ambiguous.insert(key)
                } else {
                    recovered[key] = destination
                }
            }
        }
        var reconciled = claim
        for (key, destination) in recovered where !ambiguous.contains(key) {
            reconciled.destinations[key] = destination
        }
        return reconciled
    }

    /// Exact offer scope, as stamped by this owner. A claim alone is not a
    /// committed message. False proves absence only when the caller knows the
    /// corresponding append has ended; otherwise it may still be in flight.
    public static func proactiveSpeechCommitted(
        dataRoot: URL, caller: ProactiveSpeechCaller, idempotencyScope: String, sessionId: String
    ) async throws -> Bool {
        let session = try resolveSessionId(sessionId)
        let prefix = idempotencyScope.trimmingCharacters(in: .whitespacesAndNewlines) + "#"
        return try await readProactiveSpeechCommitment(
            dataRoot: dataRoot, sessionId: session
        ) { object in
            guard object["source"] == .string(caller.rawValue),
                  case .object(let metadata)? = object["metadata"],
                  case .string(let key)? = metadata["proactiveSpeechIdempotencyKey"] else { return false }
            return key.hasPrefix(prefix)
        }
    }

    private static func readProactiveSpeechCommitment(
        dataRoot: URL, sessionId: String, matches: @Sendable ([String: JSONValue]) -> Bool
    ) async throws -> Bool {
        let path = dataRoot.appendingPathComponent("chat/messages/\(sessionId).jsonl")
        return try await SwiftNativePersistenceCore.withFileLock(path) {
            // fileExists can hide an access error as absence.
            do {
                _ = try FileManager.default.attributesOfItem(atPath: path.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return false
            }
            let (rows, report) = try await SwiftNativePersistenceCore.readJSONLReporting(path)
            let committed = rows.contains { row in
                guard case .object(let object) = row else { return false }
                return object["role"] == .string("assistant")
                    && object["sessionId"] == .string(sessionId)
                    && matches(object)
            }
            guard committed || report.isClean else {
                throw ChatOrchestrationError.underlying("Message commitment could not be determined.")
            }
            return committed
        }
    }

}
