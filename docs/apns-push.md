# Phone alerts and optional APNS wakes

Ordinary phone alerts use CloudKit's visible query subscription. The distributed
Mac app and App Store iPhone app require the person's Apple Account, pairing and
iPhone notification permission, with no Apple developer account, provider keys
or `config/apns.json` on the person's Mac. CloudKit builds the visible title and
body from the notification record; presentation does not require iOS to run the
app or its signed reader first. Apple delivery, notification settings and Focus
still govern presentation; publication is not proof that a banner appeared.

Event kind selects exactly one renderer before transport:

| Event | CloudKit record | Visible renderer |
|---|---|---|
| Ordinary notification (`kind: notification`, source other than `requested_result`) | `NANotification` | CloudKit `NANotification.visible` |
| Requested result (`kind: notification`, source `requested_result`) | `NAChatMessage` | Existing signed bridge notification reader on the phone |
| Other chat/control message | `NAChatMessage` | Its existing consumer; no CloudKit alert |

The record-family choice reads the signed message's existing metadata, not an
APNS outcome or a second routing flag. Both record families are pulled into the
same signature verification and consumer boundary. The requested-result
envelope, settlement timestamp, local rendering and deduplication stay unchanged.
Ordinary records acknowledge `icloud_bridge_record` receipt without posting a
local notification, including when their CloudKit alert has not arrived.

`NANotification.visible` fires only on creation where `direction == mac2ios`.
Within this record family only ordinary notification envelopes carry that
direction; pairing presence records omit it and cannot produce an alert.
Its title localization argument is
`notificationTitle`, its body argument is `text`, sound is `default`, and
`notificationEventId` is the collapse key. Its three desired keys are
`notificationScreen`, `notificationEventId` and `kind`. Mutable content lets the
notification service extension read that exact record's envelope for navigation
and actions; the extension completes the existing remote request, never posts
another. The title/body already exist in the remote alert if no extension runs.
CloudKit may truncate localization arguments over 100 characters. Ordinary
CloudKit alerts use the system's default interruption level; the signed
requested-result reader retains its existing urgency handling. The router writes
`userInfo.urgency` only for requested results (CloudKit does not consume it on
ordinary alerts), and adverse
importance bypasses NativeAgent's quiet-hours hold without promising to bypass
iPhone Focus. The chat,
pairing and status subscriptions remain silent.

`MacSyncMobileNotificationRelay.sendNotification` retains and publishes one
signed event before optionally sending a direct APNS **background** wake at
priority 5. Direct APNS carries only `content-available`, with
`nativeAgentWake: notification`; it never contains an ordinary or requested-result
alert, sound or mutable-content request. A missing provider config skips this
optional wake without an error. Existing unreadable or invalid configuration,
token reads, provider rejections and unknown wake outcomes remain diagnostic
`apnsErrors`; none select another renderer or negate the accepted record.
`phone_alert_unconfirmed` is removed. Without an active CloudKit transport an
ordinary notification fails at publication rather than claiming a Drive record
will produce a CloudKit alert.

Before transport, immutable title, body, userInfo and timestamp are retained in
`notifications/publications/<eventId>.json` under a per-event lock (five-second
acquisition limit). Retries send the retained publication itself, byte for byte
(its title, body, userInfo and timestamp); an incoming attempt must match its
words, and a requested result its settlement time. Retained bytes are preserved. Conflicting or
unreadable publication state reports `notification_publication_unavailable`
with its bytes preserved. Exact server replay proof re-signals the existing
record rather than creating a second event, including when an already-published
requested result occupies the notification record family. Re-signalling an
ordinary record is an update and cannot trigger its creation-only alert again.
Requested results keep their owner's `resultCreatedAt` timestamp.

Foreground chat reply presentation remains conversation-scoped: `willPresent`
suppresses the banner and sound for the visible conversation, retaining alerts
for other conversations. The extension resolves the exact record's session
when it runs. Missing session evidence does not suppress an alert.

## Release preparation and phone compatibility

The distributor, not the person installing the apps, prepares the subscription
shapes in Development and deploys them to Production. Keep the IDs, record types,
predicates, fire options and notification settings identical to source. The
existing record schema already contains every field this path uses; no schema
change or new index is required. `NANotification.direction` is already queryable;
`kind`, `notificationTitle` and `notificationEventId` are not, so they are not
used as predicate fields. Requested results use the separate chat family.
Production `serverRejectedRequest` is not evidence a subscription exists:
registration verifies the complete server shape and surfaces failures.
No failed subscription enables another alert renderer.
Chat and visible-alert subscriptions are ensured independently, each with its
own bounded registration and named failure. A visible-alert rejection cannot
prevent chat registration. Incoming observation's readiness result describes
the chat subscription alone; a visible-alert failure remains separately logged
under `NANotification.visible`, never presented as a chat-wake failure.

**PHONE BREAK — coordinate the Mac install and TestFlight 38.** Build 37
(`56e14f53a6`) locally renders ordinary notification records when the Mac omits
`directAlertDeviceIDs`. Installing the visible subscription alongside build 37
can therefore show both its remote alert and 37's local alert. Build 37 can also
repair the shared subscription back to its silent shape. Ship/open 38 and retire
37 before enabling this Mac/subscription revision; the Mac and phone both
reconcile the same subscription ID. No compatibility flags or dual rendering
paths are retained. Moving new requested results into `NAChatMessage` preserves
37's signed reader; removing direct APNS ordinary alerts removes that former
visible path for a keyed Mac. A phone still using 37 must not be used to approve
this revision's no-duplicate result.

