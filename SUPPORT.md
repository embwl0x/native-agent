# NativeAgent Support

NativeAgent is a local-first personal agent for Apple platforms. The Mac app is
the runtime; the iPhone and iPad app are companions to a compatible Mac
installation.

## Official links

- Product/download page: **https://nativeagent.app**
- Support and issue form:
  **https://github.com/embwl0x/native-agent/issues/new/choose**
- Privacy policy: **https://nativeagent.app/privacy**
- Source repository: **https://github.com/embwl0x/native-agent**
- Release notes: **https://github.com/embwl0x/native-agent/releases**
- User and agent guide:
  **https://github.com/embwl0x/native-agent/blob/main/docs/USER_GUIDE.md**

## Requirements

### Mac

- Apple-silicon Mac
- macOS 14 or newer
- a user-selected supported AI provider
- user-granted permissions for any optional Mac integrations

### iPhone and iPad

- iOS or iPadOS 17 or newer
- the NativeAgent mobile app and a compatible NativeAgent Mac release
- both devices signed into the intended Apple account with iCloud enabled
- a Mac release signed for the same production iCloud/CloudKit container as
  the mobile app

The mobile app does not host an agent or call a model independently. Chat,
memory, tools, provider access, and policy remain on the paired Mac. If the Mac
is offline, mobile work remains pending or unavailable rather than silently
switching to another runtime.

## Install the Mac app

1. Download the current notarized disk image from the official product page.
2. Open the disk image and drag NativeAgent into Applications.
3. Launch NativeAgent from Applications and complete onboarding.
4. Connect a supported provider in **Settings → Providers**.
5. Grant only the Mac Integration permissions the user intends to use.

If macOS blocks the app, confirm the file came from the official download page
and that the release is signed and notarized. Do not bypass Gatekeeper for an
unknown or modified download.

## Pair iPhone or iPad

1. Install and launch NativeAgent on the Mac.
2. On the Mac, open **Settings → Pair iPhone / iPad**.
3. Keep both devices signed into the intended Apple account with iCloud enabled.
4. Launch NativeAgent on iPhone or iPad.
5. Choose **Connect via iCloud** after the signed pairing material arrives.
6. If iCloud propagation is delayed, reveal the pairing key on the Mac and
   paste it into **Manual pairing key** on the mobile device.
7. Treat the QR code and pairing key as secrets. Do not screenshot or share
   them.

If the mobile app remains unpaired, verify that the Mac build supports
production iCloud/CloudKit continuity. The standalone public Mac lane without
iCloud entitlements cannot pair with the App Store companion.

## Updates

Official direct-download Mac releases use a signed Sparkle update feed. Use
**Check for Updates…** in the app when that action is available. A development
or feedless build instead explains that automatic updates are unavailable.

iPhone and iPad updates are delivered by the App Store or TestFlight.

## Common problems

### The phone says the Mac is offline

- Keep NativeAgent running on the Mac.
- Confirm iCloud is available on both devices.
- Pull to refresh or use **Settings → Force Refresh from iCloud** on mobile.
- Confirm the pairing version matches and re-pair if the Mac key changed.
- Allow time for iCloud delivery after reconnecting from an offline state.

### A mobile action is waiting

Mobile actions require the Mac to receive, verify, authorize, execute, and
return a terminal receipt. Keep the Mac running and resolve any approval shown
there. Do not repeat the same consequential action while its original receipt
is still pending.

### Notifications do not appear

- Enable notifications for NativeAgent in iOS Settings.
- Confirm pairing is active and the Mac reports the phone as reachable.
- Check Focus, notification summary, lock-screen preview, and time-sensitive
  notification settings.
- A push is only a wake/delivery signal; durable iCloud state still needs to
  reach the phone.

### A provider or connector does not work

- Reopen **Settings → Providers** or **Connectors** on the Mac.
- Confirm the credential belongs to the selected provider and has the required
  scope.
- Review the provider's service status and account limits.
- Remember that provider, connector, and website availability are outside the
  NativeAgent project's control.

### A Mac permission is missing

Use **Mac Integration** in NativeAgent to request the permission, then review
**System Settings → Privacy & Security**. Calendar, Reminders, Contacts, and
other protected services each have separate Apple authorization.

## Reporting a problem

Include:

- NativeAgent version and build number;
- macOS/iOS/iPadOS version and device model;
- whether the issue is on Mac, iPhone, iPad, or device sync;
- the exact action and visible error;
- whether it reproduces after an ordinary app relaunch; and
- a redacted support snapshot when one can be produced safely.

Never post API keys, OAuth tokens, pairing keys, private prompts, personal
files, or unredacted support archives. Security vulnerabilities should follow
[SECURITY.md](SECURITY.md), not a public issue.

## Data removal

Before destructive cleanup, export any work the user wants to keep.

- On mobile, use **Settings → Re-pair** to clear the current pairing, then
  delete the app to remove its local app container.
- On Mac, quit NativeAgent before removing its Application Support data and
  workspace.
- Remove NativeAgent data from iCloud and device backups through the applicable
  Apple account/storage controls.
- Revoke or delete provider and connector credentials at the external service
  as well as locally.

Development/source installs can use a checkout-local data root. Confirm the
active storage location in the app before deleting anything.

## Support and safety limits

NativeAgent is provided under the MIT License without warranty. It can invoke
models and, when authorized, tools that affect files, applications, accounts,
and external services. TrustCenter and approval checks reduce risk but do not
make model output infallible or the shell a security sandbox.

Keep backups, verify consequential results, use the least authority practical,
and do not rely on NativeAgent as the sole control for emergency, medical,
legal, financial, or safety-critical decisions.
