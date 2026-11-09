# NativeAgent Chrome surface

The Chrome `NativeAgent` tab group is the resident agent's workspace and ownership state.
Every other tab belongs to the person. Activation, the person's trusted pointer/keyboard/wheel/touch
input, or an address-bar navigation ungroups one of their tabs immediately and
stops their pending actions. App and extension restarts recover tabs directly
from the group. Nothing closes a tab except an explicit close of their own tab.

Each conversation remembers its last tab ID. Navigation reuses that tab while
it remains in the group. `chrome.navigate {url, new_tab:true}` opens another
inactive tab in that group and remembers it for this conversation; omit `tab_id`
and use a destination, not back/forward. No existing tab or focus is moved.
An explicit lost tab refuses without creating another;
release events, ownership refusals and an accepted group inventory that no longer
contains it forget its remembered ID. A disconnected or replaced channel does
not clear tab memory. A later navigation
without a tab creates an inactive grouped tab. A new window is created only after
a successful empty normal-window inventory. Reads and
page actions use their current tab or an explicit owned tab ID. Chrome group
membership is checked against Chrome before page dispatch. Page-changing actions
keep exact snapshot, document, element identity and user-sequence checks.

`background.js` owns requests and frame routing; `page-evidence.js` formats bounded snapshots and action receipts.
`page-agent.js` is the isolated document reader; the extension never runs code in a page's own JavaScript world.
The reader exists only in their tabs. `background.js` puts it in each document committed in an owned tab and in the
documents a tab already holds when it becomes theirs, and it leaves when ownership ends; no other tab carries any of our code.
The reader enters open and closed web-component shadow roots through
`chrome.dom.openOrClosedShadowRoot`. Readiness, layout order, mutation observation
and action checks use those same roots; a component's root mode never selects another reader.

