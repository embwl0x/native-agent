# Siri and Mac notification actions

## Siri

**Ask Your Agent** offers these phrases, with the configured persona name:

- “Ask [name] in NativeAgent”
- “Tell NativeAgent's [name]”
- “Ask my agent in NativeAgent”

Siri asks for the Message separately. `ResidentAgentEntity` reads its name
from `PersonaCompiler.agentDisplayName()`; launch and profile-name changes
refresh shortcut parameters.

`AskResidentAgentIntent` delegates to `NativeAgentChatIntent.reply(to:)`.
It continues `ConversationAnchor.currentSessionId()` or creates a conversation
when none exists, uses the chat settings and normal chat path, and returns the
full reply string. On macOS 27, both chat intents adopt `LongRunningIntent`
and use `performBackgroundTask`; earlier systems call the same reply method
directly.

The source also defines Status, Doctor, Approvals, Desk Task, Query Memory,
Remember and Pending Memory Proposals intents. The App Shortcuts list includes
the two Ask actions and these actions except Desk Task.

## Mac notification actions

Approve, Deny and Reply require foreground activation and authentication.
Approve/Deny reread the canonical inbox, require a pending request with
reviewable details, and use `ApprovalDecisionAction`, as the in-app buttons do.
A normal notification click navigates without deciding the request.

The approval observer establishes a startup baseline and posts newly pending
requests. Quiet hours suppress Mac banners; requests remain available in
Approvals. Suppressed or failed banners are not automatically replayed.

Notifications with a chat session offer Reply in that conversation. Those
marked for a new notification conversation create one when replied to. Replies
open the target transcript and use `startChatTurnForSession`, including composer
admission and busy-session queueing.

## Small checks after installation

1. Open Shortcuts → App Shortcuts → NativeAgent. Confirm Ask Your Agent offers
   the current name. Invoke one named phrase, supply a brief message, and check
   the reply and the conversation it continued.
2. For an existing benign pending approval, use its banner's Approve or Deny
   action and inspect the decision in Approvals. Do not change Trust solely to
   manufacture a banner.
3. Ask for a benign Mac notification through `app` action `notify.mac`, switch
   conversations, then reply from the banner. Confirm the reply reaches the
   originating conversation.

Siri recognition and notification presentation require an installed-app check;
source declarations alone do not establish either.

Source: `Sources/NativeAgentApp/NativeAgentIntents.swift`, `MemoryAppIntents.swift`,
`NativeAgentNotificationActions.swift`, `AppDelegate+Launch.swift`, and
`AppModel.swift`.
