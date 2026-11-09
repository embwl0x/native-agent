import AuthoredCapabilities
import Foundation
import os
import CryptoKit
import NativeAgentCore
import PersistenceCore
// Blueprint: | `TurnTraceEvent.swift` | Canonical events; bounded envelopes retain receipt evidence |

/// A turn event delivered by TurnTraceBus.deliver or deliverDurably. Callers must pre-redact payloads: no raw prompt/completion bodies or bot tokens.
public struct TurnTraceEvent: Sendable, Equatable {
    public enum TerminalState: String, Sendable, Codable {
        case completed, stopped, interrupted, waiting, failed
    }
    /// Per-string payload cap, except for model-call receipts and the first-class feeling frame.
    public static let maxPayloadStringChars = 2000
    /// Ordinary row budget includes the envelope; model calls and full feeling frames share the detail owner's larger row ceiling.
    public static let maxPayloadBytes = 12 * 1024
    // Keep hostile envelope metadata from consuming the space reserved for the frozen context.snapshot scalar manifest.
    private static let maxEnvelopeFieldUTF8Bytes = 480
    private static let maxEnvelopeFieldJSONBytes = 512
    private static let oversizedPreviewBytes = 6 * 1024

    /// The engine projects steering from the supplied turn; never from the emitting task.
    public static var steer: @Sendable (Turn) -> String? {
        get { steerHook.withLock { $0 } }
        set { steerHook.withLock { $0 = newValue } }
    }
    private static let steerHook = OSAllocatedUnfairLock<@Sendable (Turn) -> String?>(initialState: { _ in nil })

    public let turnId: String
    public let ts: Date
    public let kind: String
    private static let terminalKinds: Set<String> = ["turn.terminal", "turn.cancelled", "turn.failed"]
    public static func isTerminalKind(_ kind: String) -> Bool { terminalKinds.contains(kind) }
    public let sessionId: String?
    public let surface: String?
    /// Captured from the held turn's envelope, or trace correlation for an emitter without a turn.
    public let destinationId: String?
    public let threadId: String?
    /// Callers redact content; turn payloads are bounded, standalone receipts retain their content under the shared feed's retention budget.
    public let payload: JSONValue
    internal var diagnostic: [String: JSONValue] = [:]

    /// Standalone receipts keep their envelope; bound turns store receipt metadata beside their canonical event.
    /// Supply the turn being served, or explicit nil for a receipt with no held turn.
    public init(
        kind: String, title: String, status: String, payload: JSONValue,
        id: String = UUID().uuidString.lowercased(), createdAt: String, ts: Date = Date(),
        turnId: String? = nil, sessionId: String? = nil,
        surface: String? = nil, turn: Turn?
    ) {
        let turnId = turnId ?? turn?.id
        let sessionId = sessionId ?? turn?.session
        if let turnId, turnId != "unknown" {
            self.init(turnId: turnId, ts: ts, kind: kind, sessionId: sessionId, surface: surface,
                payload: payload, turn: turn)
        } else {
            self.init(canonicalTurnId: "unknown", ts: ts, canonicalKind: kind,
                canonicalSessionId: sessionId, canonicalSurface: surface,
                canonicalDestinationId: nil, canonicalThreadId: nil, boundedPayload: payload)
        }
        diagnostic = ["id": .string(id), "title": .string(title),
                      "status": .string(status), "createdAt": .string(createdAt)]
    }

