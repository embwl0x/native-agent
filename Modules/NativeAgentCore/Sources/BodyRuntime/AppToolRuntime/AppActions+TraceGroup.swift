import PersistenceCore
import MacNerves
import NativeAgentCore
import NativeAgentShared
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+TraceGroup.swift` | Trace action declarations |

extension AppActions {
    static func traceGroup() throws -> [AppAction] {
        try [
        // A part's line is a world happening the agent's attention weighs, never context (AGENT_IS_THE_APP contract #2).
        AppAction("home.arrive", "desk", """
            From a part's run: one line for your attention, weighed by your turn program; event_key deduplicates this occurrence durably within this \
            part, otherwise the same line is offered once per local day
            """,
                  [.required("line"), .optional("event_key")], tool: "home_arrive", versionExempt: true),

        // Folded reads are scriptable and raise no inbox notes.
        .fold("time_now", "*", "The date and time now: local, UTC, epoch, weekday and day of year", read: true),
        .fold("context_expand", "chat", """
            Read deeper context by its offered atom id or a history: id from a replayed receipt; offset defaults to 0, pages cap at 12000 characters, \
            continue with next_offset until null
            """,
              [.required("atom_id"), .optional("max_characters", .integer), .optional("offset", .integer)], read: true,
              argumentReferences: ["message_id": .init(parameter: "atom_id", prefix: "history:", qualifiers: ["agent"]),
                                   "history": .init(parameter: "atom_id", prefix: "history:", qualifiers: ["agent"])]),
        .fold("inner_state", "personality",
              "Your inner state, from your organs' record; asked how you feel, read this first, then speak",
              [.optional("window_hours", .integer), .optional("detail", .options("compact", "full"))], read: true),
        .fold("agent_introspect", "diagnostics", "Your live runtime, provider and conversation identity",
              [.optional("detail", .options("compact", "full"))], read: true),
        .fold("recent_trace_summary", "diagnostics", """
            Read traces from the life record; events stay in this conversation unless scope:all, which reads every conversation and the background \
            life; receipts and a receipt_id span all conversations unless session_id is explicit, with non-read actions first and complete \
            retained since windows
            """,
              [.optional("view", .receiptView), .optional("effects_only", .boolean), .optional("since"), .optional("limit", .integer), .optional("before"), .optional("offset", .integer), .optional("completed_turns", .integer), .optional("kind"), .optional("name"),
                  .optional("status"), .optional("scope", .options("conversation", "all")), .optional("session_id"), .optional("turn_id"), .optional("receipt_id"), .optional("fields", .shortStrings)], read: true),
        .fold("recent_trace_summary", "diagnostics", id: "trace.model_calls", """
            Model calls: per-turn counts by purpose and rounds per turn (p50, p90) for the last 24 hours and 7 days, the top five purposes by total \
            milliseconds, and the week's five heaviest asks with their first six calls; reads retained traces without a model call
            """,
              [], input: ["view": .string("model_calls")], read: true),
        .fold("recent_trace_summary", "diagnostics", id: "trace.usage", """
            Recorded model usage: exact retained call, input, cache read/creation/write and lifetime splits, output token and duration sums by model, \
            surface or local day; reports each cache counter separately with its provider semantics; since \
            defaults to today (local midnight) or accepts an ISO-8601 timestamp; reports missing measurements and retention coverage
            """,
              [.optional("since"), .optional("by", .options("model", "surface", "day"))], input: ["view": .string("usage")], read: true),
        ]
    }
}
