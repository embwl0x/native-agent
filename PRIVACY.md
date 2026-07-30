# NativeAgent Privacy Policy

**Effective date:** July 28, 2026

NativeAgent is a local-first personal agent for macOS with an optional iPhone
and iPad companion. The Mac app owns the agent runtime. The mobile app connects
to that Mac through the user's private Apple account; it is not a separate
hosted agent.

This policy describes the official NativeAgent applications distributed by the
project. A modified build may behave differently, so review the source and the
publisher's policy before using a third-party build.

## What the project operator collects

The official apps do not include developer-operated advertising, analytics,
behavioral profiling, or cross-app tracking. The project operator does not
receive a copy of conversations, memories, files, credentials, tool results,
or usage telemetry merely because the apps are installed or used.

NativeAgent does maintain local diagnostics, receipts, and bounded runtime
telemetry on the user's own devices. These records support operation,
verification, and troubleshooting; they are not automatically uploaded to the
project operator.

If a user voluntarily sends a support report, bug report, crash report, or
other material, the project operator receives the information the user chooses
to include and uses it to respond to the request. Users should remove private
conversation content, credentials, and personal files before sharing a support
bundle.

## Data processed on the user's devices

Depending on enabled features, NativeAgent may store or process:

- conversations, session summaries, attachments, and generated content;
- persona settings, memories, skills, preferences, and relationship context;
- tool inputs and outputs, approvals, receipts, task state, and diagnostics;
- provider selection and non-secret connection status;
- OAuth tokens, API keys, connector credentials, and device-pairing material;
- the files and work products the user asks the agent to read or create; and
- notification-delivery and device-sync state.

The Mac stores its canonical runtime data locally. Sensitive credentials use
the macOS Keychain where implemented or owner-only local files. Mobile pairing
material is kept in protected app storage and the Apple account's private sync
plane.

## User-selected AI providers and external services

NativeAgent does not provide a hosted model service. The user selects and
connects an AI provider. When a request uses that provider, the content needed
for the request can be sent directly from the Mac to the selected provider.
That can include conversation text, relevant context, attachments, and bounded
tool results. The provider processes that data under its own terms and privacy
policy.

The same principle applies to optional connectors and tools. If the user
connects services such as email, calendar, messaging, source control, document
services, search, or social platforms, NativeAgent sends and receives only the
data required for the requested operation. Those services are independent
data controllers with their own policies.

NativeAgent can also open websites or retrieve external content. Requests made
to those sites may disclose ordinary network information such as the user's IP
address and user agent to the site operator.

## iCloud, CloudKit, and notifications

When Mac/iPhone continuity is enabled, signed messages, compact snapshots,
pairing state, action receipts, and related records move through Apple iCloud
Key-Value Store, iCloud Drive, or the app's CloudKit private database. These
records are associated with the user's Apple account and are governed by
Apple's terms and privacy policy. NativeAgent does not use a public CloudKit
database for personal agent data.

Apple Push Notification service may process a device token and bounded
notification payload so the iPhone or iPad can be notified of new activity.
Notification previews can reveal content on a locked device according to the
user's iOS notification settings.

The mobile companion requires a compatible Mac build signed for the same
production iCloud/CloudKit container. A standalone direct-download Mac build
without those entitlements cannot provide mobile pairing or continuity.

## Device permissions

NativeAgent requests access only when a corresponding feature needs it.
Permissions can include:

- microphone and speech recognition for push-to-talk dictation;
- photo-library access for user-selected chat attachments;
- notifications for alerts and background delivery;
- Calendar, Reminders, Contacts, Mail, Messages, Notes, Music, Accessibility,
  Screen Recording, or Automation on the Mac when the user enables the
  corresponding integration.

Permission prompts are controlled by Apple. Access can be reviewed or revoked
in System Settings on the Mac or Settings on iPhone/iPad. Revoking a permission
can disable the related feature without deleting previously created local
records.

## Tracking, advertising, and sale of data

NativeAgent does not use advertising identifiers, does not track users across
other companies' apps or websites, and does not sell personal information.

## Retention and deletion

NativeAgent retains local data until the user removes it, an enabled retention
rule expires it, or a bounded subsystem consolidates it. Removing a memory or
conversation does not necessarily erase an independently created external
record, provider log, exported file, backup, or previously delivered message.

To disconnect the mobile companion, use **Settings → Re-pair** on iPhone or
iPad and regenerate the pairing key on the Mac. To remove mobile local data,
delete the iOS/iPadOS app after disconnecting it. Apple may retain app data in
iCloud or device backups until the user removes it through the applicable
Apple account or backup controls.

To remove Mac data, quit NativeAgent, remove the app, and delete its NativeAgent
folder under the user's Application Support directory together with any
NativeAgent workspace files the user no longer wants. Source-based development
installs may instead keep runtime data and work products inside the checkout.
Remove related iCloud Drive/CloudKit data and revoke provider or connector
credentials separately. Provider-side records must be deleted through the
provider.

Because deletion is consequential and install layouts can differ, consult the
[support guide](SUPPORT.md) before removing data. Keep any backup the user wants
before deletion.

## Security

NativeAgent uses signed device messages, local trust and approval boundaries,
and Apple platform protections, but no software can guarantee absolute
security. Broad Mac permissions and autonomous tool access increase risk.
Review [SECURITY.md](SECURITY.md) and grant only the access appropriate for the
installation.

## Children

NativeAgent is a general productivity tool and is not directed to children.
Model and external-service output can vary based on the services a user
connects.

## Changes

Material policy changes will be published with a new effective date in the
official project repository and release materials.

## Contact

Privacy and security questions:
**https://github.com/embwl0x/native-agent/security/advisories/new**

Official privacy-policy URL for App Store Connect:
**https://nativeagent.app/privacy**
