# Siri and Mac notification actions

## Siri on Mac

**Ask Your Agent** offers these phrases, with the configured persona name:

- “Ask [name] in NativeAgent”
- “Tell NativeAgent's [name]”
- “Ask my agent in NativeAgent”

Siri asks for the Message separately. `ResidentAgentEntity` loads the canonical
persona profile through `NativeAgentEngine.live.persona.loadProfile()` and
projects its name with `NativeAgentIdentity.displayName(profile.name)`; launch
and profile-name changes refresh shortcut parameters.

`AskResidentAgentIntent` owns the shared `reply(to:)` entry.
It continues `ConversationAnchor.currentSessionId()` or creates a conversation
when none exists, uses the chat settings and normal chat path, and returns the
full reply string. On macOS 27, the Ask intent adopts `LongRunningIntent`
and uses `performBackgroundTask`; earlier systems call the same reply method
directly.

The source also defines Status, Doctor, Approvals, Desk Task, Query Memory,
Remember and Pending Memory Proposals intents. The App Shortcuts list includes
Ask Your Agent and these actions except Desk Task. The duplicate Ask NativeAgent
intent and its separate shortcut registration are removed.

## iPhone and iPad

Native App Shortcuts expose six actions:

| Action | Result |
|---|---|
| Ask Your Agent | Sends a message in the current conversation and waits for the Mac's reply. |
| Remember | Sends “Please remember this: …” through the same chat path. |
| Approve | Rereads a remotely decidable pending request, asks for confirmation and sends the decision. |
| Status | Reads the last synced live status with its timestamp. |
| Quick Ask | Opens Chat and focuses the composer. |
| Talk to <agent name> | Opens the active conversation in hands-free talk; also usable from the Action Button. The existing Control Center control opens talk directly. |

Ask, Remember, Approve and Status require authentication and the current paired
agent over CloudKit. Talk also requires the current paired agent and authentication,
opens the app, and obtains microphone and Speech permission before listening.
Cold approval actions read both the pending approvals and the synced Inbox face
before sending its exact row call; they do not depend on a mounted phone scene.
Its on-device recognition, voice and audio lifetime are described in
[Talk mode](mobile_companion.md#talk-mode). New work needs the Mac awake with NativeAgent open.
Ask/Remember wait on the original correlation's reply or terminal event, intent
cancellation or owner shutdown. Silence leaves that request pending; invoking
the shortcut again creates a separate message.
Chat and the intent share terminal classification. Explicit `reply`/`final`
completes the intent; `error`, `cancelled` and signed rejection report failure.
`incomplete` or a missing kind ends the wait with the received words and
unconfirmed status, never success inferred from silence.

Notification Reply retains the text in its conversation's durable chat queue
before delivery. A failed send stays queued for recovery in Chat.

## Mac notification actions

Approve, Deny and Reply require foreground activation and authentication.
Approve/Deny reread the canonical inbox, require a pending request with
reviewable details, and use `ApprovalDecisionAction`, as the in-app buttons do.
A normal notification click navigates without deciding the request.
Approval and Desk destinations enter Advanced view from Simple or Agent view,
independently of any chat shortcut overlay. A chat destination preserves the
person's current view mode.

The approval observer establishes a startup baseline for Mac banners. New
pending requests retain their Mac and phone intents on the canonical card.
Quiet hours defer their ledger claims. Known refusals remain retryable; an
unknown send waits for evidence. Turning off Mac notifications settles that
destination as suppressed once. Every native banner goes through the same
per-occurrence claim and OS acknowledgement, including fire-and-forget posts.

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
Mobile source under `iOS/NativeAgentMobile/`: `Sources/MobileAppIntents.swift`,
`Sources/MobileIntentRuntime.swift` and `ControlSupport/MobileQuickAskIntent.swift`.
