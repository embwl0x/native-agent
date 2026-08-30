# NativeAgent Chrome protocol v1

The extension connects to the native-messaging host
`com.nativeagent.chrome`. Native messaging is transport only: the Swift relay
does not interpret messages, while NativeAgent.app remains the authority for
admission and effect-time Trust Center policy. The extension owns Chrome tab
leases and page primitives, but no user policy.

Every host request is a single JSON object:

```json
{
  "version": 1,
  "type": "request",
  "id": "request-uuid",
  "action": "page.snapshot.read",
  "payload": { "leaseId": "lease-uuid" }
}
```

Responses echo `id` and `action`, set `ok`, and carry exactly one of `result`
or `error`. Unsolicited extension events use `type: "event"` and have no
request id. See `protocol-v1.schema.json` for the machine-readable envelope.

Combined frame snapshots retain bounded in-flight invalidation evidence and
recheck the active lease before publication. A frame mutation during capture
returns `snapshot_stale`; a newer capture or navigation returns
`snapshot_superseded`. Old captures cannot publish dead routes after a newer
snapshot or user takeover.

## Actions

| Action | Required payload | Result or behavior |
|---|---|---|
| `attach` | none | Negotiates protocol, extension version, host id, and capabilities. |
| `lease.acquire` | `mode` (`create` or `claim`), optional `leaseDurationMs` | Creates an inactive tab or claims an exact existing tab. Claim requires `tabId` plus exact expected URL/title. The default lease is 60 seconds and the bounded range is 30–300 seconds, matching Chrome's production alarm floor. |
| `lease.renew` | `leaseId`, `expectedUserSequence`, optional `leaseDurationMs` | Extends an active lease from the current instant and emits `lease.renewed`. |
| `lease.resume` | `leaseId`, `expectedUserSequence` | Reserved compatibility action. It returns `lease_resume_not_supported`: user yield is terminal, so the host must explicitly reacquire the exact tab. |
| `lease.release` | `leaseId` | Releases a claimed tab; closes an agent-created tab unless `closeCreatedTab` is false. |
| `navigate` | `leaseId`, `expectedUserSequence`, HTTP(S) `url` | Navigates only the leased tab. |
| `page.snapshot.read` | `leaseId` | Returns the structured page snapshot below while the lease remains active. |
| `page.element.click` | `leaseId`, `expectedUserSequence`, `snapshotId`, `nodeId` | Clicks a node from the exact observed snapshot. No arbitrary selector crosses the protocol. |
| `page.element.fill` | `leaseId`, `expectedUserSequence`, `snapshotId`, `nodeId`, `value` | Replaces a current non-password editable node value and returns one outcome receipt. |
| `page.element.type` | `leaseId`, `expectedUserSequence`, `snapshotId`, `nodeId`, `text` | Appends text sequentially to a current non-password editable node and returns one outcome receipt. |
| `page.element.select` | `leaseId`, `expectedUserSequence`, `snapshotId`, `nodeId`, `values` | Selects exact native-option values on a current node that advertised `select`. |
| `page.element.keypress` | `leaseId`, `expectedUserSequence`, `snapshotId`, `nodeId`, `key` | Sends one bounded key/chord to a current non-password node that advertised `keypress`. |
| `page.element.set_checked` | `leaseId`, `expectedUserSequence`, `snapshotId`, `nodeId`, `checked` | Idempotently applies an exact checkbox/radio/switch state. |
| `page.element.double_click` | `leaseId`, `expectedUserSequence`, `snapshotId`, `nodeId` | Performs one double-click act on a node that advertised it. |
| `page.wait` | `leaseId`, `expectedUserSequence`, `condition` | Waits up to ten seconds for an advertised node state or leased-tab navigation settlement and returns one observational receipt. |
| `page.scroll` | `leaseId`, `expectedUserSequence`, `deltaX`, `deltaY` | Scrolls the page or `targetNodeId`; a supplied node is bound to `snapshotId`. |

`lease.acquire` persists the active lease before returning and emits
`lease.granted`. `lease.renew` persists its new expiry before returning and
emits `lease.renewed`. All page mutations carry `expectedUserSequence`.

A trusted pointer, keyboard, wheel, or touch event in the leased page—or
activation of its tab—terminally removes the lease from session storage and
emits:

```json
{
  "version": 1,
  "type": "event",
  "event": "lease.yielded",
  "occurredAt": "2026-08-18T12:00:00.000Z",
  "payload": {
    "leaseId": "lease-uuid",
    "tabId": 123,
    "reason": "user_scroll",
    "userSequence": 1
  }
}
```

The extension leaves the tab open on user yield, including an agent-created
tab, so it never closes a surface underneath the user. Explicit release closes
an inactive agent-created tab by default; an active tab and every claimed tab
are left open. Expiry releases the lease and closes only an untouched,
still-inactive agent-created tab. Tab closure emits
`lease.released` with reason `tab_closed`.

