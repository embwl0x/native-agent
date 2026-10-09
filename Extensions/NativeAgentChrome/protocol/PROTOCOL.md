# Chrome control protocol v1

Native messaging host: `com.nativeagent.chrome`. Messages are JSON objects with
`version: 1`, `type`, and a bounded stable request `id`. A request supplies
`action` and `payload`; its response repeats `id` and `action`, supplies `ok`,
and contains either `result` or `{code, message, details?}` in `error`.
Events supply `event`, `occurredAt` and `payload`.

The Chrome `NativeAgent` group owns tabs. Tabs outside that group belong to
User. Every read or action checks the tab's current Chrome group. Trusted input,
activation, and address-bar navigation immediately revoke control and ungroup
that tab. Group membership survives app, service worker and extension restart.
Only an explicit `tab.close` request closes an owned tab.

| Action | Payload | Behavior |
| --- | --- | --- |
| `attach` | Optional `clientName`, `clientVersion` | Returns `connected: true`, host/protocol/extension identity, `capabilities`, `lastExtensionError`, and `tabs` with `tabId`, `windowId`, `groupId`, `title`, `url`, `userSequence`. Reinstalls the existing readers in grouped tabs. |
| `extension.reload` | `reloadId` | Acknowledges `reloadId`, `beforeVersion`, `status: "acknowledged"`, then reloads. A progressing request refuses reload with `extension_busy`; failure emits `extension.reload_failed`. No tab changes. |
| `navigate` | `url`; optional `tabId`, `expectedUserSequence` | Reuses the owned tab, or creates an inactive grouped tab if missing or no longer owned. HTTP(S) URLs only; `back` and `forward` require an owned tab and walk its history. |
| `tab.close` | `tabId`; optional `expectedUserSequence` | Explicitly closes an owned tab. |
| `page.snapshot.read` | `tabId`; optional `expectedUserSequence`, `readCursor`, `maxNodes`, `maxTextChars`, `scope` | Reads structured rendered DOM material without scrolling. |
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

Snapshot IDs and node IDs are action proofs, never selectors. Snapshots include
`tabId`, `userSequence`, `capturedAt`, URL/title/language, viewport, summary,
nodes and frames. Each node's `elementIdentity` is stable for that DOM element
within the document. Replacement documents/elements receive new identities.
Frames and open shadow roots retain exact routing and identity. A captured
frame mutation invalidates its old routes; retained navigation nodes still
require their local identity proofs. Transport truncation preserves sections,
paragraphs and inline link references, with an honest continuation.

`scope` is `page` or `main_content`. `readMore` and node `more` addresses can be
supplied as `readCursor`, including structural element paths, text/option
offsets and embedded frame addresses. These addresses describe reading, never
authorize mutation. Scroll receipts return a local `viewportObservationId`
bound to that tab and target; the following read reports actual viewport
change. `rendering` reports visibility, readiness and `rendered_dom_only`.

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
NativeAgent groups. `tab.yielded` supplies `tabId`, `userSequence`, and `reason`; it invalidates
snapshot routes and in-flight typing/waits without closing the tab.

Host cancellation is a transport event `action.cancel` with
`payload: {requestId}`. It stops only that in-flight action, preserves group
ownership, and introduces no model verb.

The sole repeating Chrome alarm reconnects native messaging when the app is
absent or the transport is disconnected. It holds no ownership state.
