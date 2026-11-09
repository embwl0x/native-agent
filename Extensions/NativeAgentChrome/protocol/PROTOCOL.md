# Chrome control protocol v1

Native messaging host: `com.nativeagent.chrome`. Messages are JSON objects with
`version: 1`, `type`, and a bounded stable request `id`. A request supplies
`action` and `payload`; its response repeats `id` and `action`, supplies `ok`,
and contains either `result` or `{code, message, details?}` in `error`.
Events supply `event`, `occurredAt` and `payload`.

In shared error normalization, Chrome's message `Tabs cannot be edited right
now (user may be dragging a tab)` is mapped once to `tab_strip_locked`. It names
the unfinished drag in some Chrome window and says it clears when the drag
ends or Chrome restarts. All other errors retain their own code or the explicit
`internal_error` message. Navigation also uses this normalization so a refused
tab API is not reported as a lost navigation reply or retried through history;
the app advises against repeating a locked call.

The Chrome `NativeAgent` group owns tabs. Tabs outside that group belong to
User. Every read or action checks the tab's current Chrome group. The person's trusted input,
activation, and address-bar navigation immediately revoke control and ungroup
that tab. Group membership survives app, service worker and extension restart.
Only an explicit `tab.close` request closes an owned tab.

`tab_not_owned` is stable across all ownership refusals. Its message and
`error.details.reason` name the known cause: `tab_active` when the person
selected it, `outside_group` or `group_changed` when it left NativeAgent's
group, and `tab_missing` when Chrome reports no such tab. The workspace keeps
the release cause beside its user sequence until the tab is owned again or
closed; later requests do not erase the reason with a generic refusal. Other
Chrome lookup errors propagate instead of pretending that a tab is missing.

| Action | Payload | Behavior |
| --- | --- | --- |
| `attach` | Optional `clientName`, `clientVersion` | Returns `connected: true`, host/protocol/extension identity, `capabilities`, `lastExtensionError`, and `tabs` with `tabId`, `windowId`, `groupId`, `title`, `url`, `userSequence`. Reinstalls the existing readers in grouped tabs. |
| `extension.reload` | `reloadId` | Retains the id, attempt count and 30 s reconnect bound in extension local storage so they survive reload, acknowledges `reloadId`, `beforeVersion`, `status: "acknowledged"`, drains accepted requests and queues their replies, then reloads. With no accepted attach after 10 s, reloads once more. Attach reports `reloadEvidence: {reloadId, attempts, runningVersion}` and clears the local record when its reply is queued on the native connection; only the app's accepted matching version/code confirms it. New requests refuse with `extension_reloading`; failure emits `extension.reload_failed`. Neither reload nor attach waits for page-reader installation. No tab changes. |
| `navigate` | `url`; optional `tabId`, `expectedUserSequence`, `newTab` | Reuses the exact supplied owned tab; an explicit lost tab refuses. Creates an inactive grouped tab when tabId is omitted. `newTab:true` requires a destination and no tabId; the Swift owner does not inject the conversation's remembered tab. It becomes the conversation's remembered tab after a successful navigation receipt while still owned. The Swift conversation owner forgets released/refused tabs and remembered IDs absent from the accepted group inventory before resolving an omitted-tab navigation; a closed or replaced channel supplies no inventory. Accepts HTTP(S), `chrome:`, `about:`, `file:` and `view-source:` URLs; `back` and `forward` require an owned tab and walk its history. Unsupported schemes (including `javascript:` and `data:`) and browser process commands refuse during validation, before tab creation or navigation; the app reports `effects: none`. Watches the exact navigation before dispatch and returns on its current document’s content-present or network-quiet event, with no pending URL. Navigation has no deadline; Chrome navigation errors, tab removal and cancellation end its wait. Receipt timings identify dispatch, commit, the admitting event and the following read return; an unobserved stage is null. Non-DOM pages keep completed-tab arrival evidence. Existing `status`, `verified` and receipt verification retain resource-completion meaning; a ready document still loading returns `verified:false` and a loading note immediately. Lost post-dispatch observations remain unknown. |
| `tab.close` | `tabId`; optional `expectedUserSequence` | Explicitly closes an owned tab. |
| `page.snapshot.read` | `tabId`; optional `expectedUserSequence`, `readCursor`, `maxNodes`, `maxTextChars`, `scope`, `find`, private `expectedDocumentId`, `expectedURL`, `screenPreviewMaxWidth`, `navigationStartedAtMs` | Waits on the shared document arrival owner, then selects its reader and reads the DOM once from the viewport outward without scrolling. There is no quiet interval, deadline, replacement capture or checkpoint reply. `capturedAt` dates the snapshot and `rendering.loaded` reports resource completion independently. Explicit and passive reads use the same DOM collector. Internal pages return the no-reader receipt below. Other pages without DOM access and Chrome's PDF viewer return the bounded JPEG picture shape instead, with `reading: {mode: "picture", domAccessible: false, reason}`. The app delivers it through the image slot and reports `read_mode: "picture"`. Reader selection precedes dispatch: a ready document supplies content-type/PDF-embed evidence; without a ready DOM reader, a minimal injected document.contentType read of the exact top document identifies PDF/image MIME types. The result's documentId must match; webNavigation filters extension viewer URLs and is not PDF evidence. No URL suffix, failed DOM read or debugger probe selects a reader. Missing or unreadable evidence remains a reader failure. |
| `page.look` | `tabId`; optional `expectedUserSequence`, private `screenPreviewMaxWidth` | Internal pages return the no-reader receipt below. Otherwise captures the tab's existing surface as JPEG (quality 85) through a temporary debugger attachment, then detaches and rechecks ownership. Returns `tabId`, `url`, `title`, `userSequence`, `width`, `height`, `format: "jpeg"`, and base64 `data`. With `screenPreviewMaxWidth`, adds private paint-out `geometry` (or `null` when unreadable), never another image; optional geometry is omitted if it would exceed the existing relay frame budget. The original `data` and read failures are unchanged. Never activates, focuses, raises, moves or scrolls the tab; no person-away condition or focus emulation. |
| `page.preview` | `tabId`, `maxWidth` (the app supplies `MacScreenPreviewFrame.maxWidth`); optional `expectedUserSequence`, `hasReadText` | Private local Screen-pane observation after a Chrome door call settles, including its form batch and follow-up reads. Returned pictures and closed tabs need no preview request. Returns tab identity plus `state: frame\|background\|unavailable`. A frame adds `format: jpeg`, `width`, `height`, base64 `data`; other states carry an honest `reason`. With `hasReadText`, a background tab returns its state without capture; the app already holds the served read. No tool result or image slot receives it. See the Screen preview contract below. |
| `page.element.click` | `tabId`, `expectedUserSequence`, `snapshotId`, `nodeId`; optional `button` | Clicks the exact observed node. |
| `page.element.fill` | Same observed-node identity plus `value` | Text editables select their contents and receive trusted Input.insertText. Atomic date/time/color/range/file values use the native setter with input/change; file permits clearing only. |
| `page.element.type` | Same observed-node identity plus `text`; optional `delayMs` | Sequential text controls only: targets the exact editing host, places its caret at the end, sends trusted Input.insertText and reads back. delayMs retains bounded per-character delivery. |
| `page.element.select` | Same observed-node identity plus `values` | Selects exact native option values. |
| `page.element.keypress` | Same observed-node identity plus `key` | Sends one real Input.dispatchKeyEvent keyDown then keyUp, including printable keys, Escape, navigation, editing and modifier shortcuts. Printable keyDown carries text and unmodifiedText (Enter: "\r"); nontext keys and shortcuts omit text, giving rawKeyDown semantics. No separate char event: Chrome generates the character and honors keydown.preventDefault(). Chrome owns defaults. |
| `page.element.set_checked` | Same observed-node identity plus `checked` | Calls the exact control's click() once if its state differs, then reads checked state. No direct checked assignment. A known mismatch returns refused with checked/requestedChecked; missing state or a replaced control remains unknown. |
| `page.element.double_click` | Same observed-node identity | Performs one double click. |
| `page.element.drag` | Same observed-node identity plus `targetNodeId` | Drags between distinct observed nodes in one frame and snapshot; drop acknowledgement is reported honestly. |
| `page.wait` | `tabId`, `expectedUserSequence`, `condition`; optional `timeoutMs`, `settleMs` | An explicitly requested bounded content wait, or `element_state` with snapshot/node identity and `state`. `settleMs` supplies the content quiet interval (default zero); this wait does not capture a snapshot. Non-DOM pages require Chrome load completion. |
| `page.scroll` | `tabId`, `expectedUserSequence`, `deltaX`, `deltaY`; optional `snapshotId`, `targetNodeId` | Scrolls the page or observed element. |
| `page.media` | `tabId`, `expectedUserSequence`, `operation: play\|pause\|seek`; seek requires finite nonnegative `seconds` | Checks ownership and user sequence, then controls the first eligible audio/video element in the main frame, respecting modals. Play needs observed clock advance and seek a `seeked` event within 0.1 s of the requested position, each within 5 s; pause must hold without clock advance or resume for 1.5 s. Buffering or background suspension can leave verification incomplete; inspect `completed` and `reason`. |

`chrome.history` is an app action, outside this extension protocol. The
bundled part `native-chrome-history` answers it from a private read-only copy of
the Default profile's History, independent of extension connection or profile. The extension declares no `history` permission. See the
[Chrome surface contract](../README.md) for capture, aggregation and failure behavior.

## Local Screen preview

Chrome navigation, snapshots (including continuation/find reads), looks, click,
double click, fill/type, select, keypress, checkbox, drag, scroll, wait and media
calls publish one transient `MacScreenPreviewUpdate` through `turn.screenPreview`
after the complete door call settles. Internal readbacks and form steps share
that one observation. Explicit close publishes its settled `tabClosed` receipt,
clearing the old image and naming the closed site/title without requesting a
picture of the removed tab. A failed or unknown close says it is not confirmed.
Inventory/status, setup, reload, history, dry runs,
and refusals before a tab call do not capture. The caption names the activity,
site and title, with the shared secret-label redactor; it never copies typed
arguments or URL queries. It makes no claim that a page action succeeded.

Explicit looks and PDF/picture reads deliver Chrome's original JPEG to the
agent, with the same capture and failure behavior as without Screen. The pane
may show only a copy painted locally on the Mac using the returned `geometry`;
without readable geometry it shows the caption alone. It never paints over the
JPEG delivered to the agent or adds secure-geometry failures to their read. No
`page.preview` request or second capture follows a returned picture, even if
the pane's copy is unavailable or its local resizing fails. The app retains
only the pane update until the complete call settles. Geometry is consumed before
the model-facing result is assembled; no second image travels through the relay.

When a pane sink exists, the app supplies `screenPreviewMaxWidth` from
`MacScreenPreviewFrame.maxWidth`. The look's existing debugger lease reads
DOMSnapshot geometry once, immediately before its one capture. The response's
optional `geometry` is `{width, height, rects: [{x, y, width, height}]}`. Its
rectangles use the captured viewport's top-left origin in CSS units, clipped to
the rounded capture viewport `width` and `height`; document scroll offsets have
already been subtracted. At most 128 visible rectangles are returned (a 24 KiB
metadata allowance at 192 bytes per four-number rectangle); exceeding that count
returns one rectangle covering the whole viewport. Geometry is omitted at the
wire boundary if adding it would exceed the existing 1 MiB response limit, so
optional presentation metadata cannot refuse a valid original capture. No image
or transport limit is changed.

The Mac decodes the JPEG already returned, scales the geometry into source-image
pixels, and paints password/autocomplete-password/cc fields and all embedded
frames, objects and embeds onto its own copy. `MacScreenPreviewFrame` applies
opaque, outward-rounded masks with the existing two-source-pixel margin before
its shared downscaler runs; the original capture stays unchanged.
DOMSnapshot string index `-1` means an empty string, including empty boolean
attribute values. Unreadable node identity, attributes, required bounds,
snapshot or viewport returns `geometry: null`, making only the pane copy
unavailable. There is no second geometry read or moving-geometry comparison on
the agent's picture path.
Null, missing or malformed geometry, or local decode/painting/resizing failure,
clears the pane picture and shows its unavailable caption, with no error added
to the agent's call.

For calls without a returned picture, the extension takes at most one preview
capture. When the call returned read text and its tab is in the background,
`hasReadText` selects the read-text form without even querying for a debugger.
A visible target uses
`chrome.tabs.captureVisibleTab` for its window, with exact selected-tab checks.
Chrome requires `<all_urls>` or a user-granted `activeTab` for that API; this
extension's existing HTTP/HTTPS permissions do not grant it. Missing capture
permission remains unavailable. A background target uses
`Page.captureScreenshot` only if Chrome already reports an attached debugger;
the preview never attaches one, activates a tab or emulates focus. Without an
attachment it returns `background` and says a picture would show a new debugging
banner. Another debugger's attachment may refuse commands; that remains
unavailable. No alternative capture mechanism runs after a failure.

Current tab ownership releases selected tabs and creates new tabs inactive.
Consequently ordinary background Chrome reads show the page as read: the final
served text, including a site's sense or action readback, with its line breaks,
headings and numbered rows. The app bounds it to a conventional 80-column by
24-row screenful (1,920 characters and at most 24 source lines); the pane also
limits drawn lines to 24 as narrower widths can wrap rows. The caption names
the read's site/title and says it is a background tab. The visible-capture
branch is conditional on a visible owned target
and Chrome's capture permission; this change grants neither. Existing debugger
leases for Chrome input/history/explicit looks end with their own operation,
before the door's preview request. No lease survives its operation for a later
preview request; a picture read already supplies Screen's masked local copy.

Before a local preview capture is delivered, the extension inspects the exact top document's
password inputs, `autocomplete` containing `password` or `cc-`, and open/closed
shadow roots. Embedded frames, objects and other embedded surfaces are painted
out as whole rectangles because their fields are not inspected from the parent.
Opaque, outward-rounded masks are applied before resizing to at most 960 pixels
wide and JPEG encoding. No page DOM or input value is changed or read. Missing
document/viewport/mask evidence, a bounded walk exceeding 50,000 elements,
changed document/secure geometry, capture/painting failure or oversized bytes
produces an explicit unavailable caption. A geometry mismatch returns that
caption-only state directly; it never turns the agent's call into an error.
Blank mask lists on inspected pages remain valid; no field name is required
for ordinary pixels.

The app waits at most two seconds for the preview response. A timeout or
cancellation produces an unavailable caption and preserves the original call's
result; late replies cannot replace it. Caption-only browser updates clear the
previous image so a different tab is never pictured as the current one. The
Screen pane renders the returned read for the background state; an unavailable
preview clears its content and shows its honest status caption alone. Image
and read text replace one another in the same preview, never keeping another
source's content.
The reader withholds values/text and selected-choice marks of password, autocomplete-password and
cc fields at source, so both the model's read and Screen's copy share that rule.
The app also applies its shared secret redactor before bounding the served text.
Standalone preview frames travel only over the local authenticated relay into
memory and the existing per-session preview; they are never saved, sent to the
phone, passed to a model, or made receipts. The Mac's painted copy of an explicit
picture read uses the image already returned to the model; that copy never
travels through the relay or gains another model or phone delivery. The
read-text preview is also memory-only and never saved or sent to the phone.

## Page evidence

The [Chrome read contract](../README.md) owns document arrival, explicit waits, overlay geometry,
graphic descriptions and continuation semantics. The protocol owns defaults:
`maxNodes` 400 (range 1...2,000), `maxTextChars` 32,000 (1...200,000), within
`MAX_SNAPSHOT_RESULT_BYTES` 1,000,000 UTF-8 bytes. Omitted limits use these
defaults across snapshots, navigation and workspace readbacks, current-tab
controls and tab rooms; callers add no per-path defaults. Passive page changes
reuse the last served view. `find` is nonempty
text up to 2,048 characters, mutually exclusive with `readCursor`; it starts at
the first matching element. `reading.find` records text, observed match and
whether the walk was limited. A not-yet-matched bounded walk keeps `find` in its
cursor, including when it advances to another frame; an identity-only top-frame
capture does not consume the search. A cursor's optional `position.overlay:true`
orders the overlay layer after content; `position.complementary:true` identifies
navigation and complementary landmarks, which follow main content outside column sets.
`position.flow` carries the finite layout-order coordinates and prose-ranked
column positions from the page walker. Side-by-side sibling columns read one
at a time even inside one landmark, with prose order ahead of landmark labels;
a cursor and every transport fold retain
that same order. A position without its flow is invalid and requires a new
page read, rather than guessing an old order.
Node `overlay` labels that classification, including descendants. Frame
aggregation reads all frames' content before an overlay phase, using only the
budget content leaves. `readLayer` travels in every cursor, including a
transport fold, so deferred overlays remain reachable. Image names include CSS width/height.
Each embedded page resolves its embedding element through a nonce-bound
parent/child Window message, not a URL/name match. It inherits a fixed or
dialog cover on that frame. Its layout observation removes its listener on
reply, cancellation or teardown, without a timer. A parent that cannot find
the embedding element replies with a cause; `frame_overlay_unavailable` and
`overlayUnknown` retain it while readable frame content and siblings proceed.
An absent parent reply remains a pending observation with Stop available.
The app offers the same tab's `chrome.look` for pixels and carries the snapshot
owner's `nodeCount` as `node_count` in its text envelope. `page-load.js` projects
DOM arrival for explicit reads, navigation readbacks and passive news: main/feed/
article prose arrives through the page's MutationObserver, or Chrome reports the
document loaded (webNavigation.onCompleted), whichever comes first. The extension
observes pages only from its isolated-world reader; it never wraps or replaces a
page's own functions. Reader attachment supplies contentPresent and
contentPresentAt on the document's absolute performance clock.
History and fragment navigation reset the current route's content and quiet
evidence. The reader's `currententrychange` listener drains pre-route records;
only text added or changed in later MutationObserver records proves route
content. Attachment cannot admit unchanged prose; removal can clear content.
Content presence counts three qualifying prose blocks of at least 30 characters,
or one block or a content control once document.readyState is complete. Headings,
navigation, page chrome and control labels are excluded; visible content
progress/progressbar elements keep the verdict busy. The same walk and exclusions
apply inside open and closed shadow roots. This verdict can admit an early shell
before later feed items render. The private `nativeagent.page.document` query
reports `busy` and its cause; DOM snapshots omit `document`. Neither content
presence nor `rendering.loaded` establishes completion of asynchronous content.
The first admitting event releases the read without a quiet interval or clock.
There is no snapshot, navigation, picture or frame-layout deadline. A required
reader wait ends on readiness, document replacement, navigation error, Stop,
takeover or connection loss; absent events leave the request pending.
The existing node, text, frame and transport budgets apply to one DOM capture.
No replacement read or empty-content retry runs. Completion and newer reads
fence publication, including cancellation of a superseded layout observation.

`summary.gaps` names unread parts with frame id, URL, code and message.
The app projects only those gaps as `status:partial`, retaining `gaps`.
Missing or malformed gap metadata retains captured content and raw evidence;
coverage remains unknown rather than refusing the read or asserting completion.
Embedding gaps preserve the parent's observed cause without substitute prose.
Node/text/transport limits are pagination: `has_more` and `next`/`element_more`
carry the existing exact offset-bearing continuation. A window without
readable material is `empty_window`, with `read_window_empty` or
`find_not_observed` and no `ok:false`; it proves no page-wide absence.
There are no settled/unsettled read fields or labels.

Only an explicit `page.wait` with `condition:"navigation_settled"` observes
content progress and readable prose. Its timeout and `settleMs` belong to that
request, with no mandatory quiet interval. It returns `matched` and a reason;
it never captures a snapshot. Its listeners and timers end on completion,
cancellation or ownership loss. The existing readiness owner wakes it after
validating the exact current document. Non-DOM waits retain their load-complete
meaning and exact-document picture admission is unchanged.

Navigation readbacks retain the observed document ID and landed URL as arrival
evidence. HTTP(S) watchers exclude a fresh tab's hostless blank document. The
navigation waits for that exact document's content-present or network-quiet
arrival. A committed HTTP(S) document identified by PDF/image MIME arrives as
`non_dom_committed`, without prose or observed network history. Internal and
other non-HTTP arrivals use completed-tab evidence. `status`, `verified` and
`rendering.loaded` still describe resource completion separately.
The navigation receipt's `timings` holds `startedAtMs` and relative
`dispatchedMs`, `committedMs`, `contentPresentMs`, `documentLoadedMs`, and
`readReturnedMs`. Observed stages survive subsequent errors and cancellation;
unobserved stages are null. Private snapshot input
`navigationStartedAtMs` carries the same extension-clock origin; the snapshot's
`navigationReadReturnedMs` is projected into its originating navigation receipt
by both ordinary and form-batch Swift callers. Workspace navigation without
a readback keeps read-return null. Stages preceding the request remain null. Timing never
decides arrival. See [background rendering limits](../README.md).

The app's text projection states modal blocking and captured `states.blockingDialogs`
names once in the header and renders
later identical blocks as references to their first row, retaining control and
link identities. Row lookup distinguishes a row's existence from its advertised
actions: `modal_target_required`, `node_not_visible`, `node_disabled` and
`node_not_actionable` retain the observed cause; `no_such_row` means the supplied
row was not observed in that read. Form batches use the same captured causes.
Current DOM action checks retain detached/hidden/disabled/modal distinctions and
the existing document, identity and ownership gates. The DOM capture budgets
still account for captured nodes.

Snapshot IDs and node IDs are action proofs, never selectors. Snapshots include
`tabId`, `userSequence`, `capturedAt`, URL/title/language, viewport, summary,
nodes and frames. Each node's `elementIdentity` is stable for that DOM element
within the document. Replacement documents/elements receive new identities.
Frames and shadow roots (open or closed) retain exact routing and identity. A captured
frame mutation invalidates its old routes; retained navigation nodes still
require their local identity proofs. The read itself returns its captured
material with `reading.pageMoved: true` if a captured frame changed, rather
than refusing or retrying. Swift renders one moved-page note. Transport
truncation preserves sections, paragraphs and inline link references, with an
honest continuation. Capture budgets each prose prefix with all its required
inline link proofs as one unit. A split advances the text offset; a next unit
that cannot fit an empty window returns read_budget_too_small. Transport
budgeting keeps the same group and refuses missing link evidence.

Chrome internal pages (`chrome://`, `about:`) allow no DOM reader or debugger
capture. Both reads return one receipt with `tabId`, `url`, `title`,
`userSequence` and `reading: {mode: "none", domAccessible: false, reason: "Chrome allows no reader on its internal pages"}`.
The app returns one text line and `read_mode: "none"`; it attempts no picture
and reports no read error. Navigation verification remains tab-based.

