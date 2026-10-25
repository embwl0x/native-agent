import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TurnTrace.swift` | `TurnTraceEvent.isTerminalKind` and `TerminalState` own terminal kind/status vocabulary for chat and restore settlement; durable terminal delivery (its notification carries the trace day file, session, surface and the part whose run started the turn) before checkpoint retirement; bounded ingress/disk queues retain their sole workers through settlement, checked JSONL framing before kind/turn filtering including one exact day-file read per receipt lookup without a retention scan, and first-render correlation/publication; turn-bound calls, dispatches and plans persist only here, with standalone and unmatched historical ledger rows through `traceEvidence`, preserving historical outcomes when canonical status is absent; model-call rows retain the former ledger byte budget to preserve cache-prefix evidence |

// MARK: - Turn Inspector W1 (turn-inspector build plan, ledger d6143561)
//
// The turnId SPINE + in-process multicast BUS + persist lane that correlate
// every event of one chat turn into a single replayable story. This is the
// foundation the W2 emission points, W3 Mac Inspector tab, and W4 iOS summary
// lane all build on. W1 does NOT add new emission points — it threads turnId
// through the THREE existing emitters (llm.call, tool.dispatch, memory.commit)
// and mirrors each onto the bus.
//
// LIVES IN PersistenceCore because it is the lowest common module the three
// emitters can all see: `llm.call` is written from ProviderRouting, and
// `tool.dispatch` / `memory.commit` from ChatOrchestration — both depend on
// PersistenceCore, and PersistenceCore already owns `JSONValue`,
// `appendJSONLCapped`, `withFileLock`, and `defaultDataRoot()`.
//
// THE U5 LESSON IS CANON: a slow observer must NEVER slow the turn. Emission
// is fire-and-forget. The bus never awaits a subscriber; a subscriber whose
// bounded buffer is full drops the event (counted per subscriber). The persist
// lane runs on a detached utility task off the hot path.

// MARK: - TurnTraceContext (request-scoped turnId spine)

/// Task-local turn correlation id, bound ONCE per chat turn at the turn-engine
/// entry (SwiftNativeTurnEngine.streamTurn / .executeTurnWithStreamingToolLoop). Every
/// surface that runs a turn through the engine inherits it for free, and it
/// propagates into the unstructured `Task {}` / `AsyncThrowingStream` inner
/// tasks the same way `LLMCallContext.sessionId` does (the binding wraps the
/// synchronous work that creates the inner task; the task inherits the value
/// at creation).
///
/// Unbound (nil) → emitters tag rows with turnId "unknown" and the bus mirror
/// is skipped (an event with no turn has no story to join). This keeps any
/// non-turn caller (a direct tool dispatch, a background loop's LLM call)
/// byte-identical to pre-W1 behavior on the persist lane EXCEPT for the
/// additive turnId field, which reads "unknown".
public enum TurnTraceContext {
    @TaskLocal public static var turnId: String?
    /// Optional request-scoped bus override for hermetic tests and diagnostics.
    /// Production leaves this nil so context-based emitters mirror to `.shared`.
    @TaskLocal public static var bus: TurnTraceBus?

    /// The conversation this turn is answering INTO — the same
    /// chat/channel + topic/thread pair the reply route carries
    /// (`ChatToolSessionContext.replyRoute`), mirrored down here because
    /// PersistenceCore is below ChatOrchestration and cannot read it.
    ///
    /// 2026-09-13: trace rows stamped `surface` and `sessionId` but never this
    /// pair, so the reader that decides whether a knock can go back to the
    /// conversation it came from had nothing to read and always said no. Bound
    /// once per turn beside `turnId`, so every row of the turn carries it.
    /// Unbound for turns with no return route (a local Mac turn, a background
    /// loop) — which is exactly the fallback-to-phone case.
    @TaskLocal public static var destinationId: String?
    @TaskLocal public static var threadId: String?

    /// The row a surface is already drawing this turn's reply in. The turn's
    /// answer is written under that id, so the reply the person watched arrive
    /// is the row that stays: nothing is swapped out when it lands.
    @TaskLocal public static var replyRow: ReplyRow?

    public struct ReplyRow: Sendable, Equatable {
        public let turnId: String
        public let messageId: String
        public init(turnId: String, messageId: String) {
            self.turnId = turnId
            self.messageId = messageId
        }
    }

    /// Mint a fresh UUID-based turn id. Lowercased to match the row-id
    /// convention used across the trace writers.
    public static func mintTurnId() -> String {
        UUID().uuidString.lowercased()
    }

}

/// Correlates the Mac UI's first visible assistant bubble with the turn trace
/// without putting UI concerns into the provider loop. Entries are bounded and
/// single-claim: an old bubble or a later delta cannot emit a duplicate render.
public actor TurnFirstRenderRegistry {
    public static let shared = TurnFirstRenderRegistry()

    private struct Pending: Sendable {
        let turnId: String
        let surface: String
        let registeredAtUptimeNs: UInt64
    }

    private let maximumEntries: Int
    private var pendingBySession: [String: Pending] = [:]
    private var insertionOrder: [String] = []

    public init(maximumEntries: Int = 256) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func register(turnId: String, sessionId: String, surface: String) {
        let session = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !turnId.isEmpty, !session.isEmpty else { return }
        if pendingBySession[session] == nil { insertionOrder.append(session) }
        pendingBySession[session] = Pending(
            turnId: turnId,
            surface: surface,
            registeredAtUptimeNs: DispatchTime.now().uptimeNanoseconds
        )
        while insertionOrder.count > maximumEntries {
            pendingBySession.removeValue(forKey: insertionOrder.removeFirst())
        }
    }

    /// The mounted surface reports visibility; correlation and publication
    /// remain with the registry that owns the turn's single render claim.
    public func observeFirstRender(
        role: String,
        content: String,
        isLastAssistant: Bool,
        messageSessionID: String?,
        messageTurnID: String?,
        activeSessionID: String,
        observedBy: String
    ) {
        guard role == "assistant", isLastAssistant,
              content.contains(where: { !$0.isWhitespace }) else { return }
        // A present-but-blank message session must not claim the active tab.
        let sessionID = (messageSessionID ?? activeSessionID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, let turnID = messageTurnID, !turnID.isEmpty,
              let event = claimFirstRenderEvent(
                sessionId: sessionID, turnId: turnID, observedBy: observedBy
              ) else { return }
        TurnTraceBus.fire(event)
    }

    public func claimFirstRenderEvent(
        sessionId: String,
        turnId: String,
        observedBy: String
    ) -> TurnTraceEvent? {
        let session = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty, let pending = pendingBySession[session], pending.turnId == turnId else {
            return nil
        }
        pendingBySession.removeValue(forKey: session)
        insertionOrder.removeAll { $0 == session }
        let elapsedMs = Int64(
            (DispatchTime.now().uptimeNanoseconds &- pending.registeredAtUptimeNs) / 1_000_000
        )
        return TurnTraceEvent(
            turnId: pending.turnId,
            kind: "surface.firstRender",
            sessionId: session,
            surface: pending.surface,
            payload: .object([
                "schema": .string("turn.lifecycle.v1"),
                "milestone": .string("surface.firstRender"),
                "observedBy": .string(observedBy),
                "elapsedMs": .int(elapsedMs),
            ])
        )
    }
}

// MARK: - TurnTraceEvent (the canonical W1 event schema)

/// One event in a turn's story. Built at each tagged emitter and handed to
/// `TurnTraceBus.emit`, which mirrors it to live subscribers AND appends it to
/// the per-day persist lane.
///
/// PRIVACY (hard constraint, same discipline as the existing trace writers):
/// the payload is PRE-REDACTED at construction — never raw prompt/completion
/// bodies, never bot tokens. String fields are bounded to
/// `maxPayloadStringChars` so an oversized field can't bloat the feed.
public struct TurnTraceEvent: Sendable, Equatable {
    public enum TerminalState: String, Sendable, Codable {
        case completed, stopped, interrupted, waiting, failed
    }
    /// Per-string-field cap applied to every string LEAF in the payload.
    public static let maxPayloadStringChars = 2000
    /// Hard serialized persisted-row ceiling for turn events. Model-call
    /// receipts retain the mixed ledger's existing traceMaximumBytes budget
    /// so moving their owner cannot clip cache-prefix evidence.
    /// The payload is sized together
    /// with the event envelope; bounding the payload alone can still write a
    /// line over the promised limit once ids, timestamp, kind and surface are
    /// added.
    public static let maxPayloadBytes = 12 * 1024
    // Keep hostile envelope metadata from consuming the space reserved for
    // the frozen context.snapshot scalar manifest.
    private static let maxEnvelopeFieldUTF8Bytes = 480
    private static let maxEnvelopeFieldJSONBytes = 512
    private static let oversizedPreviewBytes = 6 * 1024

    /// Whose words steered the turn in flight, when they are not the owner's.
    /// Installed by the engine over the turn's own taint.
    public static var steer: @Sendable () -> String? {
        get { steerLock.withLock { steerHook } }
        set { steerLock.withLock { steerHook = newValue } }
    }
    private static let steerLock = NSLock()
    nonisolated(unsafe) private static var steerHook: @Sendable () -> String? = { nil }

    public let turnId: String
    public let ts: Date
    public let kind: String
    private static let terminalKinds: Set<String> = ["turn.terminal", "turn.cancelled", "turn.failed"]
    public static func isTerminalKind(_ kind: String) -> Bool { terminalKinds.contains(kind) }
    public let sessionId: String?
    public let surface: String?
    /// The conversation this turn answers into. Defaulted from
    /// `TurnTraceContext` — the turn's own reply route — so no emission point
    /// has to pass it, and captured HERE (on the turn's task) rather than at
    /// serialization time, which happens on a detached persist lane that does
    /// not inherit task-locals.
    public let destinationId: String?
    public let threadId: String?
    /// Callers must redact sensitive content. Construction bounds payload size
    /// and string lengths; it does not run TurnTraceRedactor.
    public let payload: JSONValue

    public init(
        turnId: String,
        ts: Date = Date(),
        kind: String,
        sessionId: String? = nil,
        surface: String? = nil,
        destinationId: String? = nil,
        threadId: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        let boundedTurnID = Self.boundEnvelopeString(turnId)
        let boundedKind = Self.boundEnvelopeString(kind)
        let boundedSessionID = sessionId.map(Self.boundEnvelopeString)
        let boundedSurface = surface.map(Self.boundEnvelopeString)
        let boundedDestination = (destinationId ?? TurnTraceContext.destinationId)
            .map(Self.boundEnvelopeString)
        let boundedThread = (threadId ?? TurnTraceContext.threadId)
            .map(Self.boundEnvelopeString)
        // A turn's end names the part whose run started it (its end must not
        // wake that part) and whose words steered it, read on the turn's own task.
        var payload = payload
        if Self.isTerminalKind(boundedKind), case .object(var fields) = payload {
            if let part = SkillRunContext.partID { fields["part"] = .string(part) }
            if let steer = Self.steer() { fields["steered_by"] = .string(steer) }
            payload = .object(fields)
        }
        self.turnId = boundedTurnID
        self.ts = ts
        self.kind = boundedKind
        self.sessionId = boundedSessionID
        self.surface = boundedSurface
        self.destinationId = boundedDestination
        self.threadId = boundedThread
        self.payload = TurnTraceEvent.boundPayload(
            payload,
            turnId: boundedTurnID,
            ts: ts,
            kind: boundedKind,
            sessionId: boundedSessionID,
            surface: boundedSurface,
            destinationId: boundedDestination,
            threadId: boundedThread
        )
    }

    private init(
        canonicalTurnId: String,
        ts: Date,
        canonicalKind: String,
        canonicalSessionId: String?,
        canonicalSurface: String?,
        canonicalDestinationId: String?,
        canonicalThreadId: String?,
        boundedPayload: JSONValue
    ) {
        self.turnId = canonicalTurnId
        self.ts = ts
        self.kind = canonicalKind
        self.sessionId = canonicalSessionId
        self.surface = canonicalSurface
        self.destinationId = canonicalDestinationId
        self.threadId = canonicalThreadId
        self.payload = boundedPayload
    }

    /// Bound turn-event string leaves, then enforce the serialized row ceiling.
    /// Model-call telemetry keeps its original ledger payload and byte budget.
    /// Oversized payloads retain stable lifecycle fields plus a bounded JSON
    /// preview, original byte count, and digest so truncation remains explicit
    /// without making the per-day ledger unbounded.
    static func boundPayload(
        _ value: JSONValue,
        turnId: String,
        ts: Date,
        kind: String,
        sessionId: String?,
        surface: String?,
        destinationId: String? = nil,
        threadId: String? = nil
    ) -> JSONValue {
        let byteLimit = kind == "llm.call" ? JSONLLineCaps.traceMaximumBytes : maxPayloadBytes
        let leafBound = kind == "llm.call" ? value : boundLeaves(value)
        guard persistedRowBytes(
                payload: leafBound,
                turnId: turnId,
                ts: ts,
                kind: kind,
                sessionId: sessionId,
                surface: surface,
                destinationId: destinationId,
                threadId: threadId
              ).map({ $0 > byteLimit }) == true,
              let serialized = try? leafBound.serializedData(pretty: false) else {
            return leafBound
        }

        var summary: [String: JSONValue] = [
            "_truncated": .bool(true),
            "_originalBytes": .int(Int64(serialized.count)),
            "_sha256": .string(
                SHA256.hash(data: serialized)
                    .map { String(format: "%02x", $0) }
                    .joined()
            ),
            "_preview": .string(
                String(decoding: serialized.prefix(oversizedPreviewBytes), as: UTF8.self)
                + "…[payload byte limit]"
            ),
        ]
        if case .object(let object) = leafBound {
            // Canonical model-call receipts retain every scalar measurement
            // when larger structured metadata forces preview summarization.
            if kind == "llm.call" {
                for (key, field) in object {
                    switch field {
                    case .array, .object: continue
                    default: summary[key] = field
                    }
                }
            }
            let stableKeys = [
                "schema", "phase", "status", "name", "tool", "stage",
                "milestone", "provider", "model", "resultClass",
                "durationMs", "elapsedMs", "inputTokens", "outputTokens",
                "argKeys", "shown", "receipt", "parentId", "cacheMarkers",
                // Context snapshots can include bounded previews that are
                // intentionally much larger than one trace row. Keep their
                // scalar integrity facts when that preview is summarized so
                // the canonical row stays queryable rather than leaving a
                // JSON fragment whose surviving keys depend on sort order.
                "containsCognitiveSubstrate", "cognitiveCapsuleBytes", "cognitiveCue",
                "toolSchemaCount", "toolSchemaParameterBytes",
                "toolSchemaMaterialBytes", "toolSchemaFingerprintSHA256",
                "promptFingerprintSHA256", "systemTotalBytes",
                "stableBytes", "dynamicBytes", "userMessageBytes",
                "userBlockBytes", "preparationMs",
                "promptTextBytes", "imagePayloadBytes", "segmented",
                // The composer's context receipt reads these five as well.
                // Every real turn carries previews, so every real snapshot row
                // is summarized here — a component left off this list is not
                // "sometimes missing", it never reaches disk at all, and the
                // receipt would silently drop that line on every turn.
                // `memoryRecall` is a four-field object, well inside the 1 KiB
                // per-field guard below.
                "historyMessageBytes", "historyMessageCount",
                "volatileBlockBytes", "personaSourceBytes", "memoryRecall",
                "toolCatalogSystemBytes", "toolCatalogBriefBytes",
            ]
            for key in stableKeys {
                guard let field = object[key],
                      let bytes = try? field.serializedData(pretty: false),
                      bytes.count <= (key == "receipt" ? 8_192 : 1_024) else { continue }
                summary[key] = field
            }
        }
        var previewBytes = min(oversizedPreviewBytes, serialized.count)
        while true {
            summary["_preview"] = .string(
                String(decoding: serialized.prefix(previewBytes), as: UTF8.self)
                + "…[payload byte limit]"
            )
            let bounded = JSONValue.object(summary)
            let rowBytes = persistedRowBytes(
                payload: bounded,
                turnId: turnId,
                ts: ts,
                kind: kind,
                sessionId: sessionId,
                surface: surface,
                destinationId: destinationId,
                threadId: threadId
            ) ?? Int.max
            if rowBytes <= byteLimit { return bounded }
            guard previewBytes > 0 else { break }
            previewBytes = max(0, previewBytes - max(256, rowBytes - byteLimit + 64))
        }

        // Defensive fallback removes optional lifecycle fields only. The
        // context.snapshot scalar manifest is a persisted contract and may
        // never be traded away to make room for hostile envelope metadata.
        summary.removeValue(forKey: "_preview")
        for key in [
            "argKeys", "outputTokens", "inputTokens",
            "elapsedMs", "durationMs", "resultClass", "provider", "milestone",
            "stage", "tool", "name", "status", "phase",
        ] {
            let candidate = JSONValue.object(summary)
            if persistedRowBytes(
                payload: candidate,
                turnId: turnId,
                ts: ts,
                kind: kind,
                sessionId: sessionId,
                surface: surface,
                destinationId: destinationId,
                threadId: threadId
            ).map({ $0 <= byteLimit }) == true {
                return candidate
            }
            summary.removeValue(forKey: key)
        }
        // With four envelope fields capped at 512 serialized bytes, the fixed
        // scalar manifest plus integrity fields has a reserved budget well
        // below 12 KiB. Return it intact; never fall back to integrity-only.
        return .object(summary)
    }

    private static func persistedRowBytes(
        payload: JSONValue,
        turnId: String,
        ts: Date,
        kind: String,
        sessionId: String?,
        surface: String?,
        destinationId: String? = nil,
        threadId: String? = nil
    ) -> Int? {
        var row: [String: JSONValue] = [
            "turnId": .string(turnId),
            "ts": .string(ts.formatted(fractionalISO8601)),
            "kind": .string(kind),
            "payload": payload,
        ]
        if let sessionId { row["sessionId"] = .string(sessionId) }
        if let surface { row["surface"] = .string(surface) }
        if let destinationId { row["destinationId"] = .string(destinationId) }
        if let threadId { row["threadId"] = .string(threadId) }
        return try? (JSONValue.object(row).serializedData(pretty: false).count + 1)
    }

    private static func boundLeaves(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(boundString(s))
        case .array(let arr):
            return .array(arr.map { boundLeaves($0) })
        case .object(let obj):
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(obj.count)
            for (k, v) in obj { out[k] = boundLeaves(v) }
            return .object(out)
        case .null, .bool, .int, .double:
            return value
        }
    }

    static func boundString(_ s: String) -> String {
        let cap = maxPayloadStringChars
        guard s.count > cap else { return s }
        // Keep the newest-truncation honest: prefix kept, marker appended.
        let prefix = String(s.prefix(cap))
        return prefix + "…[+\(s.count - cap) chars]"
    }

    /// Envelope fields are bounded by UTF-8 bytes, then checked in their JSON
    /// string representation. Character-count caps are not byte caps (`🧠` is
    /// one Character and four bytes), and JSON escaping can add bytes again.
    private static func boundEnvelopeString(_ value: String) -> String {
        let source = Data(value.utf8)
        if source.count <= maxEnvelopeFieldUTF8Bytes,
           (try? JSONValue.string(value).serializedData(pretty: false).count)
                .map({ $0 <= maxEnvelopeFieldJSONBytes }) == true {
            return value
        }

        var prefixBytes = min(source.count, maxEnvelopeFieldUTF8Bytes)
        while prefixBytes >= 0 {
            guard let prefix = String(data: source.prefix(prefixBytes), encoding: .utf8) else {
                prefixBytes -= 1
                continue
            }
            let marker = "…[+\(source.count - prefixBytes) bytes]"
            let candidate = prefix + marker
            let utf8Count = candidate.utf8.count
            let jsonCount = try? JSONValue.string(candidate).serializedData(pretty: false).count
            if utf8Count <= maxEnvelopeFieldUTF8Bytes,
               jsonCount.map({ $0 <= maxEnvelopeFieldJSONBytes }) == true {
                return candidate
            }
            prefixBytes -= max(1, utf8Count - maxEnvelopeFieldUTF8Bytes)
        }
        return "…[+\(source.count) bytes]"
    }

    /// Decode one persisted JSONL row back into a `TurnTraceEvent` — the inverse
    /// of `jsonRow`, used by the W3 replay lane to reconstruct events off disk.
    /// Returns nil for a malformed row (missing required field, bad ts) so the
    /// replay reader can SKIP it and keep going rather than crash on one bad
    /// line. `ts` parses ISO8601 (the format `jsonRow` writes); a row whose ts
    /// can't be parsed is rejected (a turn event with no honest timestamp can't
    /// be placed on the timeline).
    ///
    /// Note: re-bounds string leaves through the same `boundPayload` the
    /// `init` applies (defense in depth — a hand-edited or pre-cap row can't
    /// smuggle an oversized leaf into the live UI).
    public init?(jsonRow value: JSONValue) {
        guard case .object(let obj) = value,
              case .string(let turnId)? = obj["turnId"],
              case .string(let kind)? = obj["kind"],
              case .string(let tsString)? = obj["ts"],
              // Fractional first (current write format), plain second (rows
              // persisted before the sub-second fix).
              let ts = Self.parseISO8601(tsString)
        else { return nil }
        var sessionId: String? = nil
        if case .string(let s)? = obj["sessionId"] { sessionId = s }
        var surface: String? = nil
        if case .string(let s)? = obj["surface"] { surface = s }
        var destinationId: String? = nil
        if case .string(let s)? = obj["destinationId"] { destinationId = s }
        var threadId: String? = nil
        if case .string(let s)? = obj["threadId"] { threadId = s }
        let payload = obj["payload"] ?? .object([:])
        self.init(
            turnId: turnId,
            ts: ts,
            kind: kind,
            sessionId: sessionId,
            surface: surface,
            destinationId: destinationId,
            threadId: threadId,
            payload: payload
        )
    }

    /// Decode a physical persisted row without repeating the expensive payload
    /// serialization proof that the writer already completed. The fast path is
    /// admitted only when the physical row is within the canonical byte cap,
    /// every envelope field is already canonical, and no payload string leaf
    /// needs clipping. A hand-edited, legacy, or oversized row falls back to
    /// `init(jsonRow:)`, preserving the replay lane's defense-in-depth contract.
    public init?(persistedJSONRow value: JSONValue, physicalByteCount: Int) {
        guard case .object(let obj) = value,
              case .string(let turnId)? = obj["turnId"],
              case .string(let kind)? = obj["kind"],
              case .string(let tsString)? = obj["ts"],
              let ts = Self.parseISO8601(tsString)
        else { return nil }
        let sessionId: String? = if case .string(let value)? = obj["sessionId"] {
            value
        } else {
            nil
        }
        let surface: String? = if case .string(let value)? = obj["surface"] {
            value
        } else {
            nil
        }
        let destinationId: String? = if case .string(let value)? = obj["destinationId"] {
            value
        } else {
            nil
        }
        let threadId: String? = if case .string(let value)? = obj["threadId"] {
            value
        } else {
            nil
        }
        let payload = obj["payload"] ?? .object([:])
        let envelopeIsCanonical = Self.boundEnvelopeString(turnId) == turnId
            && Self.boundEnvelopeString(kind) == kind
            && sessionId.map(Self.boundEnvelopeString) == sessionId
            && surface.map(Self.boundEnvelopeString) == surface
            && destinationId.map(Self.boundEnvelopeString) == destinationId
            && threadId.map(Self.boundEnvelopeString) == threadId
        guard physicalByteCount > 0,
              physicalByteCount <= (kind == "llm.call" ? JSONLLineCaps.traceMaximumBytes : Self.maxPayloadBytes),
              envelopeIsCanonical,
              kind == "llm.call" || !Self.hasOversizedStringLeaf(payload) else {
            self.init(jsonRow: value)
            return
        }
        self.init(
            canonicalTurnId: turnId,
            ts: ts,
            canonicalKind: kind,
            canonicalSessionId: sessionId,
            canonicalSurface: surface,
            canonicalDestinationId: destinationId,
            canonicalThreadId: threadId,
            boundedPayload: payload
        )
    }

    private static func hasOversizedStringLeaf(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let string):
            return string.count > maxPayloadStringChars
        case .array(let values):
            return values.contains(where: hasOversizedStringLeaf)
        case .object(let values):
            return values.values.contains(where: hasOversizedStringLeaf)
        case .null, .bool, .int, .double:
            return false
        }
    }

    /// Parse a persisted ts: fractional-seconds ISO8601 (the current write
    /// format) and plain seconds for rows persisted before the sub-second fix.
    public static func parseISO8601(_ s: String) -> Date? {
        if let d = try? fractionalISO8601.parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }

    /// 2026-09-23: one shared Sendable style, not a new ISO8601DateFormatter per
    /// row. Summaries re-parse every row at launch and after each iPhone/iCloud sync.
    static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// The persisted JSONL row shape. Matches the {turnId, ts, kind,
    /// sessionId?, surface?, payload} schema in the W1 brief. `ts` is ISO8601
    /// WITH FRACTIONAL SECONDS: persistence off the bus is fire-and-forget, so
    /// file append order is NOT emission order — whole-second timestamps made
    /// same-second events tie and replay shuffled them (a begin rendered after
    /// its end, observed live 2026-06-12). Sub-second ts restores an honest
    /// chronological replay sort without relying on file order.
    public var jsonRow: JSONValue {
        var obj: [String: JSONValue] = [
            "turnId": .string(turnId),
            "ts": .string(ts.formatted(Self.fractionalISO8601)),
            "kind": .string(kind),
            "payload": payload,
        ]
        if let sessionId { obj["sessionId"] = .string(sessionId) }
        if let surface { obj["surface"] = .string(surface) }
        // The conversation this turn answered into. Additive: a row without a
        // return route omits both keys exactly as before.
        if let destinationId { obj["destinationId"] = .string(destinationId) }
        if let threadId { obj["threadId"] = .string(threadId) }
        return .object(obj)
    }
}

// MARK: - TurnTraceBus (in-process multicast, drop-on-backpressure)

/// In-process multicast for live turn events. Subscribers register a bounded
/// buffer; `emit` is fire-and-forget and NEVER awaits a subscriber. When a
/// subscriber's buffer is full the event is DROPPED for that subscriber and the
/// drop is counted — a slow observer (the Inspector tab on a busy turn) can
/// never apply backpressure to Agent's turn.
public actor TurnTraceBus {
    public static let shared = TurnTraceBus()

    /// Default per-subscriber ring capacity. Bounded so a stalled consumer
    /// can't grow memory without limit.
    public static let defaultBufferCapacity = 512

    public struct Subscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<TurnTraceEvent>
        /// Event-driven loss signal for this exact sink. Values are cumulative
        /// and emitted only when the count changes, so diagnostics never need
        /// a timer just to discover a terminal burst overflow.
        public let dropCounts: AsyncStream<Int>
        init(id: UUID, stream: AsyncStream<TurnTraceEvent>, dropCounts: AsyncStream<Int>) {
            self.id = id
            self.stream = stream
            self.dropCounts = dropCounts
        }
    }

    private struct Sink {
        let continuation: AsyncStream<TurnTraceEvent>.Continuation
        let dropContinuation: AsyncStream<Int>.Continuation
        var drops: Int
    }

    private var sinks: [UUID: Sink] = [:]

    /// Persistence is a separate, per-bus bounded FIFO. The global ingress
    /// pump must only wait for the actor's nonblocking live delivery; waiting
    /// for a flock'd disk append here let one diagnostic burst delay terminal
    /// traces for unrelated live turns by seconds.
    private nonisolated let persistPump: _PersistPump

    public init(persistLane: TurnTracePersistLane = TurnTracePersistLane()) {
        self.persistPump = _PersistPump(lane: persistLane, capacity: 4096)
    }

    // MARK: Subscribe / unsubscribe

    /// Register a bounded subscriber. Returns a `Subscription` whose `stream`
    /// yields live events until `unsubscribe(id:)` is called or the consumer
    /// stops iterating (onTermination unregisters automatically).
    public func subscribe(
        capacity: Int = TurnTraceBus.defaultBufferCapacity
    ) -> Subscription {
        let id = UUID()
        let cap = max(1, capacity)
        let (stream, continuation) = AsyncStream<TurnTraceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(cap)
        )
        let (dropCounts, dropContinuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        sinks[id] = Sink(
            continuation: continuation,
            dropContinuation: dropContinuation,
            drops: 0
        )
        continuation.onTermination = { [weak self] _ in
            // Consumer went away (cancel / break out of for-await). Detached so
            // we never await from the termination callback.
            Task { [weak self] in await self?.removeSink(id) }
        }
        return Subscription(id: id, stream: stream, dropCounts: dropCounts)
    }

    public func unsubscribe(_ id: UUID) {
        removeSink(id)
    }

    private func removeSink(_ id: UUID) {
        if let sink = sinks.removeValue(forKey: id) {
            sink.continuation.finish()
            sink.dropContinuation.finish()
        }
    }

    /// Drop count observed for a subscriber so far.
    public func dropCount(_ id: UUID) -> Int {
        sinks[id]?.drops ?? 0
    }

    // MARK: Emit

    /// One bounded FIFO and at most one drain task replace the old one-detached-
    /// task-per-event handoff. Telemetry remains nonblocking and lossy under
    /// distress without allowing thousands of suspended task allocations.
    private nonisolated static let emissionPump = _FIFO<PendingEmission>(capacity: 4096)

    private struct PendingEmission: Sendable {
        let event: TurnTraceEvent
        let bus: TurnTraceBus
    }

    private final class _FIFO<Element: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [Element] = []
        private var head = 0
        private var worker: Task<Void, Never>?
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []
        private let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        /// Queue admission and publication of the sole retained worker share
        /// the lock. Its handle retires only after the final delivery settles.
        func enqueue(_ pending: Element, deliver: @escaping @Sendable (Element) async -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard queue.count - head < capacity else { return }
            queue.append(pending)
            guard worker == nil else { return }
            worker = Task.detached(priority: .utility) { [self] in
                while let next = self.next() { await deliver(next) }
            }
        }
        func next() -> Element? {
            lock.lock()
            guard head < queue.count else {
                queue.removeAll(keepingCapacity: true)
                head = 0
                worker = nil
                let waiters = idleWaiters
                idleWaiters.removeAll()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
                return nil
            }
            let value = queue[head]
            head += 1
            if head >= 256, head * 2 >= queue.count {
                queue.removeFirst(head)
                head = 0
            }
            lock.unlock()
            return value
        }
        /// Suspend until the pump is idle (queue empty AND the drain worker,
        /// which pops each item BEFORE awaiting its delivery, has finished its
        /// final delivery and observed the empty queue). Resumes immediately
        /// when already idle. Process-exit drain for short-lived CLI hosts;
        /// the hot emit path never touches this.
        func waitUntilIdle() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard worker != nil || head < queue.count else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// One writer task per bus, never one task per event. This preserves the
    /// persisted order for a turn while isolating a slow data root from
    /// every other bus using the process-wide ingress pump. Trace persistence
    /// remains explicitly lossy under sustained distress and bounded to 4096
    /// pending rows.
    private final class _PersistPump: Sendable {
        let lane: TurnTracePersistLane
        private let queue: _FIFO<TurnTraceEvent>

        init(lane: TurnTracePersistLane, capacity: Int) {
            self.lane = lane
            self.queue = _FIFO(capacity: capacity)
        }

        func submit(_ event: TurnTraceEvent) {
            queue.enqueue(event) { [lane] next in
                await lane.append(next)
            }
        }

        func waitUntilIdle() async {
            await queue.waitUntilIdle()
        }
    }

    /// Await full quiescence of the fire→deliver→persist pipeline for this
    /// bus: first the process-wide emission pump (idle ⇒ every accepted event
    /// has completed `deliver`, which enqueues onto the persist lane), then
    /// this bus's persist pump (idle ⇒ every enqueued row is on disk).
    ///
    /// For SHORT-LIVED HOSTS ONLY (chat-drive and peers): the app process
    /// stays alive so the detached persists always land, but a CLI that exits
    /// right after a turn races its own telemetry to `exit(0)` and loses the
    /// terminal receipt. Rows dropped at either bounded gate under distress
    /// stay dropped — this drains what was accepted; it cannot resurrect
    /// load-shed events. Never call on a turn's hot path.
    public nonisolated func drainForProcessExit() async {
        await Self.emissionPump.waitUntilIdle()
        await persistPump.waitUntilIdle()
    }

    /// Fire-and-forget emission entry. NEVER call from the hot path with
    /// `await` on the bus mutation — use this static shim, which spawns the
    /// actor hand-off through the retained pump so the caller only enqueues.
    /// In-flight emissions are BOUNDED (4096); over the cap the event drops
    /// at the gate so a stalled disk can never grow task backlog.
    ///
    /// The persist lane append is ALSO detached (off the caller's path). A
    /// nil-turnId event is dropped — it has no story to join (matches the
    /// "unbound → no mirror" contract of TurnTraceContext).
    public nonisolated static func fire(_ event: TurnTraceEvent, on bus: TurnTraceBus = .shared) {
        emissionPump.enqueue(.init(event: event, bus: bus)) { pending in
            await pending.bus.deliver(pending.event)
        }
    }

    /// Convenience: build + fire in one call, reading turnId/sessionId/surface
    /// off the ambient context when not supplied. Skips entirely when no turn
    /// is bound (the common non-turn caller).
    public nonisolated static func fireFromContext(
        kind: String,
        sessionId: String? = LLMCallContext.sessionId,
        surface: String? = LLMCallContext.surface,
        payload: JSONValue = .object([:]),
        on bus: TurnTraceBus? = nil
    ) {
        guard let turnId = TurnTraceContext.turnId else { return }
        let event = TurnTraceEvent(
            turnId: turnId,
            kind: kind,
            sessionId: sessionId,
            surface: surface,
            payload: payload
        )
        fire(event, on: bus ?? TurnTraceContext.bus ?? .shared)
    }

    /// Actor-isolated delivery: mirror to every live subscriber (drop-on-full,
    /// counted) and enqueue onto the persist lane. Subscribers are served
    /// synchronously within the actor but the per-subscriber yield is itself
    /// non-blocking (AsyncStream.yield never suspends).
    public func deliver(_ event: TurnTraceEvent) {
        deliverToSubscribers(event)
        // The per-bus writer owns disk ordering and backpressure. Enqueue is a
        // short lock operation; no disk await occurs on this actor or on the
        // process-wide ingress worker.
        persistPump.submit(event)
    }

    /// A terminal must reach disk before its restart checkpoint can be removed.
    public func deliverDurably(_ event: TurnTraceEvent) async throws {
        let wrote = try await persistPump.lane.appendGuarded(event, shouldAppend: { current in
            guard event.kind == "turn.terminal", case .object(let payload) = event.payload,
                  case .string(let status)? = payload["status"] else { return true }
            // This terminal is known by its live owner. Damage elsewhere in
            // the feed cannot prevent its append or invalidate an exact duplicate.
            return !TurnTraceReplayReader.containsTerminal(forTurn: event.turnId, in: current.events, status: status)
        })
        if wrote { deliverToSubscribers(event) }
    }

    /// Live delivery without persistence. Reconciliation uses this after its
    /// guarded append so the event is not written twice.
    func deliverToSubscribers(_ event: TurnTraceEvent) {
        for (id, var sink) in sinks {
            // `.bufferingNewest(cap)` means yield NEVER blocks; on overflow it
            // drops the OLDEST buffered value and reports `.dropped`.
            let r = sink.continuation.yield(event)
            switch r {
            case .enqueued:
                break
            case .dropped:
                sink.drops += 1
                sink.dropContinuation.yield(sink.drops)
            case .terminated:
                sink.continuation.finish()
            @unknown default:
                break
            }
            sinks[id] = sink
        }
    }
}

// MARK: - TurnTracePersistLane (per-day capped JSONL)

/// Appends every emitted event to `<dataRoot>/data/turn_traces/<yyyy-MM-dd>.jsonl`
/// via the shared `appendJSONLCapped` helper (newest-20k cap, flock
/// discipline) — a 1:1 mirror of the emitMemoryCommitTrace pattern. Per-DAY
/// files keep any one file bounded and make the W3 replay lane a simple
/// date-keyed read.
///
/// Non-fatal: an IO failure logs to stderr and never propagates — a lost trace
/// row is acceptable; a turn that fails because telemetry couldn't write is not.
public struct TurnTracePersistLane: Sendable {
    // gpt-5.5 W1 review should-fix: per-DAY files with a 5000 cap could evict
    // a morning turn's events by evening (one turn emits dozens of rows),
    // making W3 replay lossy. 20k rows ≈ hundreds of turns per day — bounded
    // file size, replay-survivable. Revisit per-turn files in W3 if replay
    // needs hard guarantees.
    static let maxLines = 20_000
    static let maxBytes = JSONLLineCaps.turnTraceMaximumBytes
    static let trimToBytes = JSONLLineCaps.turnTraceTrimTargetBytes

    /// Reads and writes resolve the same root: environment, instance, default.
    public func resolvedDataRoot() -> URL {
        if let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_TURN_TRACE_ROOT"], !raw.isEmpty {
            // Preserve literal paths, including an unexpanded tilde.
            var components = URLComponents()
            components.scheme = "file"
            components.path = raw
            return components.url ?? URL(fileURLWithPath: raw)
        }
        return dataRootOverride ?? defaultDataRoot()
    }

    let dataRootOverride: URL?
    private let persistence = SwiftNativePersistenceCore()

    public init(dataRootOverride: URL? = nil) {
        self.dataRootOverride = dataRootOverride
    }

    /// `<dataRoot>/turn_traces/<yyyy-MM-dd>.jsonl`. NOTE: `defaultDataRoot()`
    /// already returns the `.../data` directory (it resolves to the data root,
    /// not the repo root — see PersistenceCore.defaultDataRoot), so the file
    /// lands at `data/turn_traces/<date>.jsonl` as the brief specifies.
    public func path(for date: Date) -> URL {
        Self.fileURL(for: date, root: resolvedDataRoot())
    }

    static func fileURL(for date: Date, root: URL) -> URL {
        return root
            .appendingPathComponent("turn_traces", isDirectory: true)
            .appendingPathComponent("\(Self.dayString(from: date)).jsonl")
    }

    /// Doctor button path for a damaged day file. The persisted trace owner
    /// preserves every original byte before keeping only decodable event rows.
    /// A wholly unreadable file is left for human recovery.
    public func salvageValidRows(for date: Date) async throws -> Int? {
        let target = path(for: date)
        return try await persistence.withFileLock(target) {
            guard let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 16 * 1024 * 1024 else { return nil }
            let source = try FileHandle(forReadingFrom: target)
            defer { try? source.close() }
            let temporary = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent).doctor-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var line = Data()
            var oversizedLine = false
            var retained = 0
            var removed = 0
            func finishLine() throws {
                defer { line.removeAll(keepingCapacity: true); oversizedLine = false }
                guard !line.isEmpty || oversizedLine else { return }
                if !oversizedLine, let row = try? JSONValue.parse(line),
                   TurnTraceEvent(persistedJSONRow: row, physicalByteCount: line.count + 1) != nil {
                    try output.write(contentsOf: line)
                    try output.write(contentsOf: Data([10]))
                    retained += 1
                } else { removed += 1 }
            }
            while let chunk = try source.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let pieces = chunk.split(separator: 10, omittingEmptySubsequences: false)
                for (index, piece) in pieces.enumerated() {
                    if !oversizedLine {
                        if line.count + piece.count <= 16 * 1024 * 1024 { line.append(contentsOf: piece) }
                        else { line.removeAll(); oversizedLine = true }
                    }
                    if index < pieces.count - 1 { try finishLine() }
                }
            }
            try finishLine()
            guard removed > 0, retained > 0 else { return nil }
            let backup = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent).doctor-preserved-\(UUID().uuidString).bak")
            try output.close()
            try FileManager.default.copyItem(at: target, to: backup)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            return removed
        }
    }

    /// Append one event row (capped + flock'd). Best-effort.
    public func append(_ event: TurnTraceEvent) async {
        let target = path(for: event.ts)
        // Ensure the directory exists — appendJSONLCapped writes the file but
        // not its parent dir.
        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try await appendJSONLCapped(
                event.jsonRow,
                to: target,
                using: persistence,
                maxLines: Self.maxLines,
                logLabel: "TurnTracePersistLane",
                // H3: this append runs on the chat turn path under the feed's
                // flock. Without a byte trigger the cap re-read the whole
                // day-file (up to ~18MB at the 20k-line cap) for every traced
                // row. Below the trigger the line count is never taken.
                trimWhenBytesExceed: JSONLLineCaps.turnTraceTrimTriggerBytes,
                maxBytes: Self.maxBytes,
                trimToBytes: Self.trimToBytes,
                // 2026-09-22: the byte ceiling is checked every append; the full
                // re-read for the line cap only needs to run rarely.
                capCheckStride: 4096,
                // A TERMINAL ROW IS A RECORD, not telemetry: `.turnTraceTerminalPersisted`
                // is posted below and the Doctor's one-shot refresh fires on it, so the
                // row has to be on the platter before the signal goes out (GPT-5.6 round
                // review, 2026-09-11). Non-terminal trace rows stay non-durable.
                durable: TurnTraceEvent.isTerminalKind(event.kind)
            )
            postTerminalIfNeeded(event, trace: target)
        } catch {
            FileHandle.standardError.write(
                Data("TurnTracePersistLane: append failed (turn \(event.turnId)): \(error)\n".utf8)
            )
        }
    }

    /// DURABLE TURN-TERMINAL SIGNAL. `.chatTurnCompleted` is an overloaded UI
    /// refresh notification — transcript compaction posts it with no turn
    /// behind it — so anything that needs "a turn actually finished" observes
    /// this instead: it is posted only after the terminal row is on disk
    /// (GPT-5.6 round review, 2026-09-11).
    ///
    /// The abandoned-turn reconciler's synthetic row is NOT a turn that just
    /// finished, so it does not post. Her parts that wake on `turn.ended` get
    /// this edge, with where its rows are and the part whose run started it.
    private func postTerminalIfNeeded(_ event: TurnTraceEvent, trace: URL) {
        guard TurnTraceEvent.isTerminalKind(event.kind) else { return }
        if case .object(let payload) = event.payload,
           case .string("terminal_reconciliation")? = payload["observedBy"] {
            return
        }
        var info: [String: Any] = ["turnId": event.turnId, "kind": event.kind, "trace": trace.path]
        info["sessionId"] = event.sessionId
        info["surface"] = event.surface
        if case .object(let fields) = event.payload {
            if case .string(let part)? = fields["part"] { info["part"] = part }
            if case .string(let steer)? = fields["steered_by"] { info["agent"] = steer }
        }
        NotificationCenter.default.post(name: .turnTraceTerminalPersisted, object: nil, userInfo: info)
    }

    /// Append one row under the day file's OWN write lock, after re-reading
    /// that file inside the critical section so the caller can decline on rows
    /// that landed since its unlocked scan.
    ///
    /// GPT-5.6 round review (2026-09-11): the abandoned-turn reconciler decided
    /// "no terminal exists" from an unlocked read and appended later, so a real
    /// terminal landing in between was overwritten by an "abandoned" verdict.
    /// Check and append have to sit in one critical section, and this lane owns
    /// the lock that every `turn.terminal` row is written under.
    ///
    /// `shouldAppend` receives the target file's decoded rows and coverage report
    /// (empty and clean when absent). Malformed rows stay in the report, including
    /// invalid UTF-8; they do not make readable siblings unavailable. Returns false
    /// only when the predicate confirms no append is needed; read, predicate and
    /// persistence failures throw.
    ///
    /// `alsoLocking` extends the critical section over further files the
    /// predicate reads (the reconciler's sibling day files). Every lock in the
    /// section is taken in one fixed order — sorted by path — so two callers
    /// with overlapping sets can never deadlock against each other.
    @discardableResult
    public func appendGuarded(
        _ event: TurnTraceEvent,
        alsoLocking siblings: [URL] = [],
        shouldAppend: @escaping @Sendable (TurnTraceReplayReader.ReadResult) throws -> Bool
    ) async throws -> Bool {
        let target = path(for: event.ts)
        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // ONE GLOBAL ORDER, target included — not "target first" — so two
        // sweeps whose day sets overlap in opposite directions cannot deadlock.
        let lockOrder = Set(siblings.map(\.path))
            .union([target.path])
            .sorted()
            .map { URL(fileURLWithPath: $0) }
        return try await withFileLocks(lockOrder) {
            let existing: TurnTraceReplayReader.ReadResult = FileManager.default.fileExists(atPath: target.path)
                ? try TurnTraceReplayReader.parse(Data(contentsOf: target)) : ([], .clean)
            guard try shouldAppend(existing) else { return false }
            try await appendJSONLCapped(
                event.jsonRow,
                to: target,
                using: persistence,
                maxLines: Self.maxLines,
                logLabel: "TurnTracePersistLane",
                // The lock is already held by this call — nesting the same
                // non-recursive flock on the same path would deadlock.
                takeLock: false,
                trimWhenBytesExceed: JSONLLineCaps.turnTraceTrimTriggerBytes,
                maxBytes: Self.maxBytes,
                trimToBytes: Self.trimToBytes,
                capCheckStride: 4096,
                durable: true
            )
            postTerminalIfNeeded(event, trace: target)
            return true
        }
    }

    /// Take every lock in `paths` (already in the caller's fixed order) and run
    /// `body` inside all of them.
    private func withFileLocks(
        _ paths: [URL],
        _ body: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        guard let first = paths.first else { return try await body() }
        return try await persistence.withFileLock(first) {
            try await withFileLocks(Array(paths.dropFirst()), body)
        }
    }

    /// Every lane and the sweep share one day formatter, from many tasks at
    /// once, so it is only used under `dayLock`.
    private static let dayLock = NSLock()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(from date: Date) -> String {
        dayLock.withLock { dayFormatter.string(from: date) }
    }

    package static func day(from string: String) -> Date? {
        dayLock.withLock { dayFormatter.date(from: string) }
    }

    static var dayTimeZone: TimeZone {
        dayLock.withLock { dayFormatter.timeZone }
    }
}

// MARK: - Bounded recent turn-trace reader

/// Reads the same per-day ledger resolved by `TurnTracePersistLane`. Keeping
/// path resolution here prevents diagnostics from drifting back to the legacy
/// aggregate trace ledger or bypassing writer root overrides.
public struct TurnTraceRecentReader: Sendable {
    public static let maxRows = 2_000
    public static let maxBytes = 8 * 1_024 * 1_024

    public struct Snapshot: Sendable {
        public let sourceURL: URL
        public let events: [TurnTraceEvent]
        public let sourceURLs: [URL]
        public let truncated: Bool
        public let oldestRetainedDay: Date?
        public let malformedRows: Int
        public let trailingPartialLine: Bool

        public init(sourceURL: URL, events: [TurnTraceEvent], sourceURLs: [URL] = [], truncated: Bool = false, oldestRetainedDay: Date? = nil, malformedRows: Int = 0, trailingPartialLine: Bool = false) {
            self.sourceURL = sourceURL
            self.events = events
            self.sourceURLs = sourceURLs.isEmpty ? [sourceURL] : sourceURLs
            self.truncated = truncated
            self.oldestRetainedDay = oldestRetainedDay
            self.malformedRows = malformedRows
            self.trailingPartialLine = trailingPartialLine
        }
    }

    private let lane: TurnTracePersistLane
    private let persistence = SwiftNativePersistenceCore()
    private let rowLimit: Int

    /// `rowLimit` widens the tail for a reader that must find one session's
    /// latest turn: on a busy day 2,000 rows can end before it.
    public init(dataRootOverride: URL? = nil, rowLimit: Int = TurnTraceRecentReader.maxRows) {
        self.lane = TurnTracePersistLane(dataRootOverride: dataRootOverride)
        self.rowLimit = rowLimit
    }

    /// Unwindowed history shares a tail budget; since reads the complete retained window.
    /// With `holding`, framing is checked before selecting a kind or turn id.
    public func read(now: Date = Date(), history: Bool = false, since: Date? = nil, holding marks: [String] = [], trace: String? = nil, maximumReadBytes: Int = TurnTraceRecentReader.maxBytes) async throws -> Snapshot {
        let sourceURL = lane.path(for: now)
        let paths: [URL]
        var oldestRetainedDay: Date?
        if let trace {
            let filename = String(trace.dropFirst("turn_traces/".count))
            guard trace == "turn_traces/" + filename, filename.hasSuffix(".jsonl"),
                  let day = TurnTracePersistLane.day(from: String(filename.dropLast(6))),
                  filename == TurnTracePersistLane.dayString(from: day) + ".jsonl" else {
                throw PersistenceCoreError.ioFailure("trace must name turn_traces/<yyyy-MM-dd>.jsonl.")
            }
            paths = [sourceURL.deletingLastPathComponent().appendingPathComponent(filename)]
        } else if let since {
            let directory = sourceURL.deletingLastPathComponent()
            let entries = FileManager.default.fileExists(atPath: directory.path)
                ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []
            let days = entries.compactMap { path -> (URL, Date)? in
                guard path.pathExtension == "jsonl",
                      let day = TurnTracePersistLane.day(from: path.deletingPathExtension().lastPathComponent), day <= now else { return nil }
                return (path, day)
            }
            oldestRetainedDay = days.map(\.1).min()
            paths = days.filter { $0.1 >= Calendar.current.startOfDay(for: since) }
                .map(\.0).sorted { $0.lastPathComponent > $1.lastPathComponent }
        } else {
            paths = (0..<(history ? TurnTraceRetention.defaultKeepDays : 1)).compactMap {
                Calendar.current.date(byAdding: .day, value: -$0, to: now).map { lane.path(for: $0) }
            }
        }
        var events: [TurnTraceEvent] = []
        var sources: [URL] = []
        var remainingRows = rowLimit
        var remainingBytes = maximumReadBytes
        var truncated = false
        var malformedRows = 0
        var trailingPartialLine = false
        for path in paths {
            guard trace != nil || since != nil || (remainingRows > 0 && remainingBytes > 0) else { truncated = true; break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                if trace != nil { truncated = true }
                continue
            }
            if isDirectory.boolValue {
                throw PersistenceCoreError.ioFailure("turn trace path is a directory: \(path.path)")
            }
            if since != nil || trace != nil {
                sources.append(path)
                let receipt = try await TurnTraceReplayReader.read(path)
                malformedRows += receipt.report.malformedLineCount
                trailingPartialLine = trailingPartialLine || receipt.report.trailingPartialLine
                if !receipt.report.isClean { truncated = true }
                for event in receipt.events {
                    guard marks.isEmpty || marks.contains(event.kind) || marks.contains(event.turnId) else { continue }
                    guard since.map({ event.ts >= $0 }) ?? true, event.ts <= now else { continue }
                    events.append(event)
                }
                continue
            }
            let receipt = try await TurnTraceReplayReader.tail(path, limit: remainingRows, maxBytes: remainingBytes)
            sources.append(path)
            malformedRows += receipt.report.malformedLineCount
            events += receipt.events
            remainingRows -= receipt.report.physicalLineCount
            remainingBytes -= receipt.bytesRead
            truncated = truncated || receipt.truncated || remainingRows <= 0
        }
        return Snapshot(sourceURL: sourceURL, events: events, sourceURLs: sources, truncated: truncated, oldestRetainedDay: oldestRetainedDay, malformedRows: malformedRows, trailingPartialLine: trailingPartialLine)
    }

    /// Turn evidence has one durable owner. Historical ledger rows are removed
    /// only when matched to a retained event, preserving any older outcome.
    public func traceEvidence(
        now: Date = Date(), since: Date? = nil,
        maximumReadBytes: Int = TurnTraceRecentReader.maxBytes
    ) async throws -> (rows: [JSONValue], report: JSONLReadReport, turns: Snapshot, sourceAbsent: Bool) {
        let turns = try await read(now: now, history: true, since: since,
                                   holding: since == nil ? [] : ["llm.call", "provider.noReply", "tool.dispatch", "turn.plan", "turn.terminal"],
                                   maximumReadBytes: maximumReadBytes)
        let path = lane.resolvedDataRoot().appendingPathComponent("traces/events.jsonl")
        let ledger: (rows: [JSONValue], report: JSONLReadReport)
        if since != nil {
            ledger = try await persistence.readJSONLReporting(path)
        } else {
            let tail = try await persistence.tailJSONLReadReceipt(path, limit: rowLimit, maxBytes: maximumReadBytes)
            ledger = (tail.rows, JSONLReadReport(malformedLineCount: tail.malformedJSONRowCount))
        }
        func matchKey(kind: String, payload: [String: JSONValue], date: Date) throws -> Data? {
            let identity: [JSONValue]
            switch kind {
            case "tool.dispatch":
                guard case .object(let receipt)? = payload["receipt"],
                      case .string(let id)? = receipt["id"] else { return nil }
                identity = [.string(id)]
            case "turn.plan":
                guard case .string(let id)? = payload["runId"] else { return nil }
                identity = [.string(id)]
            case "llm.call", "provider.noReply":
                guard case .string(let turn)? = payload["turnId"], !turn.isEmpty, turn != "unknown" else { return nil }
                // Historical calls have no shared id; match their recorded second
                // and measurements, consuming each ledger row at most once.
                let fields = kind == "llm.call"
                    ? ["provider", "model", "surface", "purpose", "streaming", "durationMs", "ttftMs", "inputTokens", "outputTokens"]
                    : ["provider", "surface", "seconds", "events"]
                identity = [.string(turn), .int(Int64(date.timeIntervalSince1970.rounded(.down)))]
                    + fields.map { payload[$0] ?? .null }
            default: return nil
            }
            return try JSONValue.array([.string(kind)] + identity).serializedData(pretty: false)
        }
        var matches: [Data: [Int]] = [:]
        for (index, row) in ledger.rows.enumerated().reversed() {
            guard case .object(let object) = row, case .string(let kind)? = object["kind"],
                  case .object(let payload)? = object["payload"],
                  case .string(let raw)? = object["createdAt"], let date = TurnTraceEvent.parseISO8601(raw),
                  let key = try matchKey(kind: kind, payload: payload, date: date) else { continue }
            matches[key, default: []].append(index)
        }
        var matched: Set<Int> = []
        var rows: [JSONValue] = []
        for event in turns.events {
            guard ["llm.call", "provider.noReply", "tool.dispatch", "turn.plan"].contains(event.kind),
                  case .object(var payload) = event.payload else { continue }
            if event.kind == "tool.dispatch", payload["phase"] != .string("end") { continue }
            payload["turnId"] = .string(event.turnId)
            if let key = try matchKey(kind: event.kind, payload: payload, date: event.ts),
               let index = matches[key]?.popLast(), case .object(let legacy) = ledger.rows[index] {
                matched.insert(index)
                if case .object(let older)? = legacy["payload"] { payload = older.merging(payload) { _, current in current } }
                if payload["status"] == nil { payload["status"] = legacy["status"] }
            }
            let title: String
            if event.kind == "turn.plan", case .string(let goal)? = payload["goalType"],
               case .string(let mode)? = payload["contextMode"] { title = "\(goal) -> \(mode)" }
            else if case .string(let value)? = payload[event.kind == "tool.dispatch" ? "name" : event.kind == "llm.call" ? "model" : "provider"] { title = value }
            else { title = event.kind }
            let id: String
            if event.kind == "tool.dispatch", case .object(let receipt)? = payload["receipt"],
               case .string(let receiptID)? = receipt["id"] { id = receiptID }
            else {
                id = SHA256.hash(data: try event.jsonRow.serializedData(pretty: false))
                    .map { String(format: "%02x", $0) }.joined()
            }
            rows.append(.object([
                "id": .string(id), "kind": .string(event.kind), "title": .string(title),
                "status": payload["status"] ?? .string(event.kind == "provider.noReply" ? "failed" : event.kind == "llm.call" ? "unknown" : "ok"),
                "createdAt": .string(event.ts.formatted(TurnTraceEvent.fractionalISO8601)),
                "payload": .object(payload),
            ]))
        }
        rows += ledger.rows.enumerated().compactMap { matched.contains($0.offset) ? nil : $0.element }
        var report = ledger.report
        report.malformedLineCount += turns.malformedRows
        report.trailingPartialLine = report.trailingPartialLine || turns.trailingPartialLine
        var dated: [(row: JSONValue, date: Date, index: Int)] = []
        for (index, row) in rows.enumerated() {
            var date = Date.distantPast
            if case .object(let object) = row, case .string(let raw)? = object["createdAt"],
               let parsed = TurnTraceEvent.parseISO8601(raw) { date = parsed }
            dated.append((row, date, index))
        }
        dated.sort { $0.date == $1.date ? $0.index < $1.index : $0.date < $1.date }
        rows = dated.map(\.row)
        return (rows, report, turns,
                turns.sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
                    && !FileManager.default.fileExists(atPath: path.path))
    }

    public func modelCalls(now: Date = Date()) async throws -> JSONValue {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let evidence = try await traceEvidence(now: now, since: weekAgo)
        var calls: [(Date, String, String, Int64?)] = []
        var oldest: Date?
        for row in evidence.rows {
            guard case .object(let object) = row,
                  case .string(let rawDate)? = object["createdAt"],
                  let date = TurnTraceEvent.parseISO8601(rawDate) else {
                throw PersistenceCoreError.ioFailure("Model calls: a trace row has no readable createdAt; inspect the retained trace sources.")
            }
            oldest = min(oldest ?? date, date)
            guard object["kind"] == .string("llm.call"), date <= now,
                  date >= now.addingTimeInterval(-7 * 86_400) else { continue }
            guard case .object(let payload)? = object["payload"] else {
                throw PersistenceCoreError.ioFailure("Model calls: a call has no payload; inspect the retained trace sources.")
            }
            let purpose = if case .string(let value)? = payload["purpose"] { value } else { "other" }
            let turn = if case .string(let value)? = payload["turnId"], !value.isEmpty { value } else { "unknown" }
            let duration: Int64? = if case .int(let value)? = payload["durationMs"], value >= 0 { value } else { nil }
            calls.append((date, purpose, turn, duration))
        }
        let week = evidence.turns
        let rounds = Self.rounds(week.events)
        let windows: [JSONValue] = [("24h", 86_400.0), ("7d", 7 * 86_400.0)].map { label, seconds in
            let since = now.addingTimeInterval(-seconds)
            let finished = rounds.filter { $0.at >= since }.map(\.rounds)
            var turns: [String: [String: Int64]] = [:]
            var totals: [String: Int64] = [:]
            var durations: [String: Int64] = [:]
            var missingDuration: Int64 = 0
            for (date, purpose, turn, duration) in calls where date >= since {
                turns[turn, default: [:]][purpose, default: 0] += 1
                totals[purpose, default: 0] += 1
                if let duration { durations[purpose, default: 0] += duration }
                else { missingDuration += 1 }
            }
            return .object([
                "window": .string(label), "since": .string(since.formatted(.iso8601)),
                "counts_by_purpose": .object(totals.mapValues(JSONValue.int)),
                "per_turn": .array(turns.keys.sorted().map {
                    .object(["turn_id": .string($0), "counts_by_purpose": .object(turns[$0]!.mapValues(JSONValue.int))])
                }),
                "top_five_by_total_ms": .array(durations.keys.sorted {
                    durations[$0] == durations[$1] ? $0 < $1 : durations[$0]! > durations[$1]!
                }.prefix(5).map { .object(["purpose": .string($0), "total_ms": .int(durations[$0]!)]) }),
                "missing_duration_calls": .int(missingDuration),
                "predates_retained_rows": .bool(oldest.map { since < $0 } ?? true),
                "rounds_per_turn": .object(["turns": .int(Int64(finished.count)),
                    "p50": Self.percentile(finished, 0.5).map { .int(Int64($0)) } ?? .null,
                    "p90": Self.percentile(finished, 0.9).map { .int(Int64($0)) } ?? .null]),
            ])
        }
        // The week's five heaviest asks and the first six calls each made: her
        // own, refusals included; a call run inside another names its parent.
        let top = rounds.sorted { $0.rounds > $1.rounds }.prefix(5)
        let asks = top.isEmpty ? [] : try await read(now: now, since: weekAgo, holding: top.map(\.turn)).events
        let heaviest: [JSONValue] = top.map { turn in
            var ask = "", made: [String] = []
            for event in asks where event.turnId == turn.turn {
                guard case .object(let payload) = event.payload else { continue }
                if event.kind == "work.identified", case .string(let title)? = payload["title"] { ask = String(title.prefix(80)) }
                guard event.kind == "tool.dispatch", payload["phase"] == .string("end"), payload["parentId"] == nil else { continue }
                made.append(Self.callLabel(payload) + (payload["status"] == .string("failed") ? "!" : ""))
            }
            return .object(["turn_id": .string(turn.turn), "at": .string(turn.at.formatted(.iso8601)),
                            "rounds": .int(Int64(turn.rounds)), "ask": .string(ask),
                            "first_six": .array(made.prefix(6).map(JSONValue.string))])
        }
        return .object([
            "status": .string(evidence.report.malformedLineCount == 0 && !evidence.report.trailingPartialLine && !week.truncated ? "ok" : "incomplete"),
            "title": .string("Model calls"), "until": .string(now.formatted(.iso8601)),
            "measurement": .string("Recorded llm.call rows in turn_traces and standalone calls in traces/events.jsonl, including recorded failures. Unbound calls use turn_id unknown; unlabelled older calls use purpose other. Windows may exceed retained rows. Missing durations are not estimated. rounds_per_turn is each finished turn's model rounds (its first call and one per tool round, from its turn.terminal row in the per-day turn traces), nearest-rank p50/p90; heaviest_asks are the week's five turns with the most rounds, ! marking a call that failed."),
            "malformed_rows": .int(Int64(evidence.report.malformedLineCount)),
            "trailing_partial_line": .bool(evidence.report.trailingPartialLine),
            "windows": .array(windows),
            "heaviest_asks": .array(heaviest),
            "turn_traces_incomplete": .bool(week.truncated),
        ])
    }

    /// Each finished turn's model rounds: its first call and one per tool
    /// round, as its terminal row counts them.
    public static func rounds(_ events: [TurnTraceEvent]) -> [(turn: String, at: Date, rounds: Int)] {
        events.compactMap { event in
            guard event.kind == "turn.terminal", case .object(let payload) = event.payload,
                  case .int(let rounds)? = payload["providerRoundCount"] else { return nil }
            return (event.turnId, event.ts, Int(rounds))
        }
    }

    /// Nearest-rank percentile; nil with nothing to rank.
    public static func percentile(_ values: [Int], _ p: Double) -> Int? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : sorted[max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
    }

    /// An app call as heaviest_asks names it: its action, or what it read.
    static func callLabel(_ payload: [String: JSONValue]) -> String {
        if case .object(let receipt)? = payload["receipt"], case .string(let action)? = receipt["action"], action != "app" { return action }
        let args: [String: JSONValue] = if case .string(let raw)? = payload["args"],
            case .object(let args)? = try? JSONValue.parse(Data(raw.utf8)) { args } else { [:] }
        // A long script's args are clipped past parsing; its key names still say what it was.
        let keys: [JSONValue] = if case .array(let names)? = payload["argKeys"] { names } else { args.keys.map(JSONValue.string) }
        let blank: [JSONValue] = [.null, .string(""), .array([])]
        guard let key = ["actions", "script", "find", "page", "item"].first(where: {
            keys.contains(.string($0)) && !blank.contains(args[$0] ?? .bool(true))
        }) else { return "home" }
        switch args[key] {
        case .array(let list)?: return "\(key)[\(list.count)]"
        case .string(let text)? where ["page", "item"].contains(key): return key + " " + text
        default: return key
        }
    }

    public func usage(since: Date, now: Date = Date(), by: String = "model") async throws -> JSONValue {
        let snapshot = try await read(now: now, since: since)
        let metrics = ["inputTokens", "cacheReadInputTokens", "outputTokens", "durationMs"]
        let zero = Dictionary(uniqueKeysWithValues: (["calls"] + metrics).map { ($0, Int64(0)) })
        var totals = zero
        var groups: [String: [String: Int64]] = [:]
        var missing: [String: [String: Int64]] = [:]
        var totalMissing: [String: Int64] = [:]
        for event in snapshot.events where event.kind == "llm.call" {
            guard case .object(let payload) = event.payload else { continue }
            let key: String
            if by == "day" { key = TurnTracePersistLane.dayString(from: event.ts) }
            else if case .string(let value)? = payload[by], !value.isEmpty { key = value }
            else { key = "unknown" }
            groups[key, default: zero]["calls", default: 0] += 1
            totals["calls", default: 0] += 1
            for metric in metrics {
                guard case .int(let value)? = payload[metric], value >= 0 else {
                    missing[key, default: [:]][metric, default: 0] += 1
                    totalMissing[metric, default: 0] += 1
                    continue
                }
                groups[key, default: zero][metric, default: 0] += value
                totals[metric, default: 0] += value
            }
        }
        func counts(_ values: [String: Int64], missing: [String: Int64]) -> [String: JSONValue] {
            var row = values.mapValues(JSONValue.int)
            row["missing_fields"] = .object(missing.mapValues(JSONValue.int))
            return row
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        let predatesRetention = snapshot.oldestRetainedDay.map { since < $0 } ?? false
        return .object([
            "status": .string("ok"), "by": .string(by),
            "since": .string(formatter.string(from: since)), "until": .string(formatter.string(from: now)),
            "covered_since": snapshot.oldestRetainedDay.map { .string(formatter.string(from: max(since, $0))) } ?? .null,
            "oldest_retained_day": snapshot.oldestRetainedDay.map { .string(TurnTracePersistLane.dayString(from: $0)) } ?? .null,
            "predates_retention": .bool(predatesRetention),
            "coverage": .string(snapshot.oldestRetainedDay == nil ? "No retained trace day files are available." : predatesRetention
                ? "The requested window predates retained trace files; earlier usage is unavailable."
                : "The requested window is within retained trace day files."),
            "measurement": .string("Exact sums of recorded llm.call values in retained rows. missing_fields counts calls without a nonnegative integer measurement; those values are not estimated. Input and cached input are separate recorded counters. Daily trace files also have row and size retention limits."),
            "totals": .object(counts(totals, missing: totalMissing)),
            "groups": .array(groups.keys.sorted().map { key in
                var row = counts(groups[key]!, missing: missing[key] ?? [:])
                row[by] = .string(key)
                return .object(row)
            }),
        ])
    }
}

extension Notification.Name {
    /// Posted after a turn's TERMINAL row (`turn.terminal` / `turn.cancelled` /
    /// `turn.failed`) has been durably appended to the trace. userInfo carries
    /// `turnId`, `kind`, `trace` (the day file), and `sessionId`, `surface`,
    /// `part` and `agent` (whose words steered it) when known. Unlike `.chatTurnCompleted` this cannot fire
    /// without a turn.
    public static let turnTraceTerminalPersisted =
        Notification.Name("turnTraceTerminalPersisted")
}
