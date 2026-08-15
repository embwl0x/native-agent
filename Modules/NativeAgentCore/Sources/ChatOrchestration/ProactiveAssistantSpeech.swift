import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - "She speaks" seam (L5 G7)
//
// ONE narrow path by which something that is NOT a user turn can put an
// assistant-authored message into a chat transcript. Everything proactive in
// this tree is otherwise a card or a banner; this is the single exception, and
// it is deliberately built to stay one.
//
// THREE PROPERTIES THAT MAKE IT SAFE TO EXIST:
//
//   1. ONE CALLER. `ProactiveSpeechCaller` has exactly one case
//      (`.morningBrief`). Adding a second caller is a source edit to this enum,
//      which is the review checkpoint — not a config flag, not a free-form
//      string anyone can pass. This is NOT a general broadcast API.
//
//   2. RATE LIMITED — ON THE PROACTIVE ROUTE ONLY. At most one UNPROMPTED post
//      per caller per `proactiveSpeechMinimumIntervalSeconds` (1h), and the
//      limiter state is persisted so a relaunch can't reset it into a storm
//      (same reason the trigger scheduler persists `last_fired_at`). A post User
//      asked for by pressing Act (`.userRequested`) is not a proactive post: it
//      skips the interval and never advances the proactive clock. Gating an
//      explicit button press behind an hourly quota would just be a dead
//      button.
//
//   3. IDEMPOTENCY STAMPED. Each post carries a caller-supplied key. Re-posting
//      a key this caller has recently used is a no-op reporting `.duplicate` —
//      the same contract the desk-notify loop gets from
//      `markNotifiedIfUnchanged`: the second attempt neither writes nor lies
//      about having written. This is what stops the scheduled brief and a
//      subsequent Act on that same brief's card from both landing.
//
// WHAT IS WIRED TODAY, DECLARED NOT SILENT: exactly one call site exists —
// `NativeClient.postSpokenInboxMessage`, the morning-brief card's Act handler,
// on the `.userRequested` route (L5 G6). The `.scheduled` route is built and
// tested but has NO caller: nothing in this tree yet speaks into a transcript
// without User pressing something, and turning the 8am tick into an unprompted
// chat message is a separate product decision from building the seam. Wiring it
// is one call in the trigger fire path with `initiative: .scheduled` — at which
// point the hourly quota below becomes load-bearing rather than protective.
//
// FAILURE SEMANTICS: the claim is written BEFORE the transcript append
// (at-most-once). If the append fails, the claim is rolled back under a CAS on
// our own stamp, so a transient IO error doesn't burn the day's brief — but a
// crash between the two leaves the claim standing. A missed proactive message
// is the failure mode we choose over a duplicate one.

/// The exhaustive list of code paths allowed to speak unprompted.
/// Adding a case here is the review gate for widening the seam.
public enum ProactiveSpeechCaller: String, Sendable, CaseIterable, Equatable {
    case morningBrief = "morning_brief"
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

    public var didPost: Bool {
        if case .posted = self { return true }
        return false
    }
}

/// Persisted limiter + idempotency state, one row per caller.
struct ProactiveSpeechClaim: Sendable, Equatable {
    /// Last UNPROMPTED post. nil when this caller has only ever been driven by
    /// an explicit user action.
    var lastProactivePostAt: Date?
    /// Recently used idempotency keys, oldest first, bounded by `recentKeyCap`.
    var recentKeys: [String]

    /// Bounded because this file is read on every attempt and must never grow
    /// without limit. 16 is far more than the ~1/day the one caller produces,
    /// and enough that an Act on yesterday's card still dedups.
    static let recentKeyCap = 16

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "recentKeys": .array(recentKeys.map { .string($0) }),
        ]
        if let lastProactivePostAt {
            object["lastProactivePostAt"] = .string(ProactiveSpeechState.iso8601(lastProactivePostAt))
        }
        return .object(object)
    }

    init(lastProactivePostAt: Date?, recentKeys: [String]) {
        self.lastProactivePostAt = lastProactivePostAt
        self.recentKeys = recentKeys
    }

    /// Returns nil for anything that isn't a readable row — a malformed or
    /// truncated state file degrades to "no claim recorded", which costs at
    /// most one extra post. It never throws into the caller's tick.
    init?(_ value: JSONValue?) {
        guard case .object(let object)? = value else { return nil }
        if case .string(let raw)? = object["lastProactivePostAt"] {
            self.lastProactivePostAt = ProactiveSpeechState.date(fromISO8601: raw)
        } else {
            self.lastProactivePostAt = nil
        }
        if case .array(let rows)? = object["recentKeys"] {
            self.recentKeys = rows.compactMap {
                if case .string(let key) = $0 { return key }
                return nil
            }
        } else {
            self.recentKeys = []
        }
    }

    func appending(key: String) -> ProactiveSpeechClaim {
        var keys = recentKeys.filter { $0 != key }
        keys.append(key)
        if keys.count > Self.recentKeyCap {
            keys.removeFirst(keys.count - Self.recentKeyCap)
        }
        return ProactiveSpeechClaim(lastProactivePostAt: lastProactivePostAt, recentKeys: keys)
    }
}

