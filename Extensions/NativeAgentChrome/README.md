# NativeAgent Chrome Control

Manifest V3 extension for NativeAgent's real-Chrome surface. It connects to
the native-messaging host `com.nativeagent.chrome`, creates inactive agent
tabs, can claim an exact user tab, and yields its lease when the user touches
or activates that tab.

Tab leases are now real, bounded, renewable, persisted in
`chrome.storage.session`, and recovered across Manifest V3 service-worker
restarts. Physical pointer, keyboard, wheel, touch, or tab-activation evidence
terminally yields the lease without closing the tab. The extension never
activates an agent-created tab.

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

Run the focused extension tests with:

```bash
node --test Extensions/NativeAgentChrome/tests/*.test.js
```

Run the relay framing tests with:

```bash
swift test --filter NativeAgentChromeRelayTests
```

For local inspection, open `chrome://extensions`, enable Developer mode, and
load `Extensions/NativeAgentChrome` as an unpacked extension. The app registers
the bundled host while Chrome control is enabled and removes the registration
when it is disabled. The installer script remains available for isolated relay
development. A disconnected extension retries the transport on a bounded
Chrome alarm, so changing the switch does not require stealing focus or
reloading the extension.
