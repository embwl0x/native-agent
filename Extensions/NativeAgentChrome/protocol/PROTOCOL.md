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
User. Every read or action checks the tab's current Chrome group. Trusted input,
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
| `extension.reload` | `reloadId` | Acknowledges `reloadId`, `beforeVersion`, `status: "acknowledged"`, drains accepted requests and queues their replies, then reloads. New requests refuse with `extension_reloading`; failure emits `extension.reload_failed`. No tab changes. |
| `navigate` | `url`; optional `tabId`, `expectedUserSequence` | Reuses the owned tab, or creates an inactive grouped tab if missing or no longer owned. Accepts HTTP(S), `chrome:`, `about:`, `file:` and `view-source:` URLs; `back` and `forward` require an owned tab and walk its history. Unsupported schemes (including `javascript:` and `data:`) and browser process commands refuse during validation, before tab creation or navigation; the app reports `effects: none`. Watches `tabs.onUpdated` from before dispatch, then checks the exact tab is complete with no pending URL and returns its landed URL (`verification: "verified"`, `verified: true`, `requestedUrl` beside `url`). Chrome pages and PDFs need no DOM agent for verification. If the 25 s deadline passes after a document commit, the partial arrival retains `verified: false` and a loading sentence; lost post-dispatch observations remain unknown. |
| `tab.close` | `tabId`; optional `expectedUserSequence` | Explicitly closes an owned tab. |
| `page.snapshot.read` | `tabId`; optional `expectedUserSequence`, `readCursor`, `maxNodes`, `maxTextChars`, `scope` | Reads the current ready document's rendered DOM from the viewport outward without scrolling, independently of unrelated loading resources; `rendering.loaded` reports tab completion. Internal pages return the no-reader receipt below. Other pages without DOM access and Chrome's PDF viewer return the bounded JPEG picture shape instead, with `reading: {mode: "picture", domAccessible: false, reason}`. The app delivers it through the image slot and reports `read_mode: "picture"`. HTTP PDF viewers are identified by Chrome's MIME type or DOM document evidence, never a URL suffix; an ordinary web page's missing reader remains a failure. |
| `page.look` | `tabId`; optional `expectedUserSequence` | Internal pages return the no-reader receipt below. Otherwise captures the tab's existing surface as JPEG (quality 85) through a temporary debugger attachment, then detaches and rechecks ownership. Returns `tabId`, `url`, `title`, `userSequence`, `width`, `height`, `format: "jpeg"`, and base64 `data`. Never activates, focuses, raises, moves or scrolls the tab; no person-away condition or focus emulation. |
| `page.element.click` | `tabId`, `expectedUserSequence`, `snapshotId`, `nodeId`; optional `button` | Clicks the exact observed node. |
| `page.element.fill` | Same observed-node identity plus `value` | Replaces the editable value. |
| `page.element.type` | Same observed-node identity plus `text`; optional `delayMs` | Appends bounded sequential text, with readback. |
| `page.element.select` | Same observed-node identity plus `values` | Selects exact native option values. |
| `page.element.keypress` | Same observed-node identity plus `key` | Sends a bounded named key/chord or one printable character. |
| `page.element.set_checked` | Same observed-node identity plus `checked` | Applies checkbox/radio/switch state. |
| `page.element.double_click` | Same observed-node identity | Performs one double click. |
| `page.element.drag` | Same observed-node identity plus `targetNodeId` | Drags between distinct observed nodes in one frame and snapshot; drop acknowledgement is reported honestly. |
| `page.wait` | `tabId`, `expectedUserSequence`, `condition`; optional `timeoutMs`, `settleMs` | Bounded navigation settlement, or `element_state` with snapshot/node identity and `state`. |
| `page.scroll` | `tabId`, `expectedUserSequence`, `deltaX`, `deltaY`; optional `snapshotId`, `targetNodeId`, `renderHidden` | Scrolls the page or observed element. Temporary hidden-tab focus emulation requires `renderHidden: true`. |
| `page.media` | `tabId`, `expectedUserSequence`, `operation: play\|pause\|seek`; seek requires finite nonnegative `seconds` | Checks ownership and user sequence, then controls the first eligible audio/video element in the main frame, respecting modals. Play needs observed clock advance and seek a `seeked` event within 0.1 s of the requested position, each within 5 s; pause must hold without clock advance or resume for 1.5 s. Buffering or background suspension can leave verification incomplete; inspect `completed` and `reason`. |

Snapshot IDs and node IDs are action proofs, never selectors. Snapshots include
`tabId`, `userSequence`, `capturedAt`, URL/title/language, viewport, summary,
nodes and frames. Each node's `elementIdentity` is stable for that DOM element
within the document. Replacement documents/elements receive new identities.
Frames and open shadow roots retain exact routing and identity. A captured
frame mutation invalidates its old routes; retained navigation nodes still
require their local identity proofs. The read itself returns its captured
material with `reading.pageMoved: true` if a captured frame changed, rather
than refusing or retrying. Swift renders one moved-page note. Transport
truncation preserves sections, paragraphs and inline link references, with an
honest continuation.

