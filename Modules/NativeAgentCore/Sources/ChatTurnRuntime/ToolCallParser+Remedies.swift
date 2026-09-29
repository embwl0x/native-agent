import ChatToolParsing

extension ToolCallParser {
    /// Completion-contract remedy for the STRUCTURED tool loop's announce-
    /// without-act bounce (F2-M4, 2026-07-23). The structured lane always speaks
    /// the provider's native tool-call convention, so the wording is modeled on
    /// the old native-lane remedy —
    /// NEVER the text marker protocol.
    static func structuredAnnounceContractRemedy(secondBounce: Bool) -> String {
        if !secondBounce {
            return "NativeAgent completion contract: your reply describes work as in "
                + "progress but this runtime has NO background execution — work you "
                + "narrate without a tool call never happens, and the user is left "
                + "waiting. Continue NOW in this same turn: make the next tool call, "
                + "or deliver your complete final answer."
        }
        return "SECOND bounce — you again narrated instead of acting. This is your "
            + "last continuation: either make the tool call for the next step right "
            + "now, or give the user your complete final answer (including any "
            + "concrete blocker). Do not describe future work."
    }

    /// Empty-reply recovery remedy for the STRUCTURED tool loop (FIX 1, B1.1,
    /// 2026-07-23), after the deleted text lane's `emptyReplyNudgeCount`
    /// recovery: a provider that returns an
    /// empty text reply AND zero tool calls (e.g. it did the whole move inside a
    /// thinking block and emitted no output) is not a valid final — nothing
    /// reached the user or the tool runtime. The structured lane always speaks
    /// the provider's native tool-call convention, so the wording mirrors the
    /// native-lane (`ridesNativeTools`) empty-reply nudge, NEVER the text marker
    /// protocol. Bounded at two bounces by the caller; the third empty reply is
    /// accepted as final so a provider that only ever thinks can never loop.
    static func structuredEmptyReplyRemedy(secondBounce: Bool) -> String {
        if !secondBounce {
            return "Your previous response contained only internal reasoning and "
                + "NO output — nothing reached the user or the tool runtime, so "
                + "whatever you decided never happened. Respond again NOW: either "
                + "make the tool call(s) for the action you chose, or deliver your "
                + "complete answer as plain prose. The response must never be empty."
        }
        return "SECOND empty response — again nothing reached the user or the tool "
            + "runtime. This is your last continuation: make the tool call(s) for "
            + "the next step right now, or deliver your complete final answer as "
            + "plain prose. Your response must not be empty."
    }
}
