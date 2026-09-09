# NativeAgent Chrome Control

Manifest V3 extension for NativeAgent's real-Chrome surface. It connects to
the native-messaging host `com.nativeagent.chrome`, creates inactive agent
tabs in a purple NativeAgent group beside the user's tabs in their existing window,
can claim an exact user tab, and yields its lease when the user touches
or activates that tab.

Tab leases are now real, bounded, renewable, persisted in
`chrome.storage.session`, and recovered across Manifest V3 service-worker
restarts. Physical pointer, keyboard, wheel, touch, or tab-activation evidence
terminally yields the lease without closing the tab. The extension never
activates an agent-created tab.

The first group is placed in the last-focused normal Chrome window, without
selecting a tab or focusing a window. Later work reuses the exact group's live
window, including after worker restart. After an extension reload clears session
storage, the sole group named NativeAgent in the current normal window is reused
for presentation only; existing tabs are never claimed. Multiple matching groups
refuse rather than guessing or adding a third. No separate hidden window or welcome
tab is created. User-renamed/collapsed groups are preserved. Explicit claims
stay where they are and are never grouped.

The pinned public key in `manifest.json` gives development builds stable
extension id `egdbijiogeeggnmjheomgnnkhmlepfcn`. Host registration and key
rotation instructions live in `native-host/README.md`.

The Swift `NativeAgentChromeRelay` executable provides transport from Chrome's
framed stdin/stdout to NativeAgent.app's owner-only Unix socket. The relay
contains no policy, lease, Trust Center, receipt, or verification authority.
NativeAgent.app opens and registers that path only while the default-off
**Chrome control** Trust Center switch is enabled, and rechecks the policy at
every browser effect.

Navigation, structured page snapshots, snapshot-scoped node clicks, fill,
sequential type, bounded element/navigation waits, and page or element
scrolling are implemented, together with select, bounded keypress,
checked-state, and double-click. The snapshot walker aggregates every permitted
frame and recursively includes open shadow roots, while unavailable frames and
closed roots stay explicit. Every act accepts only a current node that
advertised the exact action; password nodes advertise no actions. Every form
act returns one outcome receipt, and a lost page reply becomes
`outcome_unknown` with no automatic retry. The content agent exposes a bounded
read model rather than raw HTML, invalidates node ids after page mutation, and
runs in inactive tabs without requesting Chrome debugger or arbitrary
scripting permission.

Feed snapshots retain article/container hierarchy and parent node IDs while
omitting layout-only wrappers. Repeated controls can be identified by their
article, not guessed by index. Accessible names resolve `aria-labelledby`
inside the element's own document/shadow root and are rechecked before actions.
Mutation freshness and outcome-unknown rules remain unchanged.
Native modal dialogs retain their container identity; background nodes remain
readable but advertise no actions while a modal is open. Page-level scrolling
also requires a current target inside the modal rather than moving its backdrop.

Run the focused extension tests with:

```bash
node --test Extensions/NativeAgentChrome/tests/*.test.js
```

Run the relay framing tests with:

```bash
swift test --filter NativeAgentChromeRelayTests
```

In NativeAgent's Chrome control permissions, click **Set up Chrome**. When the
extension is bundled, this reveals the app's
`Contents/Resources/NativeAgentChrome` folder in Finder and opens
`chrome://extensions` in Google Chrome. Follow these three steps:

1. In Chrome, turn on **Developer mode** at `chrome://extensions`.
2. Click **Load unpacked**.
3. Select the **NativeAgentChrome** folder revealed in Finder. In the folder
   picker, press **Command-Shift-G** and paste the folder path shown by the app
   if needed.

Keep the app in its installed location: Chrome loads this folder in place.
Turn on **Chrome control** in NativeAgent and keep Chrome open. The switch
allows access; it does not install the extension or prove a connection.

If the bundled extension is missing or incomplete, **Set up Chrome** reports
that setup cannot continue. This action does not download extension files.
Install an app release that includes the extension. For a source checkout,
open `chrome://extensions` and use the same three steps, selecting
`Extensions/NativeAgentChrome` in that checkout instead. No source build is
needed to load those extension files. If Chrome cannot be opened automatically,
enter `chrome://extensions` in Chrome's address bar.

The app registers
the bundled host while Chrome control is enabled and removes the registration
when it is disabled. The installer script remains available for isolated relay
development. A disconnected extension retries the transport on a bounded
Chrome alarm, so changing the switch does not require stealing focus or
reloading the extension.
# Dynamic feed navigation

Unrelated feed mutations may retain an exact same-origin anchor inside a navigation
landmark for up to 60 seconds. Only click can use this retained address; its URL,
name, element, ancestor chain, page URL, visibility and enabled state must still
match. Changes inside the navigation landmark, ancestor attributes, removal,
user takeover, navigation, or an open modal require fresh evidence. Other actions
and feed controls keep whole-snapshot invalidation. This is not a stale-click retry
or selector guess: the page revalidates the original observed control synchronously.
