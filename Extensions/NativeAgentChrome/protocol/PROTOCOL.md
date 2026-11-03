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
| `extension.reload` | `reloadId` | Acknowledges `reloadId`, `beforeVersion`, `status: "acknowledged"`, drains accepted requests and queues their replies, then reloads. New requests refuse with `extension_reloading`; failure emits `extension.reload_failed`. No tab changes. |
| `navigate` | `url`; optional `tabId`, `expectedUserSequence` | Reuses the exact supplied owned tab; an explicit lost tab refuses. Creates an inactive grouped tab only when tabId is omitted. The Swift conversation owner forgets released/refused tabs so a later omitted-tab navigation can create one. Accepts HTTP(S), `chrome:`, `about:`, `file:` and `view-source:` URLs; `back` and `forward` require an owned tab and walk its history. Unsupported schemes (including `javascript:` and `data:`) and browser process commands refuse during validation, before tab creation or navigation; the app reports `effects: none`. Watches `tabs.onUpdated` from before dispatch, then checks the exact tab is complete with no pending URL and returns its landed URL (`verification: "verified"`, `verified: true`, `requestedUrl` beside `url`). Chrome pages and PDFs need no DOM agent for verification. If the 25 s deadline passes after a document commit, the partial arrival retains `verified: false` and a loading sentence; lost post-dispatch observations remain unknown. |
| `tab.close` | `tabId`; optional `expectedUserSequence` | Explicitly closes an owned tab. |
| `page.snapshot.read` | `tabId`; optional `expectedUserSequence`, `readCursor`, `maxNodes`, `maxTextChars`, `scope` | Reads the current ready document's rendered DOM from the viewport outward without scrolling, independently of unrelated loading resources; `rendering.loaded` reports tab completion. Internal pages return the no-reader receipt below. Other pages without DOM access and Chrome's PDF viewer return the bounded JPEG picture shape instead, with `reading: {mode: "picture", domAccessible: false, reason}`. The app delivers it through the image slot and reports `read_mode: "picture"`. Reader selection precedes dispatch: a ready document supplies content-type/PDF-embed evidence; without a ready DOM reader, a minimal injected document.contentType read of the exact top document identifies PDF/image MIME types. The result's documentId must match; webNavigation filters extension viewer URLs and is not PDF evidence. No URL suffix, failed DOM read or debugger probe selects a reader. Missing or unreadable evidence remains a reader failure. |
| `page.look` | `tabId`; optional `expectedUserSequence` | Internal pages return the no-reader receipt below. Otherwise captures the tab's existing surface as JPEG (quality 85) through a temporary debugger attachment, then detaches and rechecks ownership. Returns `tabId`, `url`, `title`, `userSequence`, `width`, `height`, `format: "jpeg"`, and base64 `data`. Never activates, focuses, raises, moves or scrolls the tab; no person-away condition or focus emulation. |
| `page.element.click` | `tabId`, `expectedUserSequence`, `snapshotId`, `nodeId`; optional `button` | Clicks the exact observed node. |
| `page.element.fill` | Same observed-node identity plus `value` | Text editables select their contents and receive trusted Input.insertText. Atomic date/time/color/range/file values use the native setter with input/change; file permits clearing only. |
| `page.element.type` | Same observed-node identity plus `text`; optional `delayMs` | Sequential text controls only: targets the exact editing host, places its caret at the end, sends trusted Input.insertText and reads back. delayMs retains bounded per-character delivery. |
| `page.element.select` | Same observed-node identity plus `values` | Selects exact native option values. |
| `page.element.keypress` | Same observed-node identity plus `key` | Sends one real Input.dispatchKeyEvent keyDown then keyUp, including printable keys, Escape, navigation, editing and modifier shortcuts. Printable keyDown carries text and unmodifiedText (Enter: "\r"); nontext keys and shortcuts omit text, giving rawKeyDown semantics. No separate char event: Chrome generates the character and honors keydown.preventDefault(). Chrome owns defaults. |
| `page.element.set_checked` | Same observed-node identity plus `checked` | Calls the exact control's click() once if its state differs, then reads checked state. No direct checked assignment. A known mismatch returns refused with checked/requestedChecked; missing state or a replaced control remains unknown. |
| `page.element.double_click` | Same observed-node identity | Performs one double click. |
| `page.element.drag` | Same observed-node identity plus `targetNodeId` | Drags between distinct observed nodes in one frame and snapshot; drop acknowledgement is reported honestly. |
| `page.wait` | `tabId`, `expectedUserSequence`, `condition`; optional `timeoutMs`, `settleMs` | Bounded navigation settlement, or `element_state` with snapshot/node identity and `state`. |
| `page.scroll` | `tabId`, `expectedUserSequence`, `deltaX`, `deltaY`; optional `snapshotId`, `targetNodeId`, `renderHidden` | Scrolls the page or observed element. Temporary hidden-tab focus emulation requires `renderHidden: true`. |
| `page.media` | `tabId`, `expectedUserSequence`, `operation: play\|pause\|seek`; seek requires finite nonnegative `seconds` | Checks ownership and user sequence, then controls the first eligible audio/video element in the main frame, respecting modals. Play needs observed clock advance and seek a `seeked` event within 0.1 s of the requested position, each within 5 s; pause must hold without clock advance or resume for 1.5 s. Buffering or background suspension can leave verification incomplete; inspect `completed` and `reason`. |

`chrome.history` is an app action, outside this extension protocol. Under its
existing Full Mac/file-read admission, the app reads a stable private copy of
the admitted Default profile's History/WAL/journal, independent of extension
connection or profile. The extension declares no `history` permission. See the
[Chrome surface contract](../README.md) for capture, aggregation and failure behavior.

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
the app's image slot shows); Chrome's debugging infobar lasts only for the
capture attachment. A capture error or empty data returns `tab_not_painted`:
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
URL changes and MutationObserver notices trigger bounded captures; no polling
or tab creation occurs. Change generation and reading view are page state stored in
session storage, independent of tab ownership. Explicit reads supersede passive
captures. Every DOM capture carries the aggregate page's worker-local document
generation. Any frame commit advances that generation; one synchronous
publish-if-current helper checks it before registering routes, retaining the
read's view, returning its result, or emitting `page.changed`. A replaced
frame's late reply is discarded even if it arrived before its local snapshot
key could be recorded. Superseded passive captures retain pending work;
replacement documents wait for frame readiness, with no retry clock.
`page.invalidated` supplies `tabId` at navigation dispatch, top-document or
subframe commit, and ownership end. The app discards its subscription snapshot
and prevents already-pending replies from republishing that baseline. An
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
reconnects, and never grants ownership or persists to disk.

Host cancellation is a transport event `action.cancel` with
`payload: {requestId}`. It stops only that in-flight action, preserves group
ownership, and introduces no model verb.

The sole repeating Chrome alarm reconnects native messaging when the app is
absent or the transport is disconnected. It holds no ownership state.
An app request belongs to one channel. Disconnection returns that request's
original outcome and connection remedy; it never resubmits on a replacement
channel. A dispatched mutation with no confirmation remains outcome unknown.