Chrome tab work also updates **Work → Screen** through the same transient
preview publisher as Mac work, once after the whole call settles. It shows a
masked, downscaled tab picture when capture is available without a new debugging
banner or focus change. Ordinary background DOM reads show the first screenful
of the returned text and structure instead, with the read's site/title and a
background-tab caption. Image and read text replace each other; calls with no
readable content show their honest unavailable state. The reader withholds
password/autocomplete-password/cc values in both the model read and this local
copy. The [local Screen preview contract](protocol/PROTOCOL.md#local-screen-preview)
owns capture permissions, masking, deadlines and retention. No preview frame
enters a tool result, model request, file or phone message. Explicit looks and
PDF/picture reads return Chrome's original JPEG with optional paint-out geometry,
never a second picture. The Mac paints that geometry onto its own copy before
downscaling for Screen; unavailable geometry means a caption alone.
The pane never changes the agent's picture or read failures and never takes a
second capture after their debugger lease ends.
Closing a tab clears its old picture and shows the settled close state.
Read previews also stay in memory and are never saved or sent to the phone.

`chrome.history` is answered by the bundled part `native-chrome-history`, whose
reach declares `computer_files` and `Google/Chrome/Default/History` only,
independent of extension connection or profile. The extension has no history
action or `history` permission. The part reads through the stem's
`host.files.query`, which queries a private read-only copy of the file and its
`-wal`/`-shm` and bounds rows and time (two seconds per query).
Results name `source: "sqlite_snapshot"`. Top-domain counts aggregate all
qualifying visits since `since` before limiting returned domains; there is no
candidate-URL count cap. Search matches title or URL ignoring case and
diacritics. Missing history reads as `status: "absent"`; other failures retain
their cause; no other profile or reader is attempted.

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

An HTML document arrives through the first of two observations: readable prose in
the reader's main/feed/article regions, or document network completion.
`page-load.js` projects the document's evidence for navigation, explicit reads
and passive news. A MutationObserver record asks the page agent for a content check, without
animation frames; checks are spaced by their own measured cost, so the walk takes
at most a twentieth of the page's time, and Chrome's loaded event checks at once.
Content presence requires
three qualifying prose blocks of at least 30 characters, or once the document's
readyState is complete, one such block or a content control. Headings,
navigation, page chrome and control labels do not count as prose; a visible
progress/progressbar in the content keeps the verdict busy. Open and closed
shadow-root content belongs in the same count and exclusions as captured prose.
An early shell can satisfy this rule before a later asynchronous feed renders;
arrival establishes content presence, not feed completion. The private document
query's busy flag describes that rule; DOM snapshots omit it. `rendering.loaded`
reports Chrome resource completion, which also does not establish feed completion.
A page with no readable prose has arrived when Chrome reports its document
loaded (webNavigation.onCompleted).
Main-world hooks are installed only at document start, so an existing page
without them has unknown network evidence until its next document navigation.
History and fragment navigation reset the current route's content and quiet
evidence. The page reader observes Navigation API `currententrychange` and
drains pre-route mutation records and counts only readable text added or changed
by later MutationObserver records. Attachment and unrelated attribute changes
cannot reuse prose already on screen; removal can clear the content verdict.
The arrival owner requires current-route content or observed requests draining,
so a preceding route's content verdict cannot admit a replacement shell.

The navigation watcher is armed before dispatch. Its current document must
match Chrome's frame and tab, with no pending URL. Navigation, DOM reads and
pictures have no app request deadline; arrival and frame-layout reads have no
timer. A navigation error, removal, replacement, takeover, newer navigation,
Stop or connection loss ends the relevant wait. Otherwise the tool remains
pending and Stop cancels it. A committed HTTP(S) PDF/image arrives by its exact
document MIME, including after worker restart without network history or prose.
Internal and other non-HTTP pages retain completed-tab evidence.
Resource completion remains separate in `status`, `verified` and
`rendering.loaded`. A read uses the selected document once with the existing
node, text, frame and transport budgets; required reader and storage failures
retain their causes. Unrelated tabs' reader installation cannot hold a read.

Navigation receipts carry `timings`: `dispatchedMs`, `committedMs`,
`contentPresentMs`, `documentLoadedMs`, and `readReturnedMs`, measured from
`startedAtMs` on the extension clock. Swift carries that origin into the
following read and attaches its collector-return time to the same receipt,
including the first form-batch read. Unobserved stages remain null, including a
workspace navigation with no readback or a readback refused by Trust. Times
measure events; they never decide readiness. Events preceding this navigation
retain null stage times. Each stage is recorded at its event and retained if a later stage
fails or the request is cancelled.
Content and network timestamps come from the document's clock; worker
reattachment preserves their original event times.

Chrome suppresses animation frames in background tabs and throttles their
timers ([Chrome policy](https://developer.chrome.com/blog/background_tabs)).
This reader does not request animation frames or change visibility. A site's
own hidden-tab rendering can therefore remain delayed; arrival receipts show
the evidence received, not a promise that every site's future scripts ran.

Only an explicit `page.wait` with `condition:"navigation_settled"` observes
content progress and readable prose. Its caller supplies the timeout and any
`settleMs` quiet interval (default zero); it never starts a snapshot capture.
Reader readiness still wakes that wait after asynchronous identity acceptance.

An iframe commit invalidates only that frame's action routes. An in-flight
capture keeps its top document and sibling content, marks page movement, and
removes routes from that frame even if its old reply is still in flight. A
changing or unready optional frame is a named gap; required top-document and
requested-continuation failures keep their causes. The `page.frame_invalidated`
event clears the Mac's cached aggregate without fencing a pending reply.
Only top-document replacement emits `page.invalidated` and fences the whole read.

A read starts at the current viewport and walks outward to nearby content
within its node, text and transport budgets, for both page and main-content
scopes. It never scrolls. A changing feed returns what was read with one note
that the page moved; it does not discard the read or retry it. Read-more places
name their tab, top document, frame and reading layer as well as scroll offset
and next rendered position, with text/option offsets for a split paragraph or
control. The returned `more` address needs no repeated `tab_id`. An unchanged
element and content anchor follows its moved position; a recycled or removed
row continues at the next current position. If the viewport or its scroller has
changed, reading starts from the current view and says the page moved.
Defaults are 400 nodes and 32,000 text characters; explicit limits reach 2,000
and 200,000, within the unchanged 1,000,000-byte snapshot transport window.
The extension protocol is the sole owner of default bounds. Direct snapshots,
navigation readbacks, workspace readbacks, current-tab controls and tab rooms
omit limits to use those same defaults, including on existing tabs; old read
sizes are not inherited. Workspace readbacks retain the captured page rather
than rereading a narrower scope when a limit is reached. Passive news retains
the most recently served view. The serialized view writer compares against
session storage and writes only a changed map; a failed read or write remains
a persistence failure and a later call checks storage again.
`find:"text"` starts at the first case-insensitive matching element in reading
order without scrolling; omit `more`. An unobserved match speaks only for the
bounded rendered walk. If the walk folds before a match, its continuation keeps
the search across frame boundaries. A top-document capture used only for page
identity cannot consume that search. Once found, normal read-more continues
from there. Side-by-side sibling boxes with substantial vertical overlap form
columns, including columns inside a single main landmark. The column with the
most readable prose in a bounded rendered walk comes first, then the others in
descending prose order (left to right on ties). Stacked siblings sharing a
column read together. Each column reads from the viewport outward, top to
bottom within each distance; its remaining prose precedes the next column.
This layout order travels in every position and anchor continuation, including
transport folds. No domain, class name or site-specific selector chooses it.
Outside column sets, navigation/complementary landmarks follow the main feed
within each frame. Column prose order takes precedence over landmark labels.
All frames' content is read before the overlay phase; dialogs spend
only the node, text and transport budget content leaves. The phase travels in
every continuation, including transport folds, so deferred covers are not lost.
A paged read reports `has_more` and `next`/`element_more`, preserving the
reader's exact offset-bearing continuation; budgets do not make it `partial`.
Only named unread parts in `summary.gaps` produce `status:partial`; each names
its frame, code and cause. There is no settled/unsettled field or label.
Workspace pages preserve the read without deriving a loading verdict from rendering metadata.
Missing or malformed gap metadata stays beside captured content as unknown
coverage, with its frame and raw evidence retained. It cannot discard the read
or establish a completed coverage verdict.
An embedding gap carries the cause observed by its parent; an absent cause
remains unknown.
An empty window or unobserved find reports `empty_window` without `ok:false`;
it establishes neither page-wide absence nor a failed read. That observation
is returned directly without asking a sense to invent missing material.

Visible dialog/alertdialog regions and fixed covers are read after the
content and labelled `overlay`; both scopes retain them.
The read header states once when content is behind a dialog, naming it from its
accessible name, visible heading or its own visible prose; rows do not repeat that label.
The captured `blockedByModal` flags and `blockingDialogs` names also explain
row-action refusals. An observed blocked, disabled, invisible or nonactionable
row is never `no_such_row`; an unobserved row says only that this read did not
show it. Fresh action checks still distinguish a detached node from one that
is now invisible, disabled or blocked, without dispatching the action.
Exact repeated text blocks in a read use `Same text as row N.`
after their first occurrence, preserving each later row's identity, states and
inline link targets. This compacts the served text, not the DOM capture budget.
Fixed coverage means at least 15% of the viewport, a half-width bar at least 24 px high, or a
half-height rail at least 80 px wide. The classification includes descendants
across open and closed shadow roots, and requires the browser's point stack to show page
content underneath the fixed element. A fixed or sticky feed used as page
layout is not itself a cover. A fixed body/document root used to lock scrolling is
still the page, not its covering dialog. It changes reading order, never consent or action
authority: nothing is clicked or dismissed. Embedded readers resolve their
embedding element by the parent/child Window identity, including across origins,
and inherit its cover classification. The layout observation ends on the
nonce-matched parent reply, request/capture cancellation or reader teardown.
A parent that cannot find the embedding element replies with that cause and
`frame_overlay_unavailable`; no missing reply is interpreted as uncovered.
Images, canvases and SVG graphics
have in-place names from alt/ARIA, caption or adjacent prose, and CSS size.
Caption/adjacent names use the same secure-field-aware text reader as the page.
Unnamed nondecorative graphics say so. Decorative/hidden/failed images remain
excluded. The read offers `chrome.look {tab_id}` for pixels; it contains none.

`main_content` reads visible declared main regions, else article bodies, else the
document body, excluding navigation through the same navigation filter in
every case. Visible modals remain included. `page` includes navigation too.
`reading.mainContentAvailable` reports whether a visible main or article region was
declared, even when the body supplies the main content.

`web.read` retains its bounded HTTP extraction and receipt. A successful read
that is thin or explicitly JavaScript-gated selects this Chrome door in another
background tab, through its normal gates, and says `used_browser:true` with the
browser receipt and page. The HTTP evidence stays under `http_read`, rather than
claiming it covered rendered content. Chrome replaces the top-level text only
when its served text has more non-whitespace characters than the selected HTTP
text, using the same count on both exact returned strings, including an authored
`sense_page` when that supplies the browser text. `text_reader` says `browser` or `http`; `used_browser` records
the attempt, not selection. Empty, shorter/equal or unmeasured browser reads
leave HTTP text at the top with partial status and the actual browser result
under `browser_read`; an empty read says `browser_read_empty` and retains its
window reason. A missing door or thrown read also retains top-level HTTP text.
Chrome may use the signed-in session.
HTTP transport/status/decoding failures do not select another reader. A missing
door or refused/unavailable Chrome read reports that cause with the HTTP
evidence retained; there is no automatic repeat. HTTP `find` selects passages;
the rendered route starts at its first matching element (`around` is HTTP-only).

The extension preserves structured DOM reading, frames, open and closed shadow roots,
position-based text/control continuations, form controls, links, page changes,
bounded typing, document arrival and action outcome receipts. Prose rows
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
The sender arms one expected keydown on the admitted, focused host before
dispatch. The page consumes that record against the exact focused element,
following open and closed roots, rather than its retargeted event path.
Unrelated trusted input and activation still yield the tab.

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
Reload and attach do not wait for those page readers. If the app listener is
launching, the authenticated relay waits on socket file events until a connect
succeeds, including the socket's metadata change after `listen`. Closing Chrome
cancels that wait; observation failure reports its cause. The reload id, attempt count and deadline live in
extension local storage, surviving extension reload and clearing when the attach
reply is queued on the native connection. A retained reload with no accepted reconnect
retries the extension reload once after ten seconds, within the existing
30-second bound. The accepted greeting reports the reload id, running version
and observed attempt count; the app still requires matching code digests.
If no greeting arrives, status retains the last accepted version/time,
handshake and extension error; after-version and retry count stay unknown.

`chrome.status.extension_code_matches_folder` compares exactly the printed
`extension_running_code` and `extension_files_code`: equal observed digests mean
true, different digests mean false, and either unavailable means null. The
shipped version is read from the app bundle's `NativeAgentChrome/manifest.json`;
it can differ from a separately updated registered folder or running extension.
Setup, current reload status and reload settlement use that same digest
comparison and additionally require the registered folder and accepted running
version to equal the shipped version on a tab-ready connection. Version equality
alone proves no match; successful prior reloads remain history
when current identity cannot verify them. Setup rereads the folder after copying
it. Automatic reload remains limited to an older running manifest version;
same-version code changes need an explicit reload.