## Optional direct APNS configuration

Private/self-hosted installations may configure `<dataRoot>/config/apns.json`
to accelerate sync with silent wakes (and separately support their opt-in work
Live Activities):

```json
{
  "team_id": "YOUR_APPLE_TEAM_ID",
  "key_id": "YOUR_APNS_KEY_ID",
  "key_path": "/absolute/private/path/AuthKey_YOUR_APNS_KEY_ID.p8"
}
```

Never bundle the private key. This configuration is optional and is not an
end-user setup step. Only a proven missing configuration file means unconfigured;
an existing malformed/unreadable configuration or missing/unreadable/invalid key
reports unavailable with its cause. The sender reads exactly `key_path`; it never
searches for a differently named key.

Optional `topic` and `environment` fields constrain the registered targets. Omit
them to use each phone's required `bundleId` and `environment`; a present field
must be a nonempty string. Environments are exactly `production` or `development`
at configuration, registration and send time. No `prod`, `sandbox`, `auto`, case
conversion or invented environment is accepted. Push registration requires the
current `deviceId`, `environment` and `bundleId` fields. Work Live Activity pushes
are separate from ordinary events and retain their existing opt-in behavior.
Optional-wake token reads use one checked mode for all callers.
Unreadable/malformed store contents fail that read; an invalid device row reports
its own unavailable cause and leaves valid sibling targets eligible. There is no
separate Doctor mode.

Notification readiness, pairing/access pages, connector status and the body’s
phone target count read the checked paired-phone authority. A paired keyless
installation is ready through iCloud; no pairing means setup is needed, and
unreadable pairing authority reports unavailable. Ready describes route support,
not delivery or display proof. Optional wake tokens, credentials and provider
outcomes do not gate ordinary notification readiness. Doctor reads the same
authority; optional wake failures remain in the sender's delivery diagnostics.
The body's notification belief reads the live kernel's current delivery
prediction: publication failures and signed phone receipts, never
`mobile_push/apns_outcomes.jsonl`. No prediction, a pending publication or an
expired receipt expectation supplies no terminal delivery evidence. The
`notificationPathHealthy` projection is optional: absent delivery evidence clears
it to unknown, including an unconfigured transport; a current signed receipt
supports true and publication failure supports false. Peer contact changes
reachability alone, never notification health. Publication alone
does not prove phone receipt, display or user attention. A keyless send
does not create an APNS outcome, and an old APNS row cannot judge this path.

**PHONE BREAK:** the living-status body's `notificationPathHealthy` is now an
optional Boolean (omitted when unknown), decoded by the shared
`OrganismLivingBodyFile` used in the iOS snapshot reader. Update Mac and phone
together so unknown delivery remains unknown rather than failing a required
Boolean decode. The authenticated bridge emits JSON null for unknown.

## Delivery evidence

Optional wake fan-out retains an `unknown` receipt for every target before any
send, using the same event and APNs IDs as its eventual result, in
`mobile_push/apns_outcomes.jsonl`. Admission checks cancellation; after admission
one independent task owns all sends and final receipts. The caller joins that
task through URLSession's five-second request-idle and thirty-second resource
limits. The former five-second observation race, cancellation of outstanding
writes and rejection of late HTTP answers are removed. HTTP responses remain
`ok` or `failed`; a missing HTTP answer stays `unknown`, including a transport
timeout. No automatic resend follows uncertainty. A final receipt-write failure
returns an explicit unsettled-receipt error and leaves the retained unknown
record; a failed initial receipt write prevents admission. The body reader never
turns unknown/omitted receipts or diagnostic errors into a provider rejection.

Work-start reservation retirement remains gated by retained-format evidence:
the pre-reservation reader is still required while saved registrations lack
`startOutcomes` or `startReservations`. No historical start time is established
by an absent activity or provider answer. Retiring that reader and its adoption
loop requires reconciling retained starts first; it is not done by this change.

Receipts report `delivery: queued_to_icloud_bridge`, the bridge message/event
IDs and `route: cloudkit_visible_notification` for ordinary alerts or
`mac_icloud_bridge_notification` for requested results. `apnsPushType` is
`background`; absent optional credentials produce empty APNS receipts/errors.
`apnsAccepted` proves only wake acceptance. `lockScreenDisplayVerified` stays
false. A signed phone receipt in `icloud/chat_delivery_receipts.jsonl` confirms
receipt of the record, not display. A late or absent receipt remains unconfirmed;
it never proves failed display or authorizes another visible mechanism.

After the coordinated install, send one benign `notify.phone` event on a Mac
with no APNS config and a locked phone running 38. Confirm its queued receipt
and exactly one matching title/body on the phone, then open the phone and check
the same event's signed receipt. Subscription verification, transport acceptance
and the signed receipt alone cannot establish the visible count.

## Source owners

- `DeviceSync/MacSyncMobileNotificationRelay.swift` — immutable publications,
  registration mutations and event receipts.
- `DeviceSync/APNSNotificationDelivery.swift` and `APNSNotificationReadiness.swift`
  — optional APNS wake effect, provider configuration and diagnostics.
- `DeviceSync/MobileNotificationDeliveryReceipt.swift` — publication/wake receipts.
- Shared `CloudKitDeviceTransport+Messages.swift` and `+Subscriptions.swift` —
  record-family selection, exact replay and subscription registration/repair.
- iOS `MobilePushNotifications.swift` and `NotificationService.swift` — signed
  reader projection, ordinary record acknowledgement and remote-request preparation.
