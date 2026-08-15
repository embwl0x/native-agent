# App Review 2.1 response — submission `da74935b-3635-4107-8c49-24ecbaeb7fce`

Apple returned NativeAgent iOS `0.3.0 (10)` on 2026-08-14 under
**Guideline 2.1 — Information Needed — New App Submission**. Apple did not
identify a binary defect. Review requested a physical-device walkthrough and
the seven information items below.

Keep review-only attachments and credentials out of git. Attach the final
physical-device recording directly to App Store Connect.

## App Review Information → Notes

NativeAgent is a local-first remote cockpit for the personal AI agent running
on the user's Mac. It is intended for Mac users, developers, and productivity
users who want secure conversation continuity, activity and approval review,
remote task controls, and notifications while away from the Mac. The paired
Mac remains the sole owner of the agent runtime, model-provider connection,
memory, tools, trust policy, and durable actions; the iOS app does not create a
second hosted agent or a NativeAgent cloud account.

REVIEW WALKTHROUGH: A physical-device screen recording is attached. It begins
with launching submitted TestFlight build 0.3.0 (10) on an iPhone 17 Pro Max
running iOS 26.6 and shows the normal flow: connection state, paired Chat,
Activity, approvals, memories, Skills & Tools, Workshop, provider/model
projection, Settings, and the app's microphone/speech/photo/notification
permission surfaces. There are no purchases, subscriptions, account creation,
account deletion, public user-generated-content feed, reporting, or blocking
flows.

TESTED DEVICES / SYSTEMS:
- Physical iPhone 17 Pro Max: iOS 26.5 before submission; iOS 26.6 current recheck.
- NativeAgent Store iPhone Simulator: iOS 26.5.
- NativeAgent Store iPad Simulator: iOS 26.5.

SETUP AND ACCESS:
1. Download and launch the compatible NativeAgent Mac app from
   https://nativeagent.app on a Mac signed into the same Apple Account as the
   review iPhone/iPad.
2. Complete Mac onboarding and connect a supported AI provider in Providers.
3. On Mac, open Settings > Pair iPhone / iPad.
4. Launch NativeAgent on iOS and choose Connect via iCloud. If propagation is
   delayed, use the manual pairing key shown by the Mac app.
5. Send a message from iOS. The Mac performs the provider turn and returns
   signed progress and the final response through the user's private CloudKit
   database.
6. Activity, approvals, memories, Skills & Tools, Workshop, provider/model
   controls, and Settings are available from the mobile navigation.

No NativeAgent username or password exists, and no sample files are required.
Review may tap Skip on the pairing screen to inspect the unpaired interface,
but live chat and actions require the Mac companion and a user-selected model
provider. Pairing keys and provider credentials are user-owned secrets and are
not included in source or public metadata.

EXTERNAL SERVICES / PLATFORMS:
- Apple iCloud/CloudKit private database for signed pairing, messages,
  snapshots, responses, and receipts.
- Apple Push Notification service / CloudKit notifications for paired alerts.
- A model provider selected and authenticated by the user on the Mac. Supported
  integrations include OpenAI/ChatGPT/Codex, Anthropic, xAI, Moonshot/Kimi,
  and OpenRouter. Provider traffic goes directly from the Mac to that provider;
  credentials never pass through the iOS app or a NativeAgent server.
- https://nativeagent.app for the Mac companion, support, and privacy policy.

NativeAgent has no developer-operated account, model proxy, analytics,
advertising, payment processor, or hosted content service. There are no
regional feature or content differences in the app; the same binary and
feature set are available in every selected region. Availability and terms of
an optional third-party model provider can vary by provider and region.

NativeAgent is not a regulated-industry app and is not marketed for medical,
legal, financial, emergency, or safety-critical use. It contains no protected
third-party catalog or licensed media requiring authorization documentation.

Mac companion: https://nativeagent.app
Support: https://nativeagent.app/support
Privacy: https://nativeagent.app/privacy

## Reply to App Review

Hello App Review,

Thank you for the detailed request. We have updated the App Review Information
notes with all seven requested items and attached a physical-device screen
recording of the submitted build's typical flow, beginning with app launch.

NativeAgent is a local-first iPhone/iPad companion to the user's Mac app. It
does not require a NativeAgent account and has no in-app purchases or
developer-operated AI backend. The updated notes explain the target audience,
Mac/iCloud pairing steps, model-provider dependency, tested devices and OS
versions, external services, regional behavior, and regulatory/content status.

Please continue review of submission
`da74935b-3635-4107-8c49-24ecbaeb7fce`. We are happy to provide any additional
information you need.

Best regards,
NativeAgent

## Recording checklist

- Use the submitted TestFlight app `0.3.0 (10)` on the physical iPhone 17 Pro
  Max running iOS 26.6.
- Begin on the Home Screen, launch NativeAgent, and show the build/version in
  Settings.
- Show pairing/connection status without exposing the pairing key or QR code.
- Show a short generic chat round trip and its streamed/final state.
- Show Activity, Approvals, Memories, Skills & Tools, Workshop, provider/model
  projection, and Settings.
- Show or explain microphone, speech, photo-library, and notification prompts;
  do not expose private photos, names, messages, tokens, paths, or credentials.
- Keep the recording concise, landscape-stable if mirrored, and free of
  unrelated notifications.
- Watch the final recording completely before attaching it.
