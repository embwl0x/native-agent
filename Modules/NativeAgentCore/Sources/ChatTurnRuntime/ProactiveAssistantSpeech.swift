import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore

// Blueprint: | `ProactiveAssistantSpeech.swift` | `speakProactively`; Locked deduplicated speech and destination reconciliation |

// Every speech entry shares locked claims, destination reconciliation and append so duplicate attempts never write twice.
// Only a committed transcript row proves posting; only clean absence permits recovery.

/// Keep unprompted speakers exhaustive so widening this boundary requires an explicit caller case.
public enum ProactiveSpeechCaller: String, Sendable, CaseIterable, Equatable {
    case morningBrief = "morning_brief"
    case reachOut = "reach_out"
}

/// Return a typed outcome so suppression cannot be mistaken for a posted message.
public enum ProactiveSpeechOutcome: Sendable, Equatable {
    case posted(sessionId: String, messageRunId: String)
    case duplicate(sessionId: String)
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

struct ProactiveSpeechClaim: Sendable, Equatable {
    /// Bound recent keys while preserving their oldest-first eviction order.
    var recentKeys: [String]
    /// Where each claimed message belongs, including an uncertain append.
    var destinations: [String: Destination]

    struct Destination: Sendable, Equatable {
        let sessionId: String
        let runId: String
        var jsonValue: JSONValue {
            .object(["sessionId": .string(sessionId), "runId": .string(runId)])
        }
    }

    /// Share the same bounded claim history across every entry point for this caller.
    static let recentKeyCap = 16

    var jsonValue: JSONValue {
        .object([
            "recentKeys": .array(recentKeys.map { .string($0) }),
            "destinations": .object(destinations.mapValues { $0.jsonValue }),
        ])
    }

    init(recentKeys: [String], destinations: [String: Destination] = [:]) {
        self.recentKeys = recentKeys
        self.destinations = destinations
    }

    /// Existing state is evidence: invalid fields never become an empty claim.
    init(_ value: JSONValue) throws {
        guard case .object(let object) = value,
              case .array(let keys)? = object["recentKeys"] else { throw ProactiveSpeechError.damagedState }
        self.recentKeys = try keys.map {
            guard case .string(let key) = $0, !key.isEmpty else { throw ProactiveSpeechError.damagedState }
            return key
        }
        guard Set(recentKeys).count == recentKeys.count else { throw ProactiveSpeechError.damagedState }
        self.destinations = [:]
        guard case .object(let rows)? = object["destinations"], Set(rows.keys) == Set(recentKeys) else {
            throw ProactiveSpeechError.damagedState
        }
        do {
            for (key, value) in rows {
                guard recentKeys.contains(key), case .object(let row) = value,
                      case .string(let sessionId)? = row["sessionId"],
                      NativeAgentChatSessionID.normalizedPathComponent(sessionId) == sessionId,
                      case .string(let runId)? = row["runId"], !runId.isEmpty else { throw ProactiveSpeechError.damagedState }
                destinations[key] = Destination(sessionId: sessionId, runId: runId)
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
        destinations[key] = Destination(sessionId: sessionId, runId: runId)
        return ProactiveSpeechClaim(recentKeys: keys, destinations: destinations)
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

    /// Scope plus content digest deduplicates identical messages while permitting genuinely changed content in the same scope.
    public nonisolated static func proactiveSpeechIdempotencyKey(
        scope: String,
        content: String
    ) -> String {
        // FNV-1a keeps nonadversarial deduplication keys short and stable; it never grants trust.
        let hash = fnv1a64(content.trimmingCharacters(in: .whitespacesAndNewlines))
        return "\(scope.trimmingCharacters(in: .whitespacesAndNewlines))#\(String(hash, radix: 16))"
    }

    /// An append failure proves only that posting is unresolved; reconcile before any repeat.
    /// Blank content and transcript/index failures propagate to the caller.
    @discardableResult
    public func speakProactively(
        content: String,
        caller: ProactiveSpeechCaller,
        idempotencyKey: String,
        sessionId: String,
        persona: String? = nil,
        turn: Turn
    ) async throws -> ProactiveSpeechOutcome {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChatOrchestrationError.emptyMessage }
        let resolvedSession = try Self.resolveSessionId(sessionId)
        let statePath = ProactiveSpeechState.path(dataRoot: dataRoot)

        // The lock includes append: a clean absent transcript row cannot race
        // another claimant's still-running append. A crash releases the lock,
        // leaving its exact destination/run available for reconciliation.
        return try await SwiftNativePersistenceCore.withFileLock(statePath) {
            let existing = try await SwiftNativePersistenceCore.readJSON(statePath, ifMissing: .object([:]))
            var rows = try ProactiveSpeechState.rows(existing)
            let previous = try rows[caller.rawValue].map { try ProactiveSpeechClaim($0) }
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
                // Clean absence under the same lock proves the prior append
                // ended without this row. Complete that claim at its original destination.
                destination = recorded
            } else {
                destination = .init(sessionId: resolvedSession, runId: UUID().uuidString)
                let next = (previous ?? ProactiveSpeechClaim(recentKeys: []))
                    .appending(key: idempotencyKey, sessionId: destination.sessionId, runId: destination.runId)
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
                proactiveSpeechIdempotencyKey: idempotencyKey,
             turn: turn)
            // Failures retain the pending claim. Its next attempt must prove
            // commitment or clean absence before doing anything else.
            return .posted(sessionId: destination.sessionId, messageRunId: destination.runId)
        }
    }

    /// A claim does not prove posting. Absence is conclusive only after the corresponding append has ended.
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
            // Use checked existence because fileExists can conceal access failure as absence.
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
