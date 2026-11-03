# Runtime diagnostic storage limits

`PersistenceCore/FeedPolicy.swift` defines shared feed limits;
`PersistenceCore/JSONLRetention.swift` selects rows once under the append lock,
applying the line policy before the byte policy and publishing the result once.

| Feed | Row rotation | Byte rotation |
|---|---|---|
| `traces/events.jsonl` | 5,000 → 4,000 | 8 MiB → 4 MiB |
| `activity/events.jsonl` | 5,000 → 4,000, preserving rare event kinds | No hard byte cap in this policy |
| `telegram/receipts.jsonl` | 5,000 → 4,000 | No hard byte cap in this policy |
| `turn_traces/<day>.jsonl` | 20,000 retained; checked on first append and every 4,096 appends | 12 MiB → 8 MiB |

Trace/activity and Telegram receipt row checks run on the first append and then every 128 appends,
so their row triggers can overshoot by 127. The shared trace byte ceiling is
checked on every append. An oversized incoming diagnostic row is refused;
inherited unreadable diagnostic bytes are preserved and appends that would
cross the ceiling are refused.

`TurnTraceRetention.swift` removes date-named turn ledgers older than its
14-day window. Each persisted turn-trace row is bounded to 12 KiB by
`TurnTraceEvent.swift`, except `llm.call` rows, which keep the 8 MiB allowance
`PersistenceCore` grants a model exchange.

`Browser/BrowserCaptureCache.swift` owns temporary page text, links and
screenshots. Captures share 128 MiB, 256 groups and seven days, enforced on
writes. One artifact is limited to 16 MiB and one group to 32 MiB. Matching
artifacts are evicted together. Unknown files and symlinks are excluded;
downloads, generated images and user documents are outside this cache.

`AppToolRuntime/AppToolExecutor+PagePresentation.swift` bounds offscreen page pictures in
`diagnostics/page_shots/` to seven days, 64 PNGs and 64 MiB on each write.
The current delivery is protected; inline continuations own their pixel bytes.
These are replaceable diagnostics, separate from authored images.

The daily `DataRootDiskHygieneCheck` reports oversized state; it does not
automatically delete it or enforce a global quota. Chat recovery backups have
their own five-per-session policy; see [Data bounds](data-bounds.md).

## Recovery and cutoff artifacts

| Path | Owner and content | Retention |
|---|---|---|
| `turn_traces/<day>.jsonl.doctor-preserved-<UUID>.bak` | `TurnTracePersistLane.salvageValidRows`: original bytes before an explicit Doctor repair | No automatic expiry; date-named ledger retention does not select these copies |
| `diagnostics/cutoffs/<turn-or-time>[-UUID].txt` | `RunawayOutputDetector.writeDiagnostic`: reason, character count and raw output; returns and logs its path | Existing writer keeps the newest 100 text files on write |

Neither path is selected for local backup, production export or a raw phone
snapshot; PrivacyMap inventories their parent folders. They are recovery and
diagnostic review candidates, not proven orphans merely because no dedicated
in-app content reader exists. `traces/events.jsonl` and `user_prefs.json`
retain live readers and are not orphan stores.

Source paths above are under `Modules/NativeAgentCore/Sources/`.

## Notification inbox

`NotificationInbox/LiveNotificationInbox.swift` owns
`notifications/inbox.jsonl`. Its 500-row target counts only rows without
outstanding delivery intents, as checked against `notify/deliveries.json`.
`held_delivery` is source intent, not a second delivery receipt. Rows with no
ledger evidence or with pending/unknown current destinations remain protected;
settled or superseded occurrences no longer pin their card. Protected rows are
exempt from both the row target and the 30-day terminal-card cutoff; there is no
hard total-row limit. Each mutation evicts at most 200 rows,
so a backlog converges over subsequent writes. Every eviction reaches the
uncapped `notifications/inbox_archive.jsonl` shelf before the live rewrite.

The delivery ledger retains occurrence identities and outcomes without eviction;
discarding an unknown or accepted receipt must not reauthorize its effect.
It is local delivery evidence, not another inbox or a phone snapshot.

The physical reader checks every line against `InboxItemRecord`'s current
shared card schema. Missing/mistyped required fields, invalid timestamps or
status, and malformed action lists make the complete feed unavailable with
the line number and underlying cause. A whole-feed mutation requires that
complete read and validates its output before retention or writing. It never
rewrites a shortened projection over damaged bytes. The Mac keeps its previous
published cards with the read error; a phone snapshot receives the checked read
result. An actually missing or empty file is an empty inbox.

Morning briefs use this same checked owner and the latest physical card per id
for unread counts. An unreadable feed supplies unavailable evidence and its
cause to the brief, with no unread count; the seed never invents card state.

Actions belong to the filing producer: an explicit empty list stays empty;
readers do not invent executable controls. The phone always offers local Read
navigation to the card's own detail, including approval payload previews and
Doctor repair instructions. Opening detail changes read status only when the
producer declares `read`. Signed phone dispatch requires an explicit supported
action and returns `invalid_action`
for missing or unsupported operations. A completed quiet inbox write stays in
`done` even if readback fails or its card leaves the live feed: verification is
`unknown`, with the actual read error when present. Only an observed conflicting
status produces `did_not_stick`.

The current execution link is `related_execution_id`. The single retained
`related_mission_id` reader remains in `InboxItemRecord` because live cards still
carry that key (read-only inventory, 2026-11-01); no data conversion is performed
by a read. Backlog scanning consumes that same checked card's links and declared
actions. Presentation prose never supplies approval controls.