Pictures use `Page.captureScreenshot` with `fromSurface: true`, clipped to the
visible viewport and scaled so the long side is at most 2048 device pixels (what
the app's image slot shows). Chrome's debugging infobar shows while a tab of
theirs is held rendering (navigation, reads, waits and scrolls hold focus emulation
until 60 s after their last one, their ownership ends, or the person cancels the bar,
which stands until the extension restarts), and otherwise for the capture attachment. A capture error or empty data returns `tab_not_painted`:
Chrome did not render this hidden tab; nothing was changed and it was not
activated. A JPEG above the image slot's 8 MiB returns `picture_too_large`.
Looking never switches tabs to obtain pixels.
PDF snapshot pictures also carry `document: {kind: "pdf", status: "unread"}`
when the document classification identifies a PDF before dispatch. The app
preserves that document receipt and returns `text` explaining that PDF text is
unavailable from Chrome's picture reader. The picture is the verified Chrome
view (`chrome_view_verified` reports image delivery). URL and title remain
Chrome's address; no independent HTTP request or transcript is added.
Document classification identifies image documents from their content type
before selecting the picture reader, without guessing from the URL.
The app's `chrome.look` action accepts only optional `tab_id` and resolves the
conversation's remembered tab. It is a read under the same Trust gate as the
DOM snapshot. Base64 stays in transport; the model receives the shared image
slot's bounded 2048-pixel image, source dimensions and `builtin-chrome` provenance.

`scope` is `page` or `main_content`. Main content is the visible declared main/feed regions,
else article bodies (`article`, `[role=article]`, `[role=document]`, or
`[itemprop~=articleBody]`), else the document body. The existing navigation
filter excludes navigation in every case; visible modals remain included.
`page` includes navigation too. `reading.mainContentAvailable` means a visible
main or article region was declared, before including the document body.

`readMore` and node `more` addresses can be
supplied as `readCursor`, carrying `tabId`, top `documentId`, `readLayer`
(`content` or `overlay`), `url`, `frameURL`, `frameId`, `frameDocumentId` and a `position`
with `scrollX`, `scrollY`, `distance`, `y`, `x` and `ordinal`. Positions order
rendered boxes by content/complementary/overlay priority, distance from the viewport, then page coordinates and the
ordinal of coincident boxes. `textOffset`, `optionOffset` and `elementOnly`
retain folded paragraphs and controls. A following embedded frame may omit
`position` to start at its viewport. These positions describe reading, never
authorize mutation; structural element paths are no longer continuations.
An optional `anchor: {identity, key}` binds the element and its content; an
unchanged anchor follows a moved layout before applying the cursor. Missing or
recycled rows continue at the next current position with the moved-page note.
Readable `site:` addresses include tab, document, layer and anchor, so `more`
alone resolves its tab even when another tab holds the same URL. Raw cursors
also supply their own tab; a mismatching explicit tab is refused. Top-document
replacement starts at new content; an embedded-document replacement starts at
that frame's new content, both with a moved-page note. A changed scroll
offset, missing scroller or replaced page starts in the current view with the
same moved-page note. Scroll receipts return a local `viewportObservationId`
bound to that tab and target; the following read reports actual viewport
change; it may accompany a positional continuation for a scrolled element.
Every read reports `reading.fromViewport: true`. `rendering` reports visibility,
readiness and `rendered_dom_only`.

Mutation receipts contain `id`, `action`, `tabId`, `userSequence`, snapshot/node
identity, `outcome`, `verification`, `retry`, `startedAt`, `completedAt`.
Outcome is succeeded, refused, partially_completed, or outcome_unknown. Lost
replies never trigger automatic replay. Trusted input has a twenty-second
execution deadline. Undelayed text is one Input.insertText; an explicit delay
sends code points with cancellation-aware waits. Every next effect checks the
exact admitted document, current custody, active request and retained editing
host. Stop, takeover, host replacement/detachment, changed editability, hidden
controls or lost focus stop further input. Password values remain protected.
One sender admits and dispatches each Input command, including key-up settlement.
Custody, debugger attachment and focus-emulation waits finish first. The sender
then reads the current frame/document identity, compares it with the admitted
document and sends that event in the same continuation, with no intervening await.
Before keydown dispatch, the sender arms its expected key signature on the
admitted focused host. The page consumes it once using the exact active element
through open and closed roots; the window's retargeted event path is not an
input-origin proof. Other trusted input still yields custody.

The page agent only targets, focuses once (preventScroll), places a selection
and reads back. The trusted-input owner attaches once, enables hidden-tab focus
emulation, emits input and detaches once in finally. The protocol key owner uses
the complete [Playwright macEditingCommands table](https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/server/macEditingCommands.ts)
plus Chromium's [macOS Paste and Match Style accelerator](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/ui/cocoa/accelerators_cocoa.mm).
The lookup spelling is enabled modifiers in Shift/Control/Alt/Meta order followed
by the exact physical code (for example `Shift+Meta+KeyV`); modifier order in
the incoming key string does not matter. Missing entries send `commands: []`,
never a command inferred from fewer modifiers. `Meta+Shift+V` sends
`pasteAndMatchStyle`, `Meta+V` sends `paste`; ordered multi-command bindings stay
ordered. AppKit selector colons are stripped and `insert*` selectors excluded as
in Playwright's CDP encoder, leaving text on the combined keydown.
The wire key spelling remains a printable character or a named key, prefixed by
Alt/Control/Meta/Shift modifiers. Named keys also include F5, NumpadEnter,
Numpad5 and NumpadSubtract; keypad events retain location 3 and isKeypad.
The page agent has no keyboard defaults.
`input` is `chrome_trusted` for keyboard/text or `native_value` for atomic fill.
`landed` is `landed`, `changed_by_page`, `not_landed`, `no_value_change` (a key
without a value change) or `unknown` (a detached target). `valueBefore` and
`valueAfter` retain up to 2000 characters each, with `valueTruncated`.
A page rewrite returns changed evidence, never an invented refusal.
`characterCount` counts acknowledged code points, `nextUTF16Offset` counts
acknowledged UTF-16 units, and `requestedCharacterCount` is the request size.
These counts do not assert retention. `completed` requires successful readback
and completion of dispatch; partial typing is conclusive only for an observed
retained prefix with no input command in flight. Otherwise a post-dispatch
failure is outcome_unknown. Unknown results never instruct replay.
A lost target readback reports readbackError; release reports targetReleaseError.
Key-up settlement runs even after Stop for a dispatched keydown, under the same
document and current custody; a lost document/custody or failed release stays in
keyReleaseError. No key is released into a replacement document or yielded tab.
`cleanupError: {code: "debugger_release_failed", message}` is independent of
the performed effect, including navigation, hidden scroll and picture capture.
The Swift picture delivery keeps cleanupError. Operation errors retain cleanup
failure in details and their message; detach failure never replaces an effect.
Node waits are bounded to ten seconds. Navigation waits
recheck ownership and supersession before returning observed completion.

`page.changed` supplies `tabId`, `userSequence`, `changeGeneration`,
`changedFrameId`, and a registered actionable `snapshot`. Document readiness,
URL changes and MutationObserver notices trigger bounded captures, spaced by their
own cost so a changing page gives up at most a twentieth of its time; no polling
or tab creation occurs. Change generation and reading view are page state stored in
session storage, independent of tab ownership. Explicit reads supersede passive
captures. Every DOM capture carries the top page's worker-local document
generation. Only top-document replacement advances that fence; one synchronous
publish-if-current helper checks it before registering routes, retaining the
read's view, returning its result, or emitting `page.changed`. A subframe commit
marks movement and removes only that frame's action routes, including routes
from an old reply still in flight; sibling content remains. An unready or changed
optional frame is a named gap. Superseded passive captures retain pending work;
replacement documents wait for frame readiness, with no retry clock.
`page.invalidated` supplies `tabId` at navigation dispatch, top-document commit
and ownership end. The app discards its subscription snapshot and prevents
already-pending replies from republishing that baseline. `page.frame_invalidated`
supplies `tabId` and `frameId` on a subframe commit: the Mac drops its cached
aggregate without fencing pending replies that retain sibling evidence. An
explicit read only replaces extension routes; it can publish its fresh result.
Inventory replacement also discards a retained tab's cached snapshot when its
URL or user sequence changes. A new subscription admits a cached DOM snapshot
only when tab, URL, user sequence and requested host still agree. With no current
snapshot it waits for a real capture, ending on cancellation, ownership loss or
channel shutdown; absence does not publish page content or a capture verdict.
`page.change_unavailable` supplies tab/sequence and `{code, message}` error.
`tabs.changed` supplies a deduplicated current `tabs` group projection when
group membership, tab metadata or user ownership changes. It queries only
NativeAgent groups. `tab.yielded` supplies `tabId`, `userSequence`, `reason` and `url`; it invalidates
snapshot routes and in-flight typing/waits without closing the tab.
The app records each `tab.yielded` (a close yields first, reason `tab_closed`;
the `tab.closed` confirmation is not a second release) as the last eight
`{tabId, reason, at, url}` releases in `chrome.status.released`, using the
event's `occurredAt` as `at`. The status note says "tabs that were theirs and why
they stopped being theirs". This evidence lasts for the app run, across relay
reconnects, and never grants ownership or persists to disk. A release by the
person's act (`tab_active`, `tab_activated`, `user_*`) also posts the
`chrome.tab_taken` signal and a world happening carrying the host alone, never
the URL.

Host cancellation is a transport event `action.cancel` with
`payload: {requestId}`. It stops only that in-flight action, preserves group
ownership, and introduces no model verb.

The sole repeating Chrome alarm reconnects native messaging when the app is
absent or the transport is disconnected. It holds no ownership state. A reload's
single ten-second retry is bounded separately and is cleared by accepted attach;
the relay's launch-time listener observation lasts at most twenty seconds and
redials once through the same authenticated transport.
An app request belongs to one channel. Disconnection returns that request's
original outcome and connection remedy; it never resubmits on a replacement
channel. A dispatched mutation with no confirmation remains outcome unknown.
