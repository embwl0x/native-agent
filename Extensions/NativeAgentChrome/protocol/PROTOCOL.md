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
Navigation uses `chrome.tabs.update` without an activation request. Snapshot,
click, fill, type, select, keypress, checked-state, double-click, element waits,
and scroll are handled by isolated content agents; navigation settlement and
frame aggregation remain in the service worker. Stale
snapshots, missing leases, and nodes that did not advertise the requested
action fail closed. A fill/type message whose reply disappears after dispatch
returns `outcome_unknown` and is never automatically retried.

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
The service worker walks every permitted Chrome frame, aggregates one bounded
snapshot with frame/parent metadata, and routes opaque global node ids back to
the owning frame. Each content agent recursively walks light DOM plus open
shadow roots; closed shadow roots and unavailable frames remain honestly
inaccessible. Every truncation or unavailable-frame reason is reported.
Password/secure fields expose neither
their value nor a selector. The protocol never exposes cookies, storage,
passwords, history, arbitrary JavaScript, or unrestricted CDP.