Lease records live in `chrome.storage.session`, are validated against live tabs
after an MV3 worker restart, and use one-shot Chrome alarms for expiry. The
extension refuses a stale sequence or missing lease instead of guessing.
Page effects and renewal check `expiresAt` at use time, not only when Chrome's
expiry alarm is delivered. A late alarm cannot extend an expired lease or
allow renewal to resurrect it. Explicit release remains available after expiry
for orderly cleanup, including preserving the tab with `closeCreatedTab: false`.
Navigation uses `chrome.tabs.update` without an activation request. Its
completion is bound to the current per-tab request and rechecks the
existing active lease after each wait and before returning. A superseding
navigation or takeover after dispatch returns `outcome_unknown` with no
automatic retry. `requestedUrl` remains distinct from the observed final `url`
so redirects remain supported; a complete tab observation is explicitly
`verified: false`, not proof that the requested navigation's intended outcome
was achieved. Navigation-settlement waits reread the exact tab after their
settle interval and never verify a cached completion event.
Snapshot,
click, fill, type, select, keypress, checked-state, double-click, element waits,
and scroll are handled by isolated content agents; navigation settlement and
frame aggregation remain in the service worker. Stale
snapshots, missing leases, and nodes that did not advertise the requested
action fail closed. A fill/type message whose reply disappears after dispatch
returns `outcome_unknown` and is never automatically retried.

Typing accepts the requested text but executes for at most twenty seconds or
the remaining lease lifetime, leaving time for its reply inside the host's
thirty-second deadline. It checks the same field's identity, editability,
visibility, lease expiry/revocation, and trusted user takeover before each
character. Zero-delay typing yields every 32 code points. Cancellation releases
the lease without closing the tab; release/yield events stop active page loops.

A bounded type reply reports `completed`, `characterCount`,
`requestedCharacterCount`, `remainingCharacterCount`, `stopReason`, and
`elapsedMs`. Character counts and `nextCharacterIndex` are Unicode code-point
positions; `nextUTF16Offset` is a safe offset into the original JavaScript
string and never splits a surrogate pair. A partial receipt uses
`partially_completed` and `fresh_snapshot_then_remaining_text_only`: observe a
fresh snapshot before continuing only the untyped suffix. Never blindly resend
the original full text. Counts acknowledge append effects, not verified final
page state; the receipt keeps `page_acknowledged` distinct from verification.

## Structured page snapshot

The snapshot is an agent-facing accessibility/DOM read model, not raw HTML.
Node ids are opaque, snapshot-scoped references. A later action must present
both the `snapshotId` and `nodeId`; a navigation, DOM generation change, or
user-sequence change invalidates them.

```json
{
  "snapshotId": "snapshot-uuid",
  "leaseId": "lease-uuid",
  "tabId": 123,
  "userSequence": 0,
  "capturedAt": "2026-08-18T12:00:00.000Z",
  "url": "https://example.com/",
  "title": "Example",
  "language": "en",
  "viewport": {
    "width": 1440,
    "height": 900,
    "scrollX": 0,
    "scrollY": 640,
    "documentWidth": 1440,
    "documentHeight": 5000
  },
  "summary": {
    "text": "Bounded readable page text in visual reading order.",
    "nodeCount": 2,
    "truncated": false,
    "truncationReasons": []
  },
  "frames": [
    {
      "frameId": 0,
      "parentFrameId": -1,
      "url": "https://example.com/",
      "name": "Example",
      "accessible": true,
      "nodeCount": 2
    }
  ],
  "nodes": [
    {
      "nodeId": "n1",
      "parentNodeId": null,
      "frameId": 0,
      "kind": "heading",
      "role": "heading",
      "name": "Latest posts",
      "text": "Latest posts",
      "value": null,
      "level": 1,
      "visible": true,
      "states": {
        "disabled": false,
        "checked": null,
        "selected": null,
        "expanded": null,
        "editable": false
      },
      "actions": [],
      "url": null,
      "bounds": { "x": 24, "y": 80, "width": 300, "height": 40 },
      "scrollable": false
    },
    {
      "nodeId": "n2",
      "parentNodeId": null,
      "kind": "button",
      "role": "button",
      "name": "Load more",
      "text": "Load more",
      "value": null,
      "level": null,
      "visible": true,
      "states": {
        "disabled": false,
        "checked": null,
        "selected": null,
        "expanded": null,
        "editable": false
      },
      "actions": ["click"],
      "url": null,
      "bounds": { "x": 600, "y": 820, "width": 120, "height": 36 },
      "scrollable": false
    }
  ]
}
```

The implementation caps node count (500), readable summary text (50,000
characters), individual strings, aggregate node text, and frame count (64).
The combined snapshot also fits within 1,000,000 actual UTF-8 JSON bytes,
leaving room for the response envelope below the relay's 1,048,576-byte limit.
If necessary, a prefix of nodes is retained with its exact routes and parent
references, per-frame/summary counts are corrected, and truncation reports
`encoded_size_limit`. Metadata alone that exceeds the budget returns an
explicit `snapshot_metadata_too_large` error instead of dropping the transport;
exact URL identity is never silently shortened to fit.
The service worker walks every permitted Chrome frame, aggregates one bounded
snapshot with frame/parent metadata, and routes opaque global node ids back to
the owning frame. Each content agent recursively walks light DOM plus open
shadow roots; closed shadow roots and unavailable frames remain honestly
inaccessible. Every truncation or unavailable-frame reason is reported.
Password/secure fields expose neither
their value nor a selector. The protocol never exposes cookies, storage,
passwords, history, arbitrary JavaScript, or unrestricted CDP.