    /// Live emitters supply their held turn; reconstruction explicitly supplies nil and keeps the recorded payload.
    public init(
        turnId: String,
        ts: Date = Date(),
        kind: String,
        sessionId: String? = nil,
        surface: String? = nil,
        destinationId: String? = TurnTraceContext.destinationId,
        threadId: String? = TurnTraceContext.threadId,
        payload: JSONValue = .object([:]),
        turn: Turn?
    ) {
        let boundedTurnID = Self.boundEnvelopeString(turnId)
        let boundedKind = Self.boundEnvelopeString(kind)
        let boundedSessionID = sessionId.map(Self.boundEnvelopeString)
        let boundedSurface = surface.map(Self.boundEnvelopeString)
        let destination: String?
        let thread: String?
        if let turn {
            let route = turn.traceReplyRoute?(turn)
            destination = route?.destinationId
            thread = route?.threadId
        } else {
            // Explicit recorded fields (including nil) stay recorded; omitted fields capture trace correlation here.
            destination = destinationId
            thread = threadId
        }
        let boundedDestination = destination.map(Self.boundEnvelopeString)
        let boundedThread = thread.map(Self.boundEnvelopeString)
        // A terminal emitter hands over the turn before detached persistence; replaying a saved row adds no current provenance.
        var payload = payload
        if let turn, turn.id == turnId, Self.isTerminalKind(boundedKind), case .object(var fields) = payload {
            if let part = turn.partID { fields["part"] = .string(part) }
            if let steer = Self.steer(turn) { fields["steered_by"] = .string(steer) }
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

    /// Bound previews while retaining lifecycle fields, byte count and digest. Model receipts and the full feeling field keep their own evidence.
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
        let byteLimit = rowByteLimit(kind: kind, payload: value)
        let summaryThreshold = kind == "llm.call" ? byteLimit : maxPayloadBytes
        let leafBound: JSONValue
        if kind == "llm.call" {
            leafBound = value
        } else if kind == "context.snapshot", case .object(let fields) = value {
            var bounded: [String: JSONValue] = [:]
            for (key, field) in fields {
                bounded[key] = key == "feelingFrame" ? field : field.mapStrings(boundString)
            }
            leafBound = .object(bounded)
        } else {
            leafBound = value.mapStrings(boundString)
        }
        guard (try? JSONValue.object(ordinaryEnvelope(
                payload: leafBound,
                turnId: turnId,
                ts: ts,
                kind: kind,
                sessionId: sessionId,
                surface: surface,
                destinationId: destinationId,
                threadId: threadId
              )).serializedData(pretty: false).count + 1).map({ $0 > summaryThreshold }) == true,
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
            if kind == "context.snapshot", let frame = object["feelingFrame"] {
                // The complete paragraph has its own place; preview and cue bounds cannot clip or evict it.
                summary["feelingFrame"] = frame
            }
            // Canonical model-call receipts retain every scalar measurement when larger structured metadata forces preview summarization.
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
                "argKeys", "shown", "receipt", "result_recovery", "parentId", "automaticOrigin", "cacheMarkers",
                // Preserve context scalar integrity facts when large previews are summarized so rows stay queryable despite sorted-key truncation.
                "containsCognitiveSubstrate", "cognitiveCapsuleBytes", "cognitiveCue",
                "toolSchemaCount", "toolSchemaParameterBytes",
                "toolSchemaMaterialBytes", "toolSchemaFingerprintSHA256",
                "promptFingerprintSHA256", "systemTotalBytes",
                "snapshotBoundary", "wireMessageCount",
                "stableBytes", "dynamicBytes", "userMessageBytes",
                "userBlockBytes", "preparationMs",
                "promptTextBytes", "imagePayloadBytes", "segmented",
                // Preserve the composer's component measurements and bounded memoryRecall object when snapshot previews are summarized.
                "historyMessageBytes", "historyMessageCount",
                "volatileBlockBytes", "personaSourceBytes", "memoryRecall",
                "toolCatalogSystemBytes", "toolCatalogBriefBytes", "toolCatalogMeasurementError",
            ]
            for key in stableKeys {
                guard let field = object[key],
                      let bytes = try? field.serializedData(pretty: false),
                      bytes.count <= (["receipt", "toolCatalogMeasurementError"].contains(key) ? 8_192 : 1_024) else { continue }
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

        // Optional lifecycle fields may yield space; the persisted context scalar manifest must survive hostile envelope metadata.
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
        // The ordinary scalar manifest fits its reserved budget; the full feeling field retains its separate place.
        return .object(summary)
    }

    private static func rowByteLimit(kind: String, payload: JSONValue) -> Int {
        if kind == "llm.call" || (kind == "context.snapshot" && payload.objectValue?["feelingFrame"] != nil) {
            return JSONLLineCaps.traceMaximumBytes
        }
        return maxPayloadBytes
    }

    static func ordinaryEnvelope(
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
        // Keep truncation explicit: preserve a prefix and append its marker.
        let prefix = String(s.prefix(cap))
        return prefix + "…[+\(s.count - cap) chars]"
    }

    /// Cap serialized UTF-8 bytes: grapheme counts miss multibyte content and JSON escaping adds further bytes.
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

    /// Decode and re-bound a persisted row through the construction path. Malformed fields or timestamps return nil; replay reports skipped rows.
    public init?(jsonRow value: JSONValue) {
        self.init(persistedJSONRow: value, physicalByteCount: 0)
    }

    /// Reuse the writer's size proof only for physically bounded rows with canonical envelopes and unclipped leaves; otherwise reapply construction.
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
              physicalByteCount <= Self.rowByteLimit(kind: kind, payload: payload),
              envelopeIsCanonical,
              kind == "llm.call" || !Self.hasOversizedStringLeaf(payload, kind: kind) {
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
                payload: payload,
                turn: nil
            )
        }
        diagnostic = obj.filter { ["id", "title", "status", "createdAt", "transitionId"].contains($0.key) }
    }

    private static func hasOversizedStringLeaf(_ value: JSONValue, kind: String? = nil) -> Bool {
        switch value {
        case .string(let string):
            return string.count > maxPayloadStringChars
        case .array(let values):
            return values.contains { hasOversizedStringLeaf($0) }
        case .object(let values):
            return values.contains { key, child in
                !(kind == "context.snapshot" && key == "feelingFrame") && hasOversizedStringLeaf(child)
            }
        case .null, .bool, .int, .double:
            return false
        }
    }

    public static func parseISO8601(_ s: String) -> Date? {
        if let d = try? fractionalISO8601.parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }

    /// Share Sendable timestamp formatting across writes and repeated summary reads.
    static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Turn rows use fractional timestamps for chronological replay; standalone diagnostics preserve their six-field receipt envelope.
    public var jsonRow: JSONValue {
        if turnId == "unknown", !diagnostic.isEmpty {
            return .object(diagnostic.merging(["kind": .string(kind), "payload": payload]) { _, current in current })
        }
        let obj = Self.ordinaryEnvelope(payload: payload, turnId: turnId, ts: ts, kind: kind,
            sessionId: sessionId, surface: surface, destinationId: destinationId, threadId: threadId)
        return .object(obj.merging(diagnostic) { _, receipt in receipt })
    }
}
