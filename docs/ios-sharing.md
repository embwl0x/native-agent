# iOS Share extension

Share text, a URL, an image or a PDF from another app using **Share to
NativeAgent**. The compose sheet uses **Share to [agent name]**, from the name
cached by the main app, or NativeAgent before one is available.

Add an optional note, tap **Save**, then **Done**, and open NativeAgent. The app
selects Chat and imports the item into the selected conversation's durable send
queue. A paused queue stays paused. The extension saves locally; it does not
launch NativeAgent or send through CloudKit itself.

## Storage and limits

Handoffs are atomic `ChatShareInbox/*.json` files in the App Group container.
The app checkpoints its send queue and import receipt before deleting a
handoff; the share UUID becomes the queued message ID. Unreadable files are
moved intact to `ChatShareInbox/Unreadable` and reported while valid files
continue importing. Queue capacity becoming available triggers another import.

| Limit | Value |
|---|---|
| Items per share | 4 |
| Waiting shares | 20 |
| Combined text and note | 64 KiB UTF-8 |
| Binary attachments combined | 520 KiB |
| Encoded bridge record | 800 KiB, including a 16 KiB reserve for send metadata |

Images use the photo composer's JPEG preparation helper. Binary items split
the attachment budget equally. Oversized PDFs and encoded records fail visibly
before Save succeeds; PDFs are not truncated.

## Apple developer portal setup (account owner)

The configured identifiers are:

- app: `io.github.embwl0x.nativeagent.ios`;
- extension: `io.github.embwl0x.nativeagent.ios.share`;
- shared App Group: `group.io.github.embwl0x.nativeagent.ios`.

Register the group and assign it to both App IDs on the same team. Provision
both targets with that group, preserving the main app's other capabilities.
The Share extension's entitlement file requests only the App Group.

Identifiers live in `iOS/NativeAgentMobile/Config/CanonicalIdentifiers.xcconfig`.
`iOS/NativeAgentMobile/project.yml` generates the project, entitlements and
Info.plists and embeds `NativeAgentShare.appex` in the app.

## Build and installed check

Generate the project before building the app:

```sh
xcodegen --spec iOS/NativeAgentMobile/project.yml
xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -scheme NativeAgentMobile -destination 'generic/platform=iOS' build
```

Install the resulting app on the intended device. Share one Safari URL with a
short note, save it, then open NativeAgent. Confirm the queued message retains
both, and that reopening does not import it twice. With a paired Mac, confirm
delivery in that conversation. Check one image or PDF when changing attachment
handling; a saved handoff alone does not prove delivery.

Source: `ShareExtension/ShareViewController.swift`, `Shared/SharedChatInbox.swift`,
`Shared/MobileChatAttachmentPreparation.swift`, and
`Sources/ChatStore+SharedInbox.swift`, all under `iOS/NativeAgentMobile/`.
