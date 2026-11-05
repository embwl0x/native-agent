import AuthoredCapabilities
import ChatToolParsing
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import MacControl
import MacIntegration
// Blueprint: | `InlineInteractionNeed.swift` | `InlineInteractionNeed` enum; `blocksTurn`, `envelope` |

/// Only typed boundaries may raise needs; corrupt stores, unsupported routes, malformed input, missing bridges and security refusals remain failures. Model
/// text defines no button: carry canonical IDs and prose; the app registry alone supplies executable actions.
public enum InlineInteractionNeed {
    public static func blocksTurn(_ interaction: InlineInteraction) -> Bool {
        (interaction.kind == .permission && interaction.allTargets.contains {
            SystemPermissionPreflight.cardSettingsCapability($0) != nil
        }) || ![.connector, .permission, .capability].contains(interaction.kind)
    }

    /// macOS grants wait for the person's tap; other setup keeps its typed card.
    public static func envelope(invocation: ChatToolInvocation, _ interaction: InlineInteraction) -> JSONValue {
        // A skill's step never raises a card: it hands back to the agent.
        if invocation.handsBack { return SkillRunContext.handBack(interaction.title) }
        var object: [String: JSONValue] = [
            "status": .string(blocksTurn(interaction) ? InlineInteractionWire.waitingStatus : "skipped"),
            "kind": .string(interaction.kind.rawValue),
        ]
        if !interaction.target.isEmpty {
            object["target"] = .string(interaction.target)
        }
        // Retain the card ID so script call rows can address the same interaction.
        object["card_id"] = .string(interaction.id)
        // A one-line reason so a surface that knows nothing about cards (a log, a bot transport) still says something true.
        let unavailable = interaction.kind == .connector ? "connected" : "allowed"
        object["detail"] = .string(blocksTurn(interaction)
            ? interaction.kind == .permission
                ? "Waiting for your permission; tap Allow on the card in NativeAgent."
                : interaction.why
            : "skipped: \(interaction.target) isn't \(unavailable) — card filed")
        if let encoded = encode(interaction) {
            object[InlineInteractionWire.needsKey] = encoded
        }
        return .object(object)
    }

    /// Only needs_input or skipped envelopes with a decodable nonempty interaction ID may create actionable cards.
    public static func interaction(in result: JSONValue) -> InlineInteraction? {
        let reply = ToolResult(result)
        guard case .object(let object) = result,
              reply.status == object["status"]?.stringValue,
              (reply.said(InlineInteractionWire.waitingStatus) || reply.said("skipped")
                || (reply.said("ok") && object["connected"] == .bool(false)
                    && object["kind"] == .string("connector"))),
              let raw = object[InlineInteractionWire.needsKey],
              let interaction = decode(raw),
              !interaction.id.isEmpty,
              interaction.kind != .unknown
        else { return nil }
        return interaction
    }

    public static func interaction(inResultSummary summary: String) -> InlineInteraction? {
        guard let value = try? JSONValue.parse(Data(summary.utf8)) else { return nil }
        return interaction(in: value)
    }

    /// Typed cards preserve their envelope without an error; blocksTurn separately decides whether to yield to the person.
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
