# Runtime diagnostic storage limits

`FeedPolicy/FeedPolicy.swift` defines shared feed limits;
`PersistenceCore/JSONLRetention.swift` enforces them under the append lock.

| Feed | Row rotation | Byte rotation |
|---|---|---|
| `traces/events.jsonl` | 5,000 → 4,000 | 8 MiB → 4 MiB |
| `activity/events.jsonl` | 5,000 → 4,000, preserving rare event kinds | No hard byte cap in this policy |
| `turn_traces/<day>.jsonl` | 20,000 retained; checked on first append and every 4,096 appends | 12 MiB → 8 MiB |

Trace/activity row checks run on the first append and then every 128 appends,
so their row triggers can overshoot by 127. The shared trace byte ceiling is
checked on every append. An oversized incoming diagnostic row is refused;
inherited unreadable diagnostic bytes are preserved and appends that would
cross the ceiling are refused.

`TurnTraceRetention.swift` removes date-named turn ledgers older than its
14-day window. Each persisted turn-trace row is bounded to 12 KiB by
`TurnTrace.swift`.

`Browser/BrowserCaptureCache.swift` owns temporary page text, links and
screenshots. Captures share 128 MiB, 256 groups and seven days, enforced on
writes. One artifact is limited to 16 MiB and one group to 32 MiB. Matching
artifacts are evicted together. Unknown files and symlinks are excluded;
downloads, generated images and user documents are outside this cache.

The daily `DataRootDiskHygieneCheck` reports oversized state; it does not
automatically delete it or enforce a global quota. Chat recovery backups have
their own five-per-session policy; see [Data bounds](data-bounds.md).

Source paths above are under `Modules/NativeAgentCore/Sources/`.
