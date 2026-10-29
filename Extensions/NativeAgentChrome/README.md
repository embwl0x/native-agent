# NativeAgent Chrome surface

The Chrome `NativeAgent` tab group is Agent's workspace and ownership state.
Every other tab belongs to the person. Activation, trusted pointer/keyboard/wheel/touch
input, or an address-bar navigation ungroups one of their tabs immediately and
stops their pending actions. App and extension restarts recover tabs directly
from the group. Nothing closes a tab except an explicit close of their own tab.

Each conversation remembers its last tab ID. Navigation reuses that tab while
it remains in the group, otherwise creates an inactive grouped tab. Reads and
page actions use their current tab or an explicit owned tab ID. Chrome group
membership is checked against Chrome before page dispatch. Page-changing actions
keep exact snapshot, document, element identity and user-sequence checks.

`background.js` owns requests and frame routing; `page-evidence.js` formats bounded snapshots and action receipts. `page-agent.js` retains one document closure and teardown.

Navigation accepts HTTP(S), `chrome://`, `about:`, `file://` and `view-source:`
addresses, including PDFs. It observes `tabs.onUpdated` completion from before
dispatch and checks the landed URL on that exact owned tab; a DOM reader is
not required for `verified: true`. Unsupported schemes (including `javascript:`
and `data:`) and browser process commands such as `chrome://crash` refuse before
creating or moving any tab, with `effects: none` in the app's failure.

Chrome's internal pages (`chrome://`, `about:`) allow neither DOM reading nor
debugger capture. Both `chrome.snapshot` and `chrome.look` return the tab's URL
and title with `reading: {mode: "none", domAccessible: false, reason: "Chrome allows no reader on its internal pages"}`.
The app renders one line of text with `read_mode: "none"`, without attempting a picture.

For other pages without DOM access and Chrome's PDF viewer, `chrome.snapshot`
returns the displayed picture through the same image slot as `chrome.look`,
with `read_mode: "picture"` and an explicit reason that DOM text is unavailable.
PDF detection uses Chrome's MIME type or the page reader's document evidence,
not the URL suffix. HTTP PDF snapshots also retain the independent bounded HTTP
text read beside the picture in the same receipt. The picture is the verified
Chrome view (`chrome_view_verified` reports delivery); the text remains an
unverified transcript with `document.status: "unverified"`, source `http_pdf`,
and the original reason: "Independent HTTP PDF text; Chrome's displayed document has not been verified. Chrome cookies and authentication were not used."
The receipt keeps Chrome's URL/title beside the transcript's final URL, read
time, HTTP/extraction status and truncation. An HTTP or extraction failure is
reported in `document` beside the picture; it cannot substitute for the view.
An ordinary web page's missing reader remains a reader failure. Pictures retain
the same ownership, hidden-tab rendering and transport limits as `chrome.look`.

`chrome.look` reads the picture Chrome renders of an owned tab, including image
documents that have no DOM text. It never activates, focuses, raises, moves or
scrolls the tab and can run while the person uses the window. The debugger is
attached only for one JPEG capture; Chrome shows its debugging infobar during
that capture. Ownership is checked again before delivery. If Chrome cannot
paint a hidden tab, `tab_not_painted` says so; the tab is never activated to get
a picture. The capture is clipped to the viewport and scaled to at most 2048
device pixels on the long side; a JPEG above the image slot's 8 MiB is refused
explicitly.
NativeAgent delivers the picture through the same model-turn image slot as
`files.read`, bounded to 2048 pixels and retaining source dimensions. Text-only
calls say that no image slot is available. Omit `tab_id` to look at this
conversation's remembered tab; `guide:chrome.look` describes the action.

Chrome's global tab-strip lock is reported as `tab_strip_locked`, rather than
an internal extension error. A tab drag left unfinished in any Chrome window
can block tab APIs everywhere. Finish the drag or restart Chrome; repeating
the call does not clear it.

An ownership refusal keeps `tab_not_owned` and names its cause: the person
selected the tab (`tab_active`), it left the group (`outside_group` or
`group_changed`), or it no longer exists (`tab_missing`). The cause also travels
in the error's `details.reason`. A yielded event carries its URL and reason;
`chrome.status` retains the last eight released tabs with their event time and
URL for this app run, including across extension reconnects. This history is
diagnostic evidence; Chrome group membership still decides ownership.

A read starts at the current viewport and walks outward to nearby content
within its node, text and transport budgets, for both page and main-content
scopes. It never scrolls. A changing feed returns what was read with one note
that the page moved; it does not discard the read or retry it. Read-more places
retain the scroll offset and the next rendered position, with text/option
offsets for a split paragraph or control. A virtualized list can recycle its
nodes without deleting that position. If the viewport or its scroller has
changed, reading starts from the current view and says the page moved.

`main_content` reads visible declared main regions, else article bodies, else the
document body, excluding navigation through the same navigation filter in
every case. Visible modals remain included. `page` includes navigation too.
`reading.mainContentAvailable` reports whether a visible main or article region was
declared, even when the body supplies the main content.

The extension preserves structured DOM reading, frames and open shadow roots,
position-based text/control continuations, form controls, links, page changes,
bounded typing, navigation settlement and action outcome receipts. HTTP(S) host access
is needed for page readers. Temporary debugger focus emulation remains available
for a hidden-tab scroll when the app confirms the person is away: infinite
feeds can require rendering before scroll callbacks load more content.

After a checkbox or switch dispatch, a missing immediate state or changed
control identity is an unknown outcome. Observe before retrying; the action
receipt forbids automatic repetition, as it does for uncertain fill and select.

The native messaging host is `com.nativeagent.chrome`. The relay transports
messages between the extension and the in-process NativeAgent runtime; it owns
no browser policy. See [protocol/PROTOCOL.md](protocol/PROTOCOL.md) and
[native-host/README.md](native-host/README.md).

Load this directory as an unpacked Chrome extension. NativeAgent includes the
native host registration and extension setup. Source deployment remains through
the project's normal build and install workflow. The manifest version is
managed separately from changes to these sources.
Same-version JavaScript changes take effect only after `chrome.reload_extension`
on the deployed extension copy; an unchanged manifest version does not reload it.

`chrome.reload_extension` reloads the installed extension through native
messaging. The next accepted connection enumerates the group and reinstalls
its existing page readers without navigating pages. The transport reconnect
alarm remains so an absent app or disconnected native host can recover.
