import Foundation

extension SwiftNativeChatOrchestrationClient {
    nonisolated static func textCompatibilityEmptyReplyFeedback(
        ridesNativeTools: Bool
    ) -> String {
        let feedback = ridesNativeTools
            ? "Your previous response contained only internal "
                + "reasoning and NO output — nothing reached the user or "
                + "the tool runtime, so whatever you decided never happened. "
                + "Respond again NOW: either make the tool call(s) for the "
                + "action you chose, or deliver your complete answer as "
                + "plain prose. The response must never be empty."
            : "Your previous response contained only internal "
                + "reasoning and NO text output — nothing reached the user or "
                + "the tool runtime, so whatever you decided never happened. "
                + "Respond again NOW with actual text: either emit the "
                + "<tool_use name=\"tool_name\">{\"arg\": \"value\"}</tool_use> "
                + "marker(s) for the action you chose, or deliver your complete "
                + "answer as plain prose. The text channel must never be empty."
        return feedback
    }

    nonisolated static func textCompatibilityAnnounceFeedback(
        turnActiveTools: Set<String>,
        preloadAvailableNames: Set<String>,
        ridesNativeTools: Bool,
        announceNudgeCount: Int
    ) -> String {
        let readySource = turnActiveTools.isEmpty ? preloadAvailableNames : turnActiveTools
        let readyTools = readySource.sorted().prefix(8).joined(separator: ", ")
        // Same lane-awareness as the empty-reply nudge: the
        // announce detector still applies to FINAL prose on the
        // native lane, but the remedy it prescribes must match the
        // lane's actual calling convention.
        let nextStepInstruction = ridesNativeTools
            ? "make the next tool call"
            : "emit the next <tool_use name=\"tool_name\">{\"arg\": \"value\"}"
                + "</tool_use> marker(s)"
        let feedback: String
        if announceNudgeCount == 1 {
            feedback = "NativeAgent completion contract: your reply describes work "
                + "as in progress but this runtime has NO background execution — "
                + "work you narrate without a tool call never happens, and the "
                + "user is left waiting. Continue NOW in this same turn: "
                + "\(nextStepInstruction), or deliver your complete final answer. "
                + "Tools ready: \(readyTools)."
        } else if ridesNativeTools {
            feedback = "SECOND bounce — you again narrated instead of acting. This "
                + "is your last continuation: either make the tool call for the "
                + "next step right now, or give the user your "
                + "complete final answer (including any concrete blocker). Do not "
                + "describe future work."
        } else {
            // BYTE-IDENTICAL to the pre-native-lane wording for
            // every text-lane provider (gpt-5.5 blocking #2).
            feedback = "SECOND bounce — you again narrated instead of acting. This "
                + "is your last continuation: either emit the exact tool_use "
                + "marker for the next step right now, or give the user your "
                + "complete final answer (including any concrete blocker). Do not "
                + "describe future work."
        }
        return feedback
    }
}
