import Foundation
import NativeAgentCore
import PersistenceCore
import os
import TurnTrace
// Blueprint: | `LLMRequestShape.swift` | Request cache markers, conversation-prefix snapshots and task-local secondary-call isolation; `ToolContractWeight` measures schema material without retaining content |

/// Cache marker positions and TTLs from the finished request body, never prompt bytes.
/// Anthropic renders tools → system → messages; longer TTLs must precede shorter ones.
public struct LLMCacheMarker: Sendable, Equatable {
    /// `"tools[2]"`, `"system[1]"`, `"messages[7]"` — section plus index.
    public let position: String
    /// `"1h"` for extended TTL; `"5m"` names the wire's absent-`ttl` default.
    public let ttl: String

    public init(position: String, ttl: String) {
        self.position = position
        self.ttl = ttl
    }

    var json: JSONValue {
        .object(["position": .string(position), "ttl": .string(ttl)])
    }
}

// MARK: - Conversation-prefix shape receipts
//
// Prefix receipts flow through a turn-scoped task-local and remain absent when unbound.
// Receipts contain sizes, digests and bounded redacted previews.
public struct ConversationPrefixTelemetrySnapshot: Sendable, Equatable {
    public let shapeVersion: String
    public let prefixFingerprintSHA256: String
    public let historyMessageCount: Int
    public let historyMessageChars: Int
    public let volatileBlockChars: Int
    public let volatileFullBlockBytes: Int
    public let volatileDeltaBlockBytes: Int
    public let volatileKeyframe: Bool
    public let volatileDelivery: String
    public let windowCursorAdvanceCount: Int
    public let windowSlid: Bool
    /// Message count and bounded digests of role plus serialized content (first 12 SHA-256 hex).
    /// Digests expose head drift even when consecutive messages have equal sizes.
    public let messageCount: Int
    public let messageDigests: [String]
    /// One digest per cacheable-prefix message, excluding the current user message.
    /// Reuse requires turn N's list to prefix turn N+1's; the whole-prefix hash changes each turn.
    public let prefixMessageDigests: [String]
    /// Bounded prefix conversation excerpts, credential-redacted before truncation.
    public let headPreviews: [String]
    /// Separate stable-instruction, tools and history-head fingerprints identify drift.
    /// Empty when the caller does not compute them.
    public let stablePrefixFingerprintSHA256: String
    public let toolsFingerprintSHA256: String
    public let historyHeadFingerprintSHA256: String
    public init(
        shapeVersion: String,
        prefixFingerprintSHA256: String,
        historyMessageCount: Int,
        historyMessageChars: Int,
        volatileBlockChars: Int,
        volatileFullBlockBytes: Int = 0,
        volatileDeltaBlockBytes: Int = 0,
        volatileKeyframe: Bool = false,
        volatileDelivery: String,
        windowCursorAdvanceCount: Int,
        windowSlid: Bool,
        messageCount: Int = 0,
        messageDigests: [String] = [],
        prefixMessageDigests: [String] = [],
        stablePrefixFingerprintSHA256: String = "",
        toolsFingerprintSHA256: String = "",
        historyHeadFingerprintSHA256: String = "",
        headPreviews: [String] = []
    ) {
        self.shapeVersion = shapeVersion
        self.prefixFingerprintSHA256 = prefixFingerprintSHA256
        self.historyMessageCount = historyMessageCount
        self.historyMessageChars = historyMessageChars
        self.volatileBlockChars = volatileBlockChars
        self.volatileFullBlockBytes = volatileFullBlockBytes
        self.volatileDeltaBlockBytes = volatileDeltaBlockBytes
        self.volatileKeyframe = volatileKeyframe
        self.volatileDelivery = volatileDelivery
        self.windowCursorAdvanceCount = windowCursorAdvanceCount
        self.windowSlid = windowSlid
        self.messageCount = messageCount
        self.messageDigests = messageDigests
        self.prefixMessageDigests = prefixMessageDigests
        self.headPreviews = headPreviews
        self.stablePrefixFingerprintSHA256 = stablePrefixFingerprintSHA256
        self.toolsFingerprintSHA256 = toolsFingerprintSHA256
        self.historyHeadFingerprintSHA256 = historyHeadFingerprintSHA256
    }

