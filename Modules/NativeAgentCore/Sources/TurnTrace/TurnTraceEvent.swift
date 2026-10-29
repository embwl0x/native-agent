import AuthoredCapabilities
import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TurnTraceEvent.swift` | Canonical event schema, terminal kind/status vocabulary, envelope and payload bounds; model-call receipts retain the shared ledger byte budget |

/// A turn event delivered by TurnTraceBus.deliver or deliverDurably.
/// Callers must pre-redact payloads: no raw prompt/completion bodies or bot tokens.
public struct TurnTraceEvent: Sendable, Equatable {
    public enum TerminalState: String, Sendable, Codable {
        case completed, stopped, interrupted, waiting, failed
    }
    /// Per-string payload cap, except for model-call receipts.
    public static let maxPayloadStringChars = 2000
    /// Serialized row ceiling includes the envelope. Model-call receipts use
    /// traceMaximumBytes to preserve cache-prefix evidence.
    public static let maxPayloadBytes = 12 * 1024
    // Keep hostile envelope metadata from consuming the space reserved for
    // the frozen context.snapshot scalar manifest.
    private static let maxEnvelopeFieldUTF8Bytes = 480
    private static let maxEnvelopeFieldJSONBytes = 512
    private static let oversizedPreviewBytes = 6 * 1024

    /// Whose words steered the turn in flight, when they are not the owner's.
    /// Installed by the engine over the turn's own taint.
    public static var steer: @Sendable () -> String? {
        get { steerHook.withLock { $0 } }
        set { steerHook.withLock { $0 = newValue } }
    }
    private static let steerHook = OSAllocatedUnfairLock<@Sendable () -> String?>(initialState: { nil })

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
    /// Callers redact content; turn payloads are bounded, standalone receipts
    /// retain their content under the shared feed's retention budget.
    public let payload: JSONValue
    internal var diagnostic: [String: JSONValue] = [:]

    /// Standalone receipts keep their envelope; bound turns store receipt metadata
    /// beside their canonical event.
    public init(
        kind: String, title: String, status: String, payload: JSONValue,
        id: String = UUID().uuidString.lowercased(), createdAt: String, ts: Date = Date(),
        turnId: String? = nil, sessionId: String? = LLMCallContext.sessionId,
        surface: String? = LLMCallContext.surface
    ) {
        if let turnId, turnId != "unknown" {
            self.init(turnId: turnId, ts: ts, kind: kind, sessionId: sessionId, surface: surface, payload: payload)
        } else {
            self.init(canonicalTurnId: "unknown", ts: ts, canonicalKind: kind,
                canonicalSessionId: sessionId, canonicalSurface: surface,
                canonicalDestinationId: nil, canonicalThreadId: nil, boundedPayload: payload)
        }
        diagnostic = ["id": .string(id), "title": .string(title),
                      "status": .string(status), "createdAt": .string(createdAt)]
    }

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
    /// Model-call telemetry uses its larger byte budget without the string-leaf cap.
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
        let leafBound = kind == "llm.call" ? value : value.mapStrings(boundString)
        guard (try? JSONValue.object(ordinaryEnvelope(
                payload: leafBound,
                turnId: turnId,
                ts: ts,
                kind: kind,
                sessionId: sessionId,
                surface: surface,
                destinationId: destinationId,
                threadId: threadId
              )).serializedData(pretty: false).count + 1).map({ $0 > byteLimit }) == true,
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
                "argKeys", "shown", "receipt", "parentId", "automaticOrigin", "cacheMarkers",
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
                // Preserve the composer's component measurements and bounded
                // memoryRecall object when snapshot previews are summarized.
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
            let rowBytes = (try? JSONValue.object(ordinaryEnvelope(
                payload: bounded,
                turnId: turnId,
                ts: ts,
                kind: kind,
                sessionId: sessionId,
                surface: surface,
                destinationId: destinationId,
                threadId: threadId
            )).serializedData(pretty: false).count + 1) ?? Int.max
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
            if (try? JSONValue.object(ordinaryEnvelope(
                payload: candidate,
                turnId: turnId,
                ts: ts,
                kind: kind,
                sessionId: sessionId,
                surface: surface,
                destinationId: destinationId,
                threadId: threadId
            )).serializedData(pretty: false).count + 1).map({ $0 <= byteLimit }) == true {
                return candidate
            }
            summary.removeValue(forKey: key)
        }
        // With four envelope fields capped at 512 serialized bytes, the fixed
        // scalar manifest plus integrity fields has a reserved budget well
        // below 12 KiB. Return it intact; never fall back to integrity-only.
        return .object(summary)
    }

    private static func ordinaryEnvelope(
        payload: JSONValue,
        turnId: String,
        ts: Date,
        kind: String,
        sessionId: String?,
        surface: String?,
        destinationId: String? = nil,
        threadId: String? = nil
    ) -> [String: JSONValue] {
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
        return row
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

    /// Decode and re-bound a persisted row through the construction path.
    /// Malformed fields or timestamps return nil; replay reports skipped rows.
    public init?(jsonRow value: JSONValue) {
        self.init(persistedJSONRow: value, physicalByteCount: 0)
    }

    /// Decode a physical persisted row without repeating the expensive payload
    /// serialization proof that the writer already completed. The fast path is
    /// admitted only when the physical row is within the canonical byte cap,
    /// every envelope field is already canonical, and no payload string leaf
    /// needs clipping. Other rows use the defensive construction path.
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
        if physicalByteCount > 0,
              physicalByteCount <= (kind == "llm.call" ? JSONLLineCaps.traceMaximumBytes : Self.maxPayloadBytes),
              envelopeIsCanonical,
              kind == "llm.call" || !Self.hasOversizedStringLeaf(payload) {
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
        } else {
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
        diagnostic = obj.filter { ["id", "title", "status", "createdAt", "transitionId"].contains($0.key) }
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

    /// Parse fractional or plain ISO8601 seconds from persisted timestamps.
    public static func parseISO8601(_ s: String) -> Date? {
        if let d = try? fractionalISO8601.parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }

    /// Shared Sendable format for row writes and repeated summary reads.
    static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Turn rows use fractional timestamps for chronological replay;
    /// standalone diagnostics preserve their six-field receipt envelope.
    public var jsonRow: JSONValue {
        if turnId == "unknown", !diagnostic.isEmpty {
            return .object(diagnostic.merging(["kind": .string(kind), "payload": payload]) { _, current in current })
        }
        let obj = Self.ordinaryEnvelope(payload: payload, turnId: turnId, ts: ts, kind: kind,
            sessionId: sessionId, surface: surface, destinationId: destinationId, threadId: threadId)
        return .object(obj.merging(diagnostic) { _, receipt in receipt })
    }
}
