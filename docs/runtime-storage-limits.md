# Runtime diagnostic storage limits

The September 21 disk report measured 2149.62 MB written in 901 seconds,
not 2 GB of newly retained data. Chemistry history rewrote its entire retained
20,000-row window on each append; mature tool traces also repeatedly rewrote
their retained window. This finding does not establish the cause of the later
whole-Mac freeze.

`PersistenceCore/JSONLRetention.swift` owns append transactions and retention:

| Disposable feed | Row rotation | Hard bytes | Byte rotation target |
|---|---|---|---|
| Chemistry samples | 20,000 → 16,000 | 8 MiB | 6 MiB |
| Shared tool traces | 5,000 → 4,000 | 8 MiB | 4 MiB |
| Activity events | 5,000 → 4,000, retaining rare event kinds | Existing row policy only | — |

Amortized row checks run on the first append and every 128 appends, including
when a file remains above its soft byte trigger. The row trigger may therefore
overshoot by 127 rows. Hard byte ceilings are checked on every append for the
two opted-in diagnostic feeds. Oversized incoming rows are refused before
writing; unreadable inherited diagnostic data is preserved and further appends
are refused at the ceiling. Ordinary evidence/audit retention keeps its existing
oversized-newest-row behavior. Authoritative organism state is unchanged.

`Browser/BrowserCaptureCache.swift` owns temporary browser source, links, and
screenshot artifacts. Captures share 128 MiB, 256 capture groups, and seven-day
retention, enforced on writes. One artifact is limited to 16 MiB and one group
to 32 MiB. Text, links, and screenshot files share an identity for eviction;
receipts identify these paths as expiring observations. Unknown files, symlinks,
downloads, generated images, and user documents are excluded.

Existing daily turn-trace limits remain 12 MiB → 8 MiB with 14-day retention;
compaction backups retain five per session. The daily data-root hygiene check
is an alert, not a global storage quota. User memory, conversations, creative
output and documents are not disposable diagnostics. Developer build caches
are separate from runtime storage and are not deleted by these policies.

User requested verification on the installed app, without separate test builds
or suites. Use lightweight installed file metadata/process I/O observations
and bounded actions. Do not repeat Mail, Messages, or agent conversation
workloads to load-test this fix on the operator's Mac.
