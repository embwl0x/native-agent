# NativeAgent Mobile — App Store Submission Kit

Editable listing and review drafts for the release owner. Replace placeholders
and check the exact signed archive before submission; this document is not a
receipt for App Store processing, production deployment or review approval.

## Product positioning

NativeAgent Mobile connects iPhone and iPad to the agent running in the Mac
app. Live replies and actions require the Mac awake with NativeAgent open.
State that dependency in the listing and review notes.

Apple's [Guideline 4.2.3(i)](https://developer.apple.com/app-store/review/guidelines/#minimum-functionality)
expects an app to function without requiring another app's installation. The
Mac dependency therefore remains a companion-app review risk; disclosure alone
does not resolve it. Before submission, the release owner must record an
explicit decision: obtain an App Review position supporting this companion
design, or make the unpaired iOS experience independently useful while keeping
the agent runtime on the Mac. Skip on the pairing screen only opens the shell
and does not resolve this decision.

## App Store metadata drafts

| Field | Draft |
|---|---|
| Name | NativeAgent |
| Subtitle | Your Mac agent, on iPhone |
| Promotional text | Continue conversations, review activity, and direct your NativeAgent Mac from iPhone or iPad. |
| Keywords | AI,assistant,Mac,companion,chat,memory,productivity,notifications |
| Primary category | Productivity |
| Copyright | [PUBLIC_COPYRIGHT_HOLDER_AND_YEAR] |

### Description

> Stay connected to the personal agent running on your Mac.
>
> Continue chat from iPhone or iPad, review activity and approvals, browse
> memories, and follow work on the Desk. Manage providers, connectors and
> Trust, or share text, links, images and PDFs into Chat.
>
> The Mac owns the agent runtime, provider calls and durable state. The
> companion exchanges signed messages through your Apple account.
>
> Requires NativeAgent on an awake Mac, the same Apple Account on both devices,
> and a configured AI provider on the Mac.

### URLs and review contact

Release configuration embeds these URLs; verify they are publicly reachable
before submission:

- Support: `https://nativeagent.app/support`
- Privacy: `https://nativeagent.app/privacy`

Supply `[PUBLIC_MAC_DOWNLOAD_URL]` for the exact compatible Mac build.
Keep `[APP_REVIEW_CONTACT_NAME]`, `[APP_REVIEW_CONTACT_PHONE]`,
`[APP_REVIEW_CONTACT_EMAIL]` and any review credentials in the appropriate
App Store Connect fields.

## Permission and capability inventory

These declarations come from `iOS/NativeAgentMobile/project.yml` and the
app's entitlements. Reconcile them with the signed archive:

| Declaration | Purpose in the source |
|---|---|
| Microphone and speech recognition | Push-to-talk dictation |
| Photo library | Selected images in chat |
| Camera | Photo capture for an accepted phone request |
| Location when in use | Current location for an accepted phone request |
| Location always/when in use | Arrival/departure for places the user enables |
| Remote notifications | APNS registration and background sync |
| CloudKit, CloudDocuments and KVS | Companion sync and pairing |
| Communication/time-sensitive notifications | Notification presentation |
| App Groups | Shared app/extension storage |

The Share extension requests its App Group. Inspect the other embedded
extensions' signed entitlements as part of the archive, too.

## App Privacy, age rating and export compliance

Complete App Store Connect's questionnaires for the submitted build and
services. Do not infer a final privacy label or age rating solely from source.

`iOS/NativeAgentMobile/Resources/PrivacyInfo.xcprivacy` declares no tracking,
an empty tracking-domain list, and required-reason entries for file timestamps
and UserDefaults. The project sets `ITSAppUsesNonExemptEncryption: false`. These
are source declarations to reconcile with the final archive and submission
answers, not a determination of legal compliance.

## App Review notes draft

> NativeAgent Mobile is a companion to NativeAgent on Mac. The Mac runs the
> agent and must remain awake with NativeAgent open for live chat and actions.
>
> Mac download: [PUBLIC_MAC_DOWNLOAD_URL]
> Compatible versions: iOS [IOS_VERSION_AND_BUILD], Mac [MAC_VERSION_AND_BUILD].
> Provider setup for review: [REVIEW_PROVIDER_SETUP].
>
> 1. Install both apps and use the same Apple Account on both devices.
> 2. Complete Mac onboarding and provider setup.
> 3. Open Connectors → iPhone in the Mac rail and Pair with Mac on the phone.
> 4. Wait for the pairing key, using Check for Mac if needed, then tap Connect.
> 5. Match the phone's displayed code to the waiting device on the Mac and
>    choose Pair. Tap Connect on the phone again.
> 6. Send a short chat message and confirm the reply in that conversation.
>
> Skip on the pairing screen permits entry to the shell; it does not provide
> an independently running agent.
>
> Review contact: [APP_REVIEW_CONTACT_DETAILS].

## Archive and submission

`script/ios_release.sh` provides local readiness, archive and export steps:

```sh
./script/ios_release.sh --preflight
./script/ios_release.sh --archive --export
```

It regenerates the Xcode project and checks signing/account prerequisites.
It does not upload or submit to App Store Connect. Its exit codes distinguish
local/source blockers (2) from missing account material (3).

Before submission:

- Resolve and record the companion-design review decision described above.
- Confirm identifiers from `iOS/NativeAgentMobile/Config/CanonicalIdentifiers.xcconfig`:
  `io.github.embwl0x.nativeagent.ios` and
  `iCloud.io.github.embwl0x.nativeagent`.
- Check production CloudKit/APNS entitlements, provisioning, version/build,
  privacy manifest and extension packaging in the exact archive.
- Use the compatible CloudKit-entitled Mac build; a
  `NATIVEAGENT_PUBLIC_DEVICE_SYNC=none` Mac artifact is standalone.
- Build, install and check the requested flows on the actual paired apps.
  For this release, verify pairing and a chat round trip; include sharing,
  approval or notification behavior when those areas changed.
- Capture current iPhone/iPad screenshots with generic data and no pairing
  keys, private conversations or credentials. Use the current Chat, Activity,
  Memories, Desk and More screens.
- Finalize listing, questionnaire answers, review contact/setup, hosted links,
  and the account owner's upload/submission decision.

Mac packaging: [Release setup](release_setup.md). Companion behavior:
[Mobile companion](mobile_companion.md), [Sharing](ios-sharing.md) and
[APNS push](apns-push.md).
