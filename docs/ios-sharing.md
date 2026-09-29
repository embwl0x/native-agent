# iOS Share extension

Share text, a URL, an image, or a PDF from another app. The system activity is
named **Share to NativeAgent**; its compose sheet says **Share to <agent name>**
using the latest name cached by the main app. Before the app learns a name, the
sheet uses NativeAgent. The system activity's bundle display name is static.

Add an optional note and tap **Save**, then **Done**. The confirmation asks you
to open NativeAgent. Opening the app selects Chat and transfers the saved item
to the current conversation's existing durable send queue. Pair or choose Skip
if initial setup is still visible. A paused queue stays paused; use its existing
Send/Retry control. A transport failure keeps the queue entry and attachments.
The extension does not launch the app or use CloudKit itself.

Storage is `ChatShareInbox/*.json` in the App Group container. The extension
atomically saves the item; the app checkpoints the normal send queue plus an
import receipt before deleting the handoff file. The same item UUID becomes the
chat correlation ID. Receipts prevent replay if interruption happens between
checkpoint and deletion. The normal phone composer transport remains unchanged.
Unreadable handoffs are moved intact into `ChatShareInbox/Unreadable` and reported
once while valid files continue importing. A queue removal or completed send
retries waiting imports when capacity returns, preserving paused-queue behavior.

Limits: four items per share, 20 waiting shares, 64 KiB of combined text/note,
and 520 KiB of aggregate binary attachments. Images are resized and encoded as
JPEG through the same helper as the photo composer. Multiple binary items each
receive an equal portion of the budget. PDFs exceeding their budget are rejected
visibly, preserving the original document rather than truncating it.
Save also checks the codec's 800 KiB encoded-record ceiling, including base64,
JSON escaping and duplicated text, with 16 KiB reserved for send-time metadata,
session identity and signing. A share that exceeds this budget stays in the
sheet with a visible error.

## Apple developer portal setup (account owner)

On the same Apple Developer team as the existing iOS app:

1. Register the App Group `group.io.github.embwl0x.nativeagent.ios`.
2. Enable App Groups for the existing explicit App ID
   `io.github.embwl0x.nativeagent.ios` and assign that group.
3. Register the explicit extension App ID
   `io.github.embwl0x.nativeagent.ios.share`; enable App Groups and assign the
   same group. It needs no iCloud or Push Notifications capability.
4. Regenerate/download the app's development and distribution provisioning
   profiles with App Groups, and create corresponding profiles for the extension
   (or let Xcode automatic signing refresh/create them). Sign both targets with
   the same team. Preserve the app's existing iCloud and APNs entitlements.

Identifiers are centralized in `Config/CanonicalIdentifiers.xcconfig`; both
entitlements and Info.plists are generated from `project.yml`. No portal change,
physical-device installation, archive upload, or publication was performed.

## Build and simulator proof

From the worktree root:

```sh
command -v xcodegen >/dev/null 2>&1 || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen --spec iOS/NativeAgentMobile/project.yml &&
xcodebuild -project iOS/NativeAgentMobile/NativeAgentMobile.xcodeproj \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -scheme NativeAgentMobile -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios-share build
```

The app scheme embeds `NativeAgentShare.appex`. The generic simulator build
passed, including Swift 6 compilation of both targets. Installed and launched on
a fresh iOS 26.5 simulator named C7-Share; `simctl get_app_container ... groups`
confirmed the canonical App Group container. Screenshot:
`.build/c7-share-launch.png` (local, untracked).

The worker brief's additional `swift build --disable-keychain -j 6` did not
complete: GRDB's pinned SQLiteLib submodule download remained in dependency
setup. A shallow checkout retry failed with `unexpected disconnect`, `early EOF`,
and exit 143. Logs are `.build/share-swift-build.log` and
`.build/share-submodule.log`. No Mac source was changed. The external Agent
handoff file was not edited because this worker's brief restricts writes to its
own worktree; this document carries the task handoff.

The complete Safari-to-outbox interaction remains **unverified**: the available
computer UI service returned `cgWindowNotFound` for Device Hub and did not expose
a Simulator window. The fresh simulator also reports iCloud unavailable. No
fabricated inbox item, harness, or separate automated test was used as proof.

Manual completion steps:

1. Open the installed app, pair it for a delivered-message check, or tap Skip
   for the local retained-queue check. Visit Chat once to cache the agent name.
2. Open Safari to `https://example.com`, tap Share, then **Share to NativeAgent**
   (enable it under More if necessary).
3. Verify the compose sheet shows the URL and cached agent name. Enter
   `Safari share check`, tap Save, verify the saved confirmation, then Done.
4. Open NativeAgent. Chat should show that note and URL in its queued/sending
   message. Without pairing/iCloud, the normal send failure must retain the
   message for retry. With pairing, verify one Mac delivery and reply.
5. Reopen the app once: the same share must not create a second message.
6. As bounded follow-ups, share one small image and one PDF below 520 KiB; check
   their previews and attachments in Chat. Cancel one sheet and confirm it adds
   nothing. An oversized PDF must show an error rather than claim it was saved.

CloudKit delivery, image/PDF interaction, and physical-device provisioning still
need those manual checks. Review is handled separately per the worker request.

## Review fixes — 2026-09-26

The encoded-size check, per-file quarantine and capacity-triggered import retry
are implemented. The generic iOS Simulator build passed again for the app and
extension (`.build/c7share-fixes-ios-build.log`); no project regeneration was
needed. The brief's additional `swift build --disable-keychain -j 6` also passed
(`.build/c7share-fixes-swift-build.log`). This follow-up ran no tests, uploads or
installations. Runtime behavior
remains unverified. After a separately authorized install, check that an oversized
combined text/file share shows an error before Save succeeds; an unreadable
handoff is preserved and reported once while a valid sibling imports; and a
waiting share enters a full queue after one send finishes or is removed.
