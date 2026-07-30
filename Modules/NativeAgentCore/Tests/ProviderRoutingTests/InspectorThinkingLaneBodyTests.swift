import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import ProviderRouting

// Turn Inspector W2 — summarized-thinking lane request-body tests.
//
// THE U1 CONTRACT (hard): the `thinking` param is part of the Anthropic request
// BODY, so the FLAG-OFF (default) body must be BYTE-IDENTICAL to pre-W2. These
// tests pin:
//   1. flag OFF (unbound, the default) → NO `thinking` key, and the whole body
//      is byte-identical to the body built with the gate explicitly false.
//   2. flag ON → the body adds EXACTLY `thinking:{type:adaptive,display:
//      summarized}` and changes nothing else.
//   3. the gate reads at body-assembly time off the task-local (propagation
//      parity with MessagesCacheHint).
@Suite struct InspectorThinkingLaneBodyTests {

    private func body(thinking: Bool?) -> [String: Any] {
        func build() -> [String: Any] {
            AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                messages: [.user("hi there")],
                system: "sys",
                coercedModel: "claude-opus-4-8",
                maxTokens: 4096,
                tools: nil,
                stream: true
            )
        }
        guard let thinking else { return build() } // unbound — the default
        return InspectorThinkingLane.$summarizedThinking.withValue(thinking) { build() }
    }

    /// Canonical-JSON serialization with sorted keys so two bodies compare
    /// byte-for-byte regardless of dictionary iteration order.
    private func canonical(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 1. flag OFF → no thinking key + byte-identical to explicit-false

    @Test func flagOff_default_has_no_thinking_key() {
        let off = body(thinking: nil) // unbound default
        #expect(off["thinking"] == nil, "default (unbound) body must NOT carry a thinking key")
    }

    @Test func flagOff_is_byte_identical_to_explicit_false() throws {
        // The whole point of the U1 contract: an unbound gate and an explicit
        // false gate produce the SAME bytes — and neither carries `thinking`.
        let unbound = try canonical(body(thinking: nil))
        let explicitFalse = try canonical(body(thinking: false))
        #expect(unbound == explicitFalse, "flag-OFF body must be byte-identical to pre-W2")
        #expect(!unbound.contains("\"thinking\""), "flag-OFF wire body must not mention thinking")
    }

    @Test func flagOff_raw_serialization_never_mentions_thinking() throws {
        // gpt-5.5 W2 review nit: the canonical (sorted-keys) comparison can't
        // catch raw JSONSerialization drift. Assert on the RAW bytes too: the
        // unbound-default body, serialized exactly as the adapter wire path
        // serializes it, must not contain a `thinking` member.
        let raw = try JSONSerialization.data(withJSONObject: body(thinking: nil))
        let s = String(decoding: raw, as: UTF8.self)
        #expect(!s.contains("\"thinking\""), "raw flag-OFF wire bytes must not mention thinking")
    }

    // MARK: 2. flag ON → adds exactly the thinking key, nothing else changes

    @Test func flagOn_adds_exactly_the_thinking_key() throws {
        let on = body(thinking: true)
        let thinking = try #require(on["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")

        // Strip the thinking key off the ON body and it must equal the OFF body
        // byte-for-byte — proving the gate adds ONLY thinking and mutates
        // nothing else (messages/system/tools/stream/model untouched).
        var onMinusThinking = on
        onMinusThinking["thinking"] = nil
        let off = body(thinking: false)
        #expect(try canonical(onMinusThinking) == canonical(off),
                "flag-ON must change ONLY the thinking key")
    }

    // MARK: 3. propagation parity — gate read at body-assembly time

    @Test func gate_reads_at_body_assembly_time() {
        // Bound TRUE around the synchronous build → key present; the binding
        // wraps the build call exactly as the streaming engine wraps stream
        // construction.
        let on = InspectorThinkingLane.$summarizedThinking.withValue(true) {
            AnthropicOAuthDirectAdapter.makeMessagesRequestBody(
                messages: [.user("x")], system: nil, coercedModel: "claude-opus-4-8",
                maxTokens: 16, tools: nil, stream: false
            )
        }
        #expect(on["thinking"] != nil)
        // Outside the binding the default is false again.
        #expect(InspectorThinkingLane.summarizedThinking == false)
    }
}
