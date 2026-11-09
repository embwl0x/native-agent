# Runtime diagnostic storage limits

`PersistenceCore/FeedPolicy.swift` defines shared feed limits;
`PersistenceCore/JSONLRetention.swift` selects rows once under the append lock,
applying the line policy before the byte policy and publishing the result once.

| Feed | Row rotation | Byte rotation |
|---|---|---|
| `activity/events.jsonl` | 5,000 → 4,000, preserving rare event kinds | No hard byte cap in this policy |
| `telegram/receipts.jsonl` | 5,000 → 4,000 | No hard byte cap in this policy |

Activity and Telegram receipt row checks run on the first append and then every 128 appends,
so their row triggers can overshoot by 127. An oversized incoming diagnostic row is refused;
inherited unreadable diagnostic bytes are preserved and appends that would
cross the ceiling are refused.

Turn traces and standalone receipts are details in `experiences/experiences.sqlite`;
the record forgets details older than `ExperienceStore.detailHorizon` (14 days) and
refuses a detail row over 8 MiB. `TurnTraceEvent.swift` summarizes ordinary
turn-trace payloads at 12 KiB; `llm.call` receipts use the detail owner's 8 MiB
row ceiling. A `context.snapshot` retains its complete first-class `feelingFrame`
alongside that ordinary summary, also within the shared 8 MiB row ceiling.
The paragraph is redacted before recording and is exempt from per-string,
preview and 120-byte cue clipping. The retained field is identical on trace
readback; an oversized detail write fails explicitly. Its measurement contract
is in [Subconscious](SUBCONSCIOUS.md#what-reaches-the-model).

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

`diagnostics/cutoffs/<turn-or-UUID>[-UUID].txt` belongs to
`ProviderOutputDiagnostics.writeDiagnostic`: redacted reason and output, with
the character count. The writer returns and logs its path. It keeps the newest
100 text files on write and reports retention failures.
Every Codex call retains its complete produced text here at exit and pipe EOF,
including after a buffered or streaming caller stops waiting. The
`codex.reply.produced` detail in `experiences/experiences.sqlite` carries the file path, bounded preview and any
process or recording cause.

This path is not selected for local backup, production export or a raw phone
snapshot; PrivacyMap inventories its parent folder. It is a diagnostic review
candidate, not a proven orphan merely because no dedicated in-app content reader
exists. `user_prefs.json` retains live readers and is not an orphan store.

Source paths above are under `Modules/NativeAgentCore/Sources/`.

## Notification inbox

The inbox is a reading of the experiences addressed to them (`Experiences/ForPerson.swift`), held in memory: open
matters plus those settled in the last 30 days, newest 500. Nothing is evicted from the record; the reading only
forgets settled matters past its bound. There is no inbox file, archive shelf or delivery ledger. An unreadable
record fails the read with its cause; the Mac keeps its previous published cards with the read error, and a phone
snapshot receives the checked read result.

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

The execution link is `related_execution_id`; it is the only key read. Backlog
scanning consumes that same checked card's links and declared actions. Presentation prose never supplies approval controls.
