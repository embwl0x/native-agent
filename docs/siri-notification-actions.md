# Siri and Mac notification actions

The macOS 26 implementation adds `AskResidentAgentIntent` alongside the eight
existing actions. It delegates to `NativeAgentChatIntent`, preserving the same
retained conversation, provider selection, Trust path, and full reply value.
`ResidentAgentEntity` has a stable resident identifier and reads its display
name from `PersonaCompiler.agentDisplayName()`. No personal name is baked into
the public bundle.

The installed SDK's `AppShortcutPhrase.StringInterpolation` accepts the
application-name token and an intent parameter key path; `AppShortcutsProvider`
exposes `updateAppShortcutParameters()`. The phrases use the application-name
token and one entity parameter, never the free-text message. Launch and profile
name changes refresh the suggested entity. See Apple's
[App Shortcuts explanation](https://developer.apple.com/videos/play/wwdc2023/10102/).

Mac notification actions require foreground activation and authentication.
Approve/Deny reread the canonical inbox, require a pending row with reviewable
details, and call the same `ApprovalDecisionAction` as in-app buttons. Inbox
authority and the existing effect executors remain responsible for trust,
resolution races, and execution outcome. Default clicks never resolve requests.
An app-lifetime file observer posts newly pending approvals; startup establishes
a baseline without replaying old requests. Existing quiet hours suppress these
banners. Suppressed/failed banners remain reviewable in Approvals and are not
automatically retried.

`mac_notify`, connector notifications, and MacControl notification messages
offer Reply. Their session is captured from trusted turn context when posted;
messages outside a turn create a dedicated conversation when Reply is used.
Reply enters the same composer admission/queue and resident Mac chat path and
opens the resulting transcript. System status/error and Desk reminders retain
their existing navigation-only behavior.

## Build and metadata inspection

From the integration checkout:

```sh
swift build --disable-keychain -j 6
./script/build_and_run.sh --build-only
rg -n 'AskResidentAgentIntent|NativeAgentChatIntent|ResidentAgentEntity|phrases|Ask |Tell ' dist/NativeAgent.app/Contents/Resources/Metadata.appintents
jq -r '.actions[].identifier, (.autoShortcuts[] | .actionIdentifier, .phraseTemplates[].key)' dist/NativeAgent.app/Contents/Resources/Metadata.appintents/extract.actionsdata
```

The generated bundle contains nine intents and eight App Shortcuts. The new
action is `AskResidentAgentIntent`; the existing `NativeAgentChatIntent`,
`NativeAgentStatusIntent`, `NativeAgentDoctorIntent`,
`NativeAgentApprovalsIntent`, `NativeAgentWorkshopTaskIntent`,
`QueryMemoryIntent`, `StoreMemoryIntent`, and `ListPendingMemoryProposalsIntent`
remain present. The named phrase templates contain `${agent}` and
`${applicationName}`; the actual persona name is supplied at runtime.

## Small checks after the integrator installs the app

1. Launch the installed build once. Open Shortcuts → App Shortcuts → NativeAgent.
   Confirm the existing shortcuts remain and Ask Your Agent offers the configured
   agent as its Agent parameter. Inspect its Siri phrases for “Ask <name> in
   NativeAgent” and “Tell NativeAgent's <name>”.
2. Say “Siri, Ask Agent in NativeAgent” on this Mac (substitute the configured
   name elsewhere). When Siri asks for Message, say “Reply with hello.” Confirm
   the response and the retained Shortcuts conversation. Repeat with “Tell
   NativeAgent's Agent”. Arbitrary trailing text is not a phrase parameter.
3. Run the original Ask NativeAgent shortcut with a request for a reply longer
   than 260 characters and inspect its output value; it must remain complete.
   Check the original Status, Doctor, Approvals, Desk Task, Query Memory,
   Remember, and Pending Proposals actions are still listed.
4. With notification alerts enabled and quiet hours off, request one benign
   action that the current Trust policy requires confirmation for. Do not relax
   Trust merely to generate a banner. Expand its new approval banner and click
   Approve. Confirm the same request's decision and effect receipt in Approvals.
   Use a second benign request for Deny and confirm it has no execution effect.
   A plain click should only open Approvals. Already-resolved banners must fail
   explicitly if acted on again.
5. Ask the agent to send one `mac_notify` message. Switch to another conversation
   before expanding its banner and using Reply → “Reply with hello.” Confirm the
   reply and resulting assistant turn land in the originating conversation,
   through normal Trust/approval handling. A plain click must only navigate.

The worker builds but does not install, launch, call the bridge, or claim Siri
recognition/banner execution proof. Siri indexing, notification permission,
Focus presentation, and installed action behavior require these integration
checks. No macOS 27 API is needed by this slice.
