# NativeAgent Mobile — App Store Submission Kit

This is a release-owner checklist and a set of editable App Store Connect
drafts. It does not claim that the app, Mac companion, support site, privacy
policy, CloudKit schema, or push environment has been published.

Replace every bracketed placeholder and verify every answer against the exact
Apple-signed archive before submission.

Apple references used by this checklist:

- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Review](https://developer.apple.com/app-store/review/)
- [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)

## Product positioning

NativeAgent Mobile is a companion to the NativeAgent Mac app. It is not a
standalone hosted AI service. The paired Mac owns the selected model provider,
conversation, memory, tools, approvals, and durable outcomes. The mobile app
provides signed chat, continuity, activity, approvals, notifications, and
remote control through the user's private Apple account.

This dependency must be clear in the listing and Review Notes. The Mac download
available to App Review must be the production-entitled CloudKit build that
interoperates with the submitted iOS binary.

### Guideline 4.2.3 submission risk

Apple's current minimum-functionality guideline says an app should work on its
own without requiring another app to be installed. NativeAgent Mobile is
intentionally one surface of the Mac-owned agent, not a second iOS agent, so
live conversation and actions require the Mac. Do not hide this dependency or
ship a fake independent-agent/demo implementation. Before App Store submission,
obtain an App Review position on this companion design or make the unpaired iOS
experience independently useful without creating a second mind. TestFlight can
be used while that product/review decision is unresolved.

## App Store metadata drafts

### Name

`NativeAgent`

### Subtitle

`Your Mac agent, on iPhone`

### Promotional text

`Continue conversations, review activity, and securely direct your NativeAgent Mac from iPhone or iPad.`

### Keywords

`AI,assistant,Mac,companion,chat,workflow,memory,productivity,notifications,remote`

Recheck localization and App Store Connect character limits before entry.

### Description

> NativeAgent Mobile keeps you connected to the personal agent running on your
> Mac.
>
> Continue conversations from iPhone or iPad, follow streamed progress, review
> activity and approvals, inspect memories and skills, track Workshop tasks,
> and receive notifications when something needs attention.
>
> NativeAgent is local-first. Your Mac owns the agent runtime, the model
> provider you choose, memory, tools, trust policy, and durable work. The mobile
> app communicates with that Mac through signed messages in your private Apple
> account. It does not create a second cloud-hosted agent.
>
> Features include:
>
> - signed chat and session continuity;
> - streamed progress, cancellation, and photo attachments;
> - Activity, approvals, memories, Skills & Tools, and Workshop views;
> - provider, model, reasoning, and permission controls;
> - system, light, and dark appearance;
> - iPhone and iPad layouts; and
> - lock-screen notifications for paired activity.
>
> Requires a compatible NativeAgent Mac installation, iCloud, and a
> user-configured supported AI provider on the Mac. Provider subscriptions,
> usage charges, and service terms may apply. The Mac must be available to
> process new work.

### Category

Recommended primary category: `Productivity`

Candidate secondary category: `Utilities`

Choose the final categories in App Store Connect based on the marketed feature
set at submission time.

### URLs and ownership fields

- Marketing URL: **https://nativeagent.app**
- Support URL: **https://nativeagent.app/support**
- Privacy Policy URL: **https://nativeagent.app/privacy**
- Mac companion download URL: **https://nativeagent.app**
- Copyright: **[PUBLIC_COPYRIGHT_HOLDER_AND_YEAR]**
- App Review contact name: **[APP_REVIEW_CONTACT_NAME]**
- App Review phone: **[APP_REVIEW_CONTACT_PHONE]**
- App Review email: **[APP_REVIEW_CONTACT_EMAIL]**

Do not use a repository-relative Markdown file as the App Store privacy URL.
Host the final policy at a stable public HTTPS address.

## App Privacy recommendation

Recommended App Store Connect answer for the official build:

**Data Not Collected**

That answer is appropriate only while all of these remain true:

- the project operator has no analytics, advertising, account, crash-report,
  or model-proxy backend receiving app data;
- personal records use the user's local devices and private iCloud/CloudKit
  database;
- model/provider traffic goes directly from the user's Mac to the provider the
  user selected;
- optional connector traffic goes directly to the service the user connected;
  and
- support diagnostics are sent only when the user deliberately shares them.

App Store privacy disclosures concern data collected by the developer and its
third-party partners, not every item processed transiently on-device. However,
re-run the questionnaire if the release adds hosted push routing, analytics,
automatic crash reporting, a developer-operated account service, or any SDK
that receives user/device data. Apple's definition of collection and its
third-party-partner guidance win if this recommendation ever conflicts with
the current App Store Connect questionnaire.

The public privacy policy must still explain local processing, private iCloud
sync, selected providers, connectors, Apple Push Notification service, device
permissions, optional support submissions, retention, and deletion.

## Permission and capability inventory

Verify the final archive contains only active declarations:

| Capability | Purpose shown to the user |
|---|---|
| Microphone | Capture push-to-talk dictation |
| Speech recognition | Convert the user's speech to chat text |
| Photo library | Attach user-selected images to chat |
| Notifications / remote notification | Present paired activity and wake the app for signed sync |
| iCloud documents and key-value store | Compatibility sync and pairing state |
| CloudKit private database | Signed message, snapshot, and receipt transport |
| Time-sensitive notifications | Deliver user-enabled urgent paired activity through Focus where allowed |

The current app does not need camera or local-network permission declarations.
Recheck that statement against the submitted binary.

## Age-rating notes

Complete Apple's current age-rating questionnaire from actual shipped behavior:

- no gambling, contests, loot boxes, dating, or public social network;
- no public user-generated-content feed;
- no in-app purchases in the current build;
- the app is not intended for children;
- AI/provider output and retrieved external content can contain mature,
  offensive, medical, or other sensitive material depending on user requests
  and provider controls; and
- NativeAgent is not marketed as medical, legal, financial, emergency, or
  safety-critical advice.

Use the rating produced by the questionnaire and consider an upward age-rating
override if the connected-provider experience warrants it. Do not claim a
specific final rating until App Store Connect evaluates the completed answers.

## Export compliance

Recommended answer:

`ITSAppUsesNonExemptEncryption = NO`

Rationale: the app uses Apple-provided platform encryption for HTTPS, iCloud,
CloudKit, Keychain, and APNS. Its direct cryptographic operation is
CryptoKit-based HMAC-SHA256/SHA-256 for message authentication, integrity,
deduplication, and fingerprints; it does not implement a custom general-purpose
encryption product.

Confirm this answer against the final source and Apple's then-current export
guidance. If non-Apple encryption, VPN functionality, encrypted file transfer,
or another cryptographic feature is added, reassess before submission.

## App Review notes draft

> NativeAgent Mobile is a companion to the NativeAgent Mac application. The Mac
> app is required for the full experience because it owns the agent runtime,
> user-selected model provider, memory, tools, and approvals.
>
> Mac companion download: [PUBLIC_MAC_DOWNLOAD_URL]
>
> Review build compatibility: iOS build [IOS_BUILD_NUMBER] pairs with Mac
> version [MAC_VERSION_AND_BUILD]. Both builds use the production
> `iCloud.io.github.embwl0x.nativeagent` CloudKit container and production APNS
> environment.
>
> Pairing steps:
>
> 1. Install and launch the Mac companion on a Mac signed into the same test
>    Apple account used on the iPhone or iPad.
> 2. Complete Mac onboarding and configure the review provider using
>    [REVIEW_PROVIDER_SETUP_OR_CREDENTIAL_INSTRUCTIONS].
> 3. In the Mac app, open Settings → Pair iPhone / iPad.
> 4. Launch NativeAgent Mobile. Wait for the signed pairing material and choose
>    Connect via iCloud.
> 5. If iCloud propagation is delayed, reveal the manual pairing key on the Mac
>    and paste it into the mobile pairing screen. Treat this key as a secret.
> 6. Send a chat message. The Mac performs the provider turn and returns signed
>    progress and the final response through private CloudKit.
>
> No developer account is required by the mobile app. [STATE WHETHER APP REVIEW
> NEEDS TEMPORARY PROVIDER CREDENTIALS, AND SUPPLY THEM ONLY IN THE PRIVATE APP
> REVIEW FIELD—NEVER IN SOURCE OR PUBLIC NOTES.]
>
> To inspect without pairing, tap Skip on the pairing screen. Read-only shell
> screens may be visible, but live chat/actions require the Mac.
>
> Contact for review: [APP_REVIEW_CONTACT_NAME], [APP_REVIEW_CONTACT_PHONE],
> [APP_REVIEW_CONTACT_EMAIL].

Before submission, test these instructions from scratch. App Review must not be
sent to a private URL, an expired DMG, a standalone/no-sync Mac build, or setup steps
that depend on the developer's personal Apple account.

## Screenshot checklist

Capture from the exact Release candidate with generic demo data, no personal
names, secrets, email addresses, tokens, file paths, or real conversation
history. Never show the pairing QR code or key.

Prepare the current App Store Connect-required sizes for both iPhone and iPad.
At minimum, cover both appearance families:

### iPhone

- Light: Chat with a short, polished response and visible continuity.
- Dark: Activity showing a safe approval or completed outcome.
- Light: Skills & Tools with the two-page control and useful catalog rows.
- Dark: Workshop or Memories with realistic generic content.
- Light or dark: Settings showing paired Mac health and appearance controls.

### iPad

- Light: Chat in the full iPad layout.
- Dark: Activity/approval detail using the larger canvas.
- Light: Skills & Tools.
- Dark: Workshop, Memories, or organism status.
- Light or dark: paired Settings and Mac health.

Also capture:

- unpaired first launch for Review documentation, but not necessarily the
  marketing set;
- Dynamic Type and accessibility checks as QA evidence;
- notification appearance on a physical device as QA evidence, without exposing
  private lock-screen content; and
- landscape only if it is visually deliberate and useful.

Check every image at full resolution for clipped text, debug labels, stale
timestamps, test-provider names, private paths, and low-contrast controls.

## Production submission gate

- [ ] App record, bundle ID, SKU, version, build number, category, and
      availability are final.
- [ ] The App Store record uses `io.github.embwl0x.nativeagent.ios`, the
      Developer ID Mac app uses `io.github.embwl0x.nativeagent.mac`, and both
      use `iCloud.io.github.embwl0x.nativeagent`.
- [ ] The Guideline 4.2.3 companion-app risk has an explicit App Review/product
      decision; the submission does not pretend the Mac-owned agent runs on iOS.
- [ ] Every placeholder in this document, `PRIVACY.md`, and `SUPPORT.md` is
      replaced on the hosted public pages or private App Review fields.
- [ ] Agreements, tax, banking, and Apple Developer roles are current where
      applicable.
- [ ] Distribution certificate and App Store provisioning resolve the intended
      team and bundle ID.
- [ ] Release archive is built with the currently required Xcode/iOS SDK.
- [ ] Archive validation passes and the uploaded build finishes App Store
      processing.
- [ ] `PrivacyInfo.xcprivacy` is present in the final archive and the generated
      privacy report matches the source inventory.
- [ ] `ITSAppUsesNonExemptEncryption` and export-compliance answers are verified.
- [ ] Production entitlements contain the intended iCloud container, CloudKit,
      production APNS, and time-sensitive notifications.
- [ ] CloudKit development schema is deployed to production and a clean
      production container/account test passes.
- [ ] The exact notarized Mac review/download build uses the same production
      container and message contract.
- [ ] Fresh-account pairing succeeds without private developer state.
- [ ] Chat, streaming progress, cancellation, attachments, approvals,
      notifications, offline recovery, force-quit recovery, re-pair, and Mac
      restart are verified on physical devices.
- [ ] TestFlight internal and external review smoke tests pass.
- [ ] App Privacy, age rating, content rights, and review notes are complete.
- [ ] Screenshots and optional preview media contain only generic demo data.
- [ ] Support and privacy URLs are live over HTTPS and readable without login.
- [ ] The version's release notes describe real user-visible changes.

## Mac companion release gate

The website build paired with this iOS release must independently pass:

- scrubbed public export and identity/secret scans;
- clean public source revision and public commit identity;
- Developer ID signing, hardened runtime, and notarization;
- stapled app ticket and mounted-DMG verification;
- Sparkle EdDSA signing plus a live public appcast;
- fresh-Mac install, first launch, onboarding, permission prompts, update check,
  and uninstall/reinstall checks; and
- production iCloud/CloudKit entitlements when advertised as compatible with
  NativeAgent Mobile.

Advertise Mac/iPhone continuity only after the CloudKit-entitled Mac lane is
proven with this exact iOS build. A `NATIVEAGENT_PUBLIC_DEVICE_SYNC=none`
artifact must be described as standalone.