Chrome internal pages (`chrome://`, `about:`) allow no DOM reader or debugger
capture. Both reads return one receipt with `tabId`, `url`, `title`,
`userSequence` and `reading: {mode: "none", domAccessible: false, reason: "Chrome allows no reader on its internal pages"}`.
The app returns one text line and `read_mode: "none"`; it attempts no picture
and reports no read error. Navigation verification remains tab-based.

Pictures use `Page.captureScreenshot` with `fromSurface: true`, clipped to the
visible viewport and scaled so the long side is at most 2048 device pixels (what
the app's image slot shows); Chrome's debugging infobar lasts only for the
capture attachment. A capture error or empty data returns `tab_not_painted`:
Chrome did not render this hidden tab; nothing was changed and it was not
activated. A JPEG above the image slot's 8 MiB returns `picture_too_large`.
Looking never switches tabs to obtain pixels.
PDF snapshot pictures also carry `document: {kind: "pdf", status: "unread"}`
when Chrome's MIME type or the DOM reader identifies a PDF. The app adds the
bounded independent HTTP text read to the same picture receipt: `text` is the
rendered transcript and `document` retains its provenance and coverage. Its
successful extraction remains `status: "unverified"`, `source: "http_pdf"`,
`chrome_document_verified: false`, with reason "Independent HTTP PDF text; Chrome's displayed document has not been verified. Chrome cookies and authentication were not used."
The picture is the verified Chrome view (`chrome_view_verified` reports image
delivery); an HTTP or extraction failure remains in `document` beside it.
Chrome's URL/title remain the view's address; the transcript retains its own
`final_url`, `read_at`, `http_status`, `http_read_status` and truncation fields.
DOM snapshots mark image documents with `document: {kind: "image"}` so an
empty text read can point to the picture without guessing from the URL.
The app's `chrome.look` action accepts only optional `tab_id` and resolves the
conversation's remembered tab. It is a read under the same Trust gate as the
DOM snapshot. Base64 stays in transport; the model receives the shared image
slot's bounded 2048-pixel image, source dimensions and `builtin-chrome` provenance.

`scope` is `page` or `main_content`. Main content is the visible declared main regions,
else article bodies (`article`, `[role=article]`, `[role=document]`, or
`[itemprop~=articleBody]`), else the document body. The existing navigation
filter excludes navigation in every case; visible modals remain included.
`page` includes navigation too. `reading.mainContentAvailable` means a visible
main or article region was declared, before including the document body.

`readMore` and node `more` addresses can be
supplied as `readCursor`, carrying `url`, `frameURL`, `frameId` and a `position`
with `scrollX`, `scrollY`, `distance`, `y`, `x` and `ordinal`. Positions order
rendered boxes by distance from the viewport, then page coordinates and the
ordinal of coincident boxes. `textOffset`, `optionOffset` and `elementOnly`
retain folded paragraphs and controls. A following embedded frame may omit
`position` to start at its viewport. These positions describe reading, never
authorize mutation; structural element paths are no longer continuations.
Missing/recycled rows continue at the next current position. A changed scroll
offset, missing scroller or replaced page starts in the current view with the
same moved-page note. Scroll receipts return a local `viewportObservationId`
bound to that tab and target; the following read reports actual viewport
change; it may accompany a positional continuation for a scrolled element.
Every read reports `reading.fromViewport: true`. `rendering` reports visibility,
readiness and `rendered_dom_only`.

Mutation receipts contain `id`, `action`, `tabId`, `userSequence`, snapshot/node
identity, `outcome`, `verification`, `retry`, `startedAt`, `completedAt`.
Outcome is succeeded, refused, partially_completed, or outcome_unknown. Lost
replies never trigger automatic replay. Typing has a twenty-second execution
deadline, yields every 32 code points, and stops on trusted input, target
replacement/detachment, changed editability or visibility. Password values
remain protected. Node waits are bounded to ten seconds. Navigation waits
recheck ownership and supersession before returning observed completion.

`page.changed` supplies `tabId`, `userSequence`, `changeGeneration`,
`changedFrameId`, and a registered actionable `snapshot`. Document readiness,
URL changes and MutationObserver notices trigger bounded captures; no polling
or tab creation occurs. Generation and reading view are page state stored in
session storage, independent of tab ownership. Explicit reads supersede passive
captures.
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
reconnects, and never grants ownership or persists to disk.

Host cancellation is a transport event `action.cancel` with
`payload: {requestId}`. It stops only that in-flight action, preserves group
ownership, and introduces no model verb.

The sole repeating Chrome alarm reconnects native messaging when the app is
absent or the transport is disconnected. It holds no ownership state.
