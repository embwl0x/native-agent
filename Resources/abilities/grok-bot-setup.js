/* NativeAgent ability
{"id":"grok-bot-setup","kind":"ability","version":1,
 "reach":{"capabilities":[]},"face":{"page":"agents"},
 "record":{
  "description":"Grok Bot's setup and disconnect words: the message the agent types into Grok Bot's chat and its steps.",
  "actions":[],"inputSchema":{"type":"object","required":["operation","contact","chat","routine"]}}}
*/
function run(input) {
    // The contact record, Keychain, agent.grok_paste's take and the webhook send stay native: no URL, key or secret reaches this part.
    var chat = "“" + input.chat + "”", routine = "“" + input.routine + "”";
    var type = "1. Type the message into the Grok Bot chat " + chat + " with your own Mac hands and send it.";
    if (input.operation === "disconnect") {
        return {
            message: "Delete only the routine named " + input.routine + " that NativeAgent asked you to create in this conversation. "
                + "Do not delete or change any other routine. Never show its URL or key in chat.",
            steps: [
                type,
                "2. Approve the deletion in Grok Bot if it asks. The routine " + routine + " is gone when Grok says so or it no longer shows "
                    + "in Grok Bot's Routines."
            ],
            detail: "Local keys are revoked and the contact is removed. What is left is the routine in Grok Bot, which these steps delete."
        };
    }
    return {
        message: "Please create one Active webhook routine named " + input.routine + " for NativeAgent, or reuse it if it already exists "
            + "(never create a second one). Use the exact instruction below as the routine's instruction, make sure the routine is turned on, "
            + "and change no other routine or local execution policy. Do not put its webhook URL or key in this chat. When the routine exists "
            + "and is on, say so; if you cannot finish (a setting must be switched on, an approval is needed, anything else), say exactly what "
            + "is needed.\n\n" + input.instruction,
        steps: [
            type,
            "2. When Grok says the routine " + routine + " exists and is on, open that routine in Grok Bot and press its own Copy for the "
                + "webhook address.",
            "3. Call agent.grok_paste for this contact: the app pastes the clipboard into its secure Grok field and saves it to Keychain "
                + "(never into a result). Then press the routine's Copy for the webhook key and call agent.grok_paste again. The field takes "
                + "{\"url\":\"…\",\"key\":\"…\"}, the address and the key one after the other separated by a space or a new line, "
                + "or each alone in turn."
        ],
        detail: "Follow the steps in order; nothing here waits or reads Grok's chat. If Grok Bot's window has changed and a step no longer "
            + "fits, revise this ability (ability.read {id:\"grok-bot-setup\"}, then ability.save with the edit)."
    };
}