    public var payload: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "shapeVersion": .string(shapeVersion),
            "prefixFingerprintSHA256": .string(prefixFingerprintSHA256),
            "historyMessageCount": .int(Int64(historyMessageCount)),
            "historyMessageChars": .int(Int64(historyMessageChars)),
            "volatileBlockChars": .int(Int64(volatileBlockChars)),
            "volatileFullBlockBytes": .int(Int64(volatileFullBlockBytes)),
            "volatileDeltaBlockBytes": .int(Int64(volatileDeltaBlockBytes)),
            "volatileKeyframe": .bool(volatileKeyframe),
            "volatileDelivery": .string(volatileDelivery),
            "windowCursorAdvanceCount": .int(Int64(windowCursorAdvanceCount)),
            "windowSlid": .bool(windowSlid),
            "messageCount": .int(Int64(messageCount)),
            "messageDigests": .array(messageDigests.map { .string($0) }),
            "prefixMessageDigests": .array(prefixMessageDigests.map { .string($0) }),
            "headPreviews": .array(headPreviews.map { .string($0) }),
        ]
        if !stablePrefixFingerprintSHA256.isEmpty {
            out["component.stablePrefixSHA256"] = .string(stablePrefixFingerprintSHA256)
        }
        if !toolsFingerprintSHA256.isEmpty {
            out["component.toolsSHA256"] = .string(toolsFingerprintSHA256)
        }
        if !historyHeadFingerprintSHA256.isEmpty {
            out["component.historyHeadSHA256"] = .string(historyHeadFingerprintSHA256)
        }
        return out
    }
}

/// Turn-scoped receipt mailbox, bound empty at turn admission and filled after context assembly.
public final class ConversationPrefixTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConversationPrefixTelemetrySnapshot?
    private var weight: ToolContractWeight.Measurement?

    /// True when this binding exists to SHED an outer turn's receipts rather
    /// than to carry its own. Such a sink is permanently empty.
    public let marksRequestShapeUnmeasured: Bool

    /// The sink a secondary lane binds to detach the parent turn's shape. One
    /// shared value is safe because it is permanently empty by construction.
    public static let unmeasuredRequestShape =
        ConversationPrefixTelemetrySink(marksRequestShapeUnmeasured: true)

    public init(marksRequestShapeUnmeasured: Bool = false) {
        self.marksRequestShapeUnmeasured = marksRequestShapeUnmeasured
    }

    public func set(_ snapshot: ConversationPrefixTelemetrySnapshot) {
        // Secondary-call bindings remain permanently unmeasured.
        guard !marksRequestShapeUnmeasured else { return }
        lock.lock(); value = snapshot; lock.unlock()
    }

    public var current: ConversationPrefixTelemetrySnapshot? {
        lock.lock(); defer { lock.unlock() }; return value
    }

    public func set(_ measurement: ToolContractWeight.Measurement) {
        guard !marksRequestShapeUnmeasured else { return }
        lock.lock(); weight = measurement; lock.unlock()
    }

    public var toolWeight: ToolContractWeight.Measurement? {
        lock.lock(); defer { lock.unlock() }; return weight
    }
}

public enum ConversationPrefixTelemetry {
    /// Bound once per turn by the chat lane, alongside the shape task-local.
    @TaskLocal public static var sink: ConversationPrefixTelemetrySink?

    public static var current: ConversationPrefixTelemetrySnapshot? { sink?.current }

    /// Does the innermost binding say "this call's request shape is not the one
    /// in the sink"?
    public static var requestShapeUnmeasured: Bool { sink?.marksRequestShapeUnmeasured == true }

    /// Secondary calls retain turnId with an unmeasured shape, shedding chat receipts, route and token budget.
    public static func withUnmeasuredRequestShape<T: Sendable>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $sink.withValue(.unmeasuredRequestShape) {
            try await LLMCallContext.$providerId.withValue(nil) {
                try await LLMCallContext.$admittedModel.withValue(nil) {
                    try await LLMCallContext.$reasoningEffort.withValue(nil) {
                        try await LLMCallContext.$serviceTier.withValue(nil) {
                            try await LLMCallContext.$turnTokenBudget.withValue(nil) {
                                try await body()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Tool totals measure schema-material bytes (name, description and parameter JSON) without retaining content.
public enum ToolContractWeight {
    public struct Measurement: Sendable, Equatable {
        public let floorCount: Int
        public let appendedCount: Int
        public let floorBytes: Int
        public let appendedBytes: Int

        public init(floorCount: Int, appendedCount: Int, floorBytes: Int, appendedBytes: Int) {
            self.floorCount = floorCount
            self.appendedCount = appendedCount
            self.floorBytes = floorBytes
            self.appendedBytes = appendedBytes
        }

        public var wireBytes: Int { floorBytes + appendedBytes }
        /// nil rather than 0/0 when there is no tool material to divide.
        public var appendedShareOfWireBytes: Double? {
            wireBytes > 0 ? Double(appendedBytes) / Double(wireBytes) : nil
        }
    }

    /// Material bytes of one schema, the `context.snapshot` convention.
    public static func materialBytes(
        name: String, description: String, parameterBytes: Int
    ) -> Int {
        name.utf8.count + description.utf8.count + max(0, parameterBytes)
    }

}
