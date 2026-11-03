# NativeAgent Chrome surface

The Chrome `NativeAgent` tab group is the resident agent's workspace and ownership state.
Every other tab belongs to the person. Activation, the person's trusted pointer/keyboard/wheel/touch
input, or an address-bar navigation ungroups one of their tabs immediately and
stops their pending actions. App and extension restarts recover tabs directly
from the group. Nothing closes a tab except an explicit close of their own tab.

Each conversation remembers its last tab ID. Navigation reuses that tab while
it remains in the group. An explicit lost tab refuses without creating another;
release events and ownership refusals forget its remembered ID. A later navigation
without a tab creates an inactive grouped tab. A new window is created only after
a successful empty normal-window inventory. Reads and
page actions use their current tab or an explicit owned tab ID. Chrome group
membership is checked against Chrome before page dispatch. Page-changing actions
keep exact snapshot, document, element identity and user-sequence checks.

`background.js` owns requests and frame routing; `page-evidence.js` formats bounded snapshots and action receipts. `page-agent.js` retains one document closure and teardown.

`chrome.history` is an app-owned read under Full Mac and file-read admission for
`Google/Chrome/Default/History`, independent of extension connection or profile.
The extension has no history action or `history` permission. The app captures
that admitted Default profile's History plus any `-wal`/`-journal` in a private
temporary directory. File identity, size, modification and change times must
stay unchanged across the whole capture; a changing set refuses the read.
SQLite opens only that copy read-only; it is deleted on success or failure,
and cleanup failures are reported. Results name `source: "sqlite_snapshot"`.
Top-domain counts aggregate all qualifying visits since `since` before limiting
returned domains; there is no candidate-URL count cap. Search matches title or
URL case-insensitively. The copied SQLite query retains its two-second progress
deadline; that deadline does not bound filesystem I/O. Missing or unreadable
history and capture/query failures retain their cause; no other profile or
reader is attempted.

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
The reader is selected before capture, using the ready document's content type
and PDF embed evidence, or a minimal `document.contentType` read injected into
the exact top document when there is no ready DOM reader. Chrome filters its
extension viewer URLs from webNavigation; they cannot identify the PDF here.
The injected result must name the admitted document. No URL suffix or failed DOM
read selects a picture; missing document evidence stays a reader failure. DOM reads never
attach the debugger. PDF snapshots retain Chrome's `document.status: "unread"`
and explicitly report that document text is unavailable from the picture
reader. The picture is the verified Chrome view (`chrome_view_verified`
reports delivery); its URL, title and document classification come from Chrome.
Reading a PDF here makes no independent HTTP request. An explicit web read is
a separate source with its own receipt.
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
calls succeed with verified dimensions, byte size and encoded type,
`image_pixels:false`, and guidance to use Chrome's reader from a turn. They
never claim an image was displayed. Omit `tab_id` to look at this
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
bounded typing, navigation settlement and action outcome receipts. Prose rows
spend node, text and transport budgets together with every inline link's action
proof. A split advances its text offset; a budget too small for the next unit
refuses explicitly instead of returning the same continuation forever. HTTP(S) host access
is needed for page readers. Temporary debugger focus emulation remains available
for a hidden-tab scroll when the app confirms the person is away: infinite
feeds can require rendering before scroll callbacks load more content.

Text fill, type and every advertised keypress use Chrome's trusted input:
`Input.insertText` for text and `Input.dispatchKeyEvent` for keys and shortcuts.
Each key is one `keyDown` followed by `keyUp`. Printable keys carry `text` and
`unmodifiedText` on the keydown (Enter carries `"\r"`); nontext keys and
shortcuts omit text. Chrome generates the character and honors the editor's
`keydown.preventDefault()`. No separate `char` event is sent. One input sender
finishes custody, debugger attachment and focus-emulation waits before reading
the current frame/document identity. It compares that identity with the admitted
document and sends the event in the same continuation, with no intervening await,
including key-up settlement.
macOS editing commands use the complete [Playwright macEditingCommands table](https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/macEditingCommands.ts)
and Chromium's [Paste and Match Style accelerator](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/cocoa/accelerators_cocoa.mm).
Lookup uses the exact modifiers and physical key code in Shift/Control/Alt/Meta
order; absent entries send no command. `Meta+Shift+V` sends `pasteAndMatchStyle`,
while `Meta+V` sends `paste`. Multi-command bindings preserve their order. As in
Playwright, AppKit `insert*` selectors are excluded from CDP commands; text stays
on the combined keydown. Named keys include F5, NumpadEnter, Numpad5 and
NumpadSubtract so every key in the table can be addressed.
Chrome and the page's editor own editing, selection movement, submission and
scrolling. The page agent resolves the exact observed editing host, focuses it
once with `preventScroll`, places type at its end or selects its contents for
fill, then reads that same host after input. Existing rich-editor nodes survive
unless the editor itself changes them. One debugger attachment owns focus
emulation for the hidden tab and detaches in settlement. An attach or focus
failure never switches to synthetic keys, a DOM text writer or another tab.
The expected keydown of that request is consumed as agent input; unrelated
trusted input and activation still yield the tab.

Sequential text controls advertise type and fill. Atomic date/time/color/range/
file controls advertise fill, use their native value setter and input/change
events, and read back the result; only an empty file value is legal. Native
selects retain the exact-value select action. Checkboxes/radios activate with
one `click()` when a change is needed, then read their checked state.
An observed state that differs from the request stays in the result as a refusal;
an unreadable or replaced control remains unknown.
Text receipts distinguish `landed`, `changed_by_page` and `not_landed` with
bounded observed values. A legitimate rewrite remains changed evidence.
Acknowledged character counts are progress, not proof of retained text; uncertain
input is never replayed automatically. `cleanupError` preserves debugger detach
failure beside a completed effect or picture, through the Swift picture result.
Back/Forward reach only the exact neighboring history entry; attach failure
refuses, and Stop/takeover/supersession is checked again before navigation.

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

Setup, current reload status and reload settlement share the runtime's accepted
running-code/folder-code comparison: the registered folder and accepted running
version must equal the shipped version, and both code digests must be observed
and equal. Version equality alone proves no match. `chrome.status` exposes
`extension_code_matches_folder` as true, false, or null when identity is
unavailable, including while connected; successful prior reloads remain history
when current identity cannot verify them. Setup rereads the folder after copying
it. Automatic reload remains limited to an older running manifest version;
same-version code changes need an explicit reload.