enum ProactiveSpeechState {
    static func path(dataRoot: URL) -> URL {
        dataRoot
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("proactive_speech.json")
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(fromISO8601 raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) { return parsed }
        return ISO8601DateFormatter().date(from: raw)
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
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(content.trimmingCharacters(in: .whitespacesAndNewlines).utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
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
        let runId = UUID().uuidString
        let interval = Self.proactiveSpeechMinimumIntervalSeconds

        enum ClaimResult: Sendable {
            case granted(previous: ProactiveSpeechClaim?)
            case duplicate
            case rateLimited(remaining: Int)
        }

        // Read-decide-write inside ONE cross-process lock: two processes racing
        // the same tick must not both claim the hour.
        let claim: ClaimResult = try await persistence.withFileLock(statePath) {
            let existing = await persistence.readJSON(statePath, defaultValue: .object([:]))
            var rows: [String: JSONValue]
            if case .object(let object) = existing { rows = object } else { rows = [:] }
            let previous = ProactiveSpeechClaim(rows[caller.rawValue])
            if previous?.recentKeys.contains(idempotencyKey) == true {
                return .duplicate
            }
            if initiative == .scheduled, let last = previous?.lastProactivePostAt {
                let elapsed = now.timeIntervalSince(last)
                // A negative elapsed (clock stepped backwards) counts as "too
                // soon". A backwards jump must not become a licence to speak.
                if elapsed < interval {
                    return .rateLimited(remaining: max(1, Int((interval - elapsed).rounded(.up))))
                }
            }
            var next = (previous ?? ProactiveSpeechClaim(lastProactivePostAt: nil, recentKeys: []))
                .appending(key: idempotencyKey)
            if initiative == .scheduled {
                next.lastProactivePostAt = now
            }
            rows[caller.rawValue] = next.jsonValue
            try await persistence.writeJSON(.object(rows), to: statePath)
            return .granted(previous: previous)
        }

        switch claim {
        case .duplicate:
            return .duplicate(sessionId: resolvedSession)
        case .rateLimited(let remaining):
            return .rateLimited(secondsRemaining: remaining)
        case .granted(let previous):
            do {
                try await appendMessage(
                    sessionId: resolvedSession,
                    role: "assistant",
                    content: trimmed,
                    runId: runId,
                    attachments: [],
                    persona: persona,
                    source: caller.rawValue
                )
            } catch {
                await rollBackProactiveSpeechClaim(
                    caller: caller,
                    ourKey: idempotencyKey,
                    restoring: previous,
                    at: statePath
                )
                throw error
            }
            return .posted(sessionId: resolvedSession, messageRunId: runId)
        }
    }

    /// CAS-guarded compensation for a failed append: restore the prior claim,
    /// but only while the newest key on disk is still the one we wrote. A newer
    /// writer's claim is never clobbered. Best-effort by design — if the
    /// rollback itself fails the cost is one skipped interval, strictly better
    /// than the duplicate a blind retry would produce.
    private func rollBackProactiveSpeechClaim(
        caller: ProactiveSpeechCaller,
        ourKey: String,
        restoring previous: ProactiveSpeechClaim?,
        at statePath: URL
    ) async {
        try? await persistence.withFileLock(statePath) {
            let existing = await persistence.readJSON(statePath, defaultValue: .object([:]))
            var rows: [String: JSONValue]
            if case .object(let object) = existing { rows = object } else { rows = [:] }
            guard let current = ProactiveSpeechClaim(rows[caller.rawValue]),
                  current.recentKeys.last == ourKey else { return }
            if let previous {
                rows[caller.rawValue] = previous.jsonValue
            } else {
                rows.removeValue(forKey: caller.rawValue)
            }
            try await persistence.writeJSON(.object(rows), to: statePath)
        }
    }
}
