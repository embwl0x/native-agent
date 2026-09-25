import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore

extension SwiftToolDispatcher {
    /// Agent raising a need HERSELF, before hitting a wall.
    ///
    /// The boundaries raise needs when a tool is already blocked. This is the
    /// other direction: she can see from the request that she is about to be
    /// blocked ("can you see my GitHub?") and ask for the one thing that
    /// unblocks it, instead of making a failing call first so that the failure
    /// can produce a card.
    ///
    /// What she supplies is deliberately thin: a kind, a canonical ID, and the
    /// prose. Everything that could become an ACTION — the control that opens,
    /// where it can run, whether it is available at all — comes from the
    /// registry. She cannot invent a button, name a URL, point at a settings
    /// path, or widen what a grant covers. An unknown kind or an ID with no
    /// control returns a plain failure, so an unsupported ask reads as
    /// unsupported rather than as a card that does nothing.
    func impl_request_interaction(input: [String: JSONValue]) async -> JSONValue {
        func text(_ keys: String...) -> String? {
            for key in keys {
                if case .string(let value)? = input[key] {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }
        func failed(_ reason: String, _ detail: String) -> JSONValue {
            .object([
                "status": .string("failed"),
                "tool": .string(InlineInteractionWire.toolName),
                "reason": .string(reason),
                "error": .string(detail),
            ])
        }

        guard let rawKind = text("kind") else {
            return failed("missing_kind", "request_interaction requires a kind.")
        }
        let kind = InlineInteraction.Kind(rawValue: rawKind) ?? .unknown
        guard kind != .unknown else {
            return failed("unknown_kind", "There is no \(rawKind) request in this app.")
        }
        // 2026-09-24 trace: she sent {"connector": "github", "message": ...}
        // and burned two calls on missing_why / missing_target.
        guard let why = text("why", "reason", "message") else {
            return failed("missing_why", "Say in one sentence why this is needed.")
        }
        // She names it by its kind as often as by `target` (09-24:
        // connector:"github" came back missing_target).
        let target = text("target", rawKind) ?? ""
        // Her own words for what a decline costs, when she has them; the
        // registry's default otherwise. Never empty — Agent's rule is that
        // every decline says what happens next.
        let declineConsequence = text("decline_consequence", "consequence")

        let options: [InlineInteraction.Option] = {
            guard case .array(let rows)? = input["options"] else { return [] }
            return rows.compactMap { row in
                guard case .object(let object) = row,
                      case .string(let id)? = object["id"]
                else { return nil }
                let label: String = {
                    if case .string(let value)? = object["label"] { return value }
                    return id
                }()
                var detail: String?
                if case .string(let value)? = object["detail"] ?? object["description"] {
                    detail = value
                }
                return InlineInteraction.Option(id: id, label: label, detail: detail)
            }
        }()

        let interaction: InlineInteraction?
        switch kind {
        case .connector:
            guard !target.isEmpty else {
                return failed("missing_target", "Name the connector to connect.")
            }
            interaction = InlineInteractionRegistry.connector(
                target, why: why, dataRoot: dataRoot,
                declineConsequence: declineConsequence
            )
        case .permission:
            // A chain she can predict is ONE ask. Extra capabilities are
            // canonical ids from the Mac list; anything the registry does not
            // know renders unavailable rather than granting something vague.
            var capabilities = target.isEmpty ? [] : [target]
            if case .array(let extra)? = input["also_needed"] ?? input["additional_targets"] {
                capabilities += extra.compactMap {
                    if case .string(let value) = $0 { return value }
                    return nil
                }
            }
            // She may say which axis she needs; she cannot widen one. An
            // unknown value reads as "both", which is what the card would have
            // said before this field existed.
            interaction = InlineInteractionRegistry.permission(
                capabilities,
                why: why,
                mode: text("mode", "access").flatMap { InlineInteraction.AccessMode(rawValue: $0) },
                declineConsequence: declineConsequence
            )
        case .modelChoice:
            guard !target.isEmpty else {
                return failed("missing_target", "Name the Providers group.")
            }
            interaction = InlineInteractionRegistry.modelChoice(
                group: target, why: why, options: options,
                scopedToThisRequest: text("scope_noun"),
                declineConsequence: declineConsequence
            )
        case .apiKey:
            guard !target.isEmpty else {
                return failed("missing_target", "Name the provider.")
            }
            interaction = InlineInteractionRegistry.apiKey(
                provider: target, why: why, declineConsequence: declineConsequence
            )
        case .capability:
            interaction = InlineInteractionRegistry.capability(
                target, why: why, declineConsequence: declineConsequence
            )
        case .choose:
            guard let question = text("title", "question") else {
                return failed("missing_question", "A choice needs a question.")
            }
            guard let consequence = declineConsequence else {
                return failed(
                    "missing_consequence",
                    "A choice needs decline_consequence: say what happens if they don't pick."
                )
            }
            interaction = InlineInteractionRegistry.choose(
                question: question, why: why, options: options,
                declineConsequence: consequence
            )
        case .unknown:
            interaction = nil
        }

        guard let interaction else {
            return failed(
                "unavailable",
                "There is no control in this app for \(target.isEmpty ? rawKind : target)."
            )
        }
        // Last gate: a descriptor with no executable control must not become a
        // card with a dead button.
        // The WHOLE chain, because the whole chain is what one tap grants: an
        // additional target this build does not know — or one the current
        // posture forbids — has to be refused HERE, at the raise, not
        // discovered after the person has already tapped.
        let descriptor = InlineInteractionRegistry.descriptor(
            kind: interaction.kind,
            target: interaction.target,
            additionalTargets: interaction.additionalTargets,
            dataRoot: dataRoot
        )
        guard descriptor.isActionable else {
            return failed(
                "unavailable",
                descriptor.unavailableReason ?? "No control for \(interaction.target)."
            )
        }
        return InlineInteractionNeed.envelope(interaction)
    }
}
