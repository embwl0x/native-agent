import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

/// Builds the typed "I need something from you" tool envelope that a dispatch
/// boundary returns INSTEAD of an error string, and reads it back out.
///
/// The shape is deliberately small:
///
/// ```json
/// { "status": "needs_input",
///   "needs": { ...encoded InlineInteraction... } }
/// ```
///
/// Two rules hold this honest and are the reason this type exists rather than
/// each boundary hand-rolling a dictionary:
///
/// 1. **Only a typed boundary may raise a need.** A corrupt store, an
///    unsupported route, malformed arguments, a missing bridge, or a security
///    refusal is a FAILURE, not a setup invitation. Those keep their existing
///    envelopes.
/// 2. **Nothing the model wrote defines a button.** The need carries canonical
///    IDs and prose only. The card's action comes from the descriptor registry
///    on the app side; no URL, selector, settings path, or executable action
///    crosses this boundary.
public enum InlineInteractionNeed {
    /// The envelope a boundary returns. `status` is `needs_input`, which
    /// `ChatToolOutcome.exactResultClass` already treats as non-terminal
    /// (unknown) rather than as a success or a failure.
    public static func envelope(_ interaction: InlineInteraction) -> JSONValue {
        var object: [String: JSONValue] = [
            "status": .string(InlineInteractionWire.waitingStatus),
            "kind": .string(interaction.kind.rawValue),
        ]
        if !interaction.target.isEmpty {
            object["target"] = .string(interaction.target)
        }
        // A one-line reason so a surface that knows nothing about cards (a
        // log, a bot transport) still says something true.
        object["detail"] = .string(interaction.why)
        if let encoded = encode(interaction) {
            object[InlineInteractionWire.needsKey] = encoded
        }
        return .object(object)
    }

    /// The interaction carried by a tool result, or nil for every other
    /// envelope. Strict by construction: a result must say `needs_input` AND
    /// carry a decodable interaction with a non-empty id. Anything else stays
    /// an ordinary tool receipt — a malformed envelope must never surface an
    /// actionable card without an authority behind it.
    public static func interaction(in result: JSONValue) -> InlineInteraction? {
        guard case .object(let object) = result,
              case .string(let status)? = object["status"],
              (status == InlineInteractionWire.waitingStatus
                || (status == "ok" && object["connected"] == .bool(false)
                    && object["kind"] == .string("connector"))),
              let raw = object[InlineInteractionWire.needsKey],
              let interaction = decode(raw),
              !interaction.id.isEmpty,
              interaction.kind != .unknown
        else { return nil }
        return interaction
    }

    /// Same question against a persisted result summary string.
    public static func interaction(inResultSummary summary: String) -> InlineInteraction? {
        guard let value = try? JSONValue.parse(Data(summary.utf8)) else { return nil }
        return interaction(in: value)
    }

    /// True when this result is a raised need. The tool loop asks this to stop
    /// launching subsequent calls and to terminate the turn as WAITING —
    /// neither progress nor failure.
    public static func isWaiting(_ result: JSONValue) -> Bool {
        interaction(in: result) != nil
    }

    // MARK: JSON bridging

    public static func encode(_ interaction: InlineInteraction) -> JSONValue? {
        guard let data = try? InlineInteractionWire.encoder().encode(interaction),
              let value = try? JSONValue.parse(data)
        else { return nil }
        return value
    }

    public static func decode(_ value: JSONValue) -> InlineInteraction? {
        guard let data = try? value.serializedData(pretty: false) else { return nil }
        return try? InlineInteractionWire.decoder().decode(InlineInteraction.self, from: data)
    }
}
