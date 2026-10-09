# NativeAgent Chrome surface

The Chrome `NativeAgent` tab group is Agent's workspace and ownership state.
Every other tab belongs to the person. Activation, trusted pointer/keyboard/wheel/touch
input, or an address-bar navigation ungroups one of them tabs immediately and
stops their pending actions. App and extension restarts recover tabs directly
from the group. Nothing closes a tab except an explicit close of them own tab.

Each conversation remembers its last tab ID. Navigation reuses that tab while
it remains in the group, otherwise creates an inactive grouped tab. Reads and
page actions use their current tab or an explicit owned tab ID. Chrome group
membership is checked against Chrome before page dispatch; snapshots, document
and element identity, and the user sequence guard against a changed page.

The extension preserves structured DOM reading, frames and open shadow roots,
folded text/control continuations, form controls, links, page changes, bounded
typing, navigation settlement and action outcome receipts. HTTP(S) host access
is needed for page readers. Temporary debugger focus emulation remains available
for a hidden-tab scroll when the app confirms the person is away: infinite
feeds can require rendering before scroll callbacks load more content.

The native messaging host is `com.nativeagent.chrome`. The relay transports
messages between the extension and the in-process NativeAgent runtime; it owns
no browser policy. See [protocol/PROTOCOL.md](protocol/PROTOCOL.md) and
[native-host/README.md](native-host/README.md).

Load this directory as an unpacked Chrome extension. NativeAgent includes the
native host registration and extension setup. Source deployment remains through
the project's normal build and install workflow. The manifest version is
managed separately from changes to these sources.

`chrome.reload_extension` reloads the installed extension through native
messaging. The next accepted connection enumerates the group and reinstalls
its existing page readers without navigating pages. The transport reconnect
alarm remains so an absent app or disconnected native host can recover.
