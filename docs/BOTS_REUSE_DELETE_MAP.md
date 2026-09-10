# Standing helpers: reuse / delete map

User's and Agent's September 9 definition is authoritative: a saved brief, explicit
provider choice and timing, one ordinary persisted session, and dated replies.
Stage 2 implements the runtime dispositions below. Stage 3 connects the production
tab to those owners behind the unchanged default-off rail flag.

| File | Disposition |
| --- | --- |
| `StandingBots/BotDefinitionStore.swift` | KEEP reshaped — explicit model/think/fast, timing including manual only, editable limits, notification choice, session ID; migrate sources into brief text without losing existing values. |
| `StandingBots/StandingBotsModels.swift` | KEEP reshaped — definition and reply/status/artifact values; delete fetched-source, book-schema, evidence-sidecar and answer-policy types; decode old shelf entries without erasing history. |
| `StandingBots/StandingBotsDisk.swift` | KEEP reshaped — preserve checked storage, atomic writes and path protection; validate storage and execution settings only, never answers; support manual timing. |
| `StandingBots/BotRunner.swift` | KEEP reshaped — submit one ordinary ChatOrchestration session turn; retain exact reply and artifacts even on interruption, approval wait or failure; DELETE BotRunnerBook, all answer validators, per-source budgeting and canned instructions. |
| `StandingBots/BotRunnerHTTP.swift` | DELETE — ordinary discovered tools own retrieval and actions under current Trust. |
| `StandingBots/BotRunnerDeadline.swift` | KEEP reshaped — execution cancellation only; preserve partial replies and name the stop through ordinary turn outcomes. |
| `StandingBots/BotRunnerScheduler.swift` | KEEP reshaped — existing trigger scheduler, interval/cron/manual timing and shared queued turn execution. |
| `StandingBots/BotRunQueue.swift` | KEEP reshaped — one cross-process session run lock for scheduled, manual and follow-up turns; no overlap for a bot. |
| `StandingBots/ShelfStore.swift` | KEEP reshaped — durable append, pagination and sparse reader acknowledgments; entry is reply + artifacts + date + completed/interrupted/failed/waiting-for-approval; remove answer validators and failed-answer sidecar writes; keep old entries readable. |
| `StandingBots/BotContinuityStore.swift` | DELETE — ordinary persisted session, recall and compaction replace it; import useful old context and retained reports once, preserve originals and shelf history. |
| `ChatOrchestration/SwiftToolDispatcher+StandingBots.swift` | KEEP reshaped — plain create/update/pause/delete/list/run-once/ask and shelf reads over new definitions and actual replies. |
| `ChatOrchestration/SwiftToolDispatcher+StandingBotsToolLoop.swift` | DELETE — normal ChatOrchestration discovery, tools, live Trust and approvals replace bespoke source admission and structured loop. |
| `ChatOrchestration/SwiftToolDispatcher+StandingBotsContinuity.swift` | KEEP reshaped — follow-up submits an ordinary turn to the same persisted session; no cheap-provider fallback or private continuity. |
| `ChatOrchestration/BuiltInToolSchemaFactory+StandingBots.swift` | KEEP reshaped — blank-slate explicit choices, free text output, manual timing, editable limits, delete and same-session follow-up; remove source/document schema constraints and engine terminology. |
| `Tests/StandingBotsTests/StandingBotsTests.swift` | KEEP reshaped — retain durable storage/cursor proofs; replace content constraints with lossless definition/shelf migration and free-form reply proofs. |
| `Tests/StandingBotsTests/BotRunnerTests.swift` | KEEP reshaped — ordinary session turns, partial replies, limits, approval waiting and no-overlap proofs replace fetcher/book validation tests. |
| `Tests/StandingBotsTests/BotContinuityTests.swift` | KEEP reshaped — same-session follow-up and one-time legacy history migration replace private continuity/retained-report policy tests. |

## Shared interfaces in stage 2

`ProviderTurnChoice` supplies an explicit request-scoped tuple through the
ordinary checked route admission and provider adapter dispatch, without picker
writes. `SwiftNativeChatOrchestrationClient.chat` accepts this tuple plus a
whole-turn output allowance. `TurnTokenBudget` shares the remaining allowance
across provider requests and preserves output on exhaustion. Available wire caps
receive the remainder; streaming output is bounded locally across adapters.
This is a conservative exposed-output allowance, not a guarantee about hidden
provider reasoning or billed tokens on backends that reject wire caps.

## Existing owners to reuse

The app scheduler hookup supplies the same chat client used by other surfaces,
with surface `bot`, its own persisted session ID and its explicit routing choice.
Normal tool admission owns live Trust, desktop quietness and the Approvals inbox.
Normal turn budgets own output limits. No silent fallback or answer rejection.
Sessions are ordinary Chat-selectable sessions; the shelf does not become a
second transcript. Daily accounting and run locks remain in StandingBots.

## Review fixtures

Production evidence uses `BOTS_PRODUCTION=1 BOTS_SHELF_SNAPSHOT_DIR=mockups/simplicity/helpers/production`
with `BotsShelfTests`. The renderer hosts the actual BotsShelfView and
BotsEditorSheet over isolated temporary stores: three/eight bots, a forty-reply
detail, approval waiting and blank create, in both appearances and requested sizes.
The tab watches exact definition/shelf/queue/deadline files without polling.
Run once queues a turn, Pause changes scheduled eligibility, and Continue in Chat
selects the ordinary persisted session before opening Chat. Model choice reuses
ProviderThenModelPicker in integrated provider-qualified mode; no preference writes.

`SimplicitySnapshots.swift` contains DEBUG-only synthetic list/detail/creation
fixtures. The real ShellFrame and rail surround windowless ImageRenderer output.
Run `SIMPLICITY_HELPERS_ONLY=1 script/snapshot_simplicity.sh` to produce twelve
PNGs under `mockups/simplicity/helpers/`: list, detail and create, each in light
and dark at 1280×800 and 1024×700. Empty creation fields contain no defaults or
examples. Production tab code is unchanged pending User's direction.

## Required runtime proofs

Run is a session turn; approval-needed keeps reply and waits; cap keeps partial
work; migration keeps definitions and old entries; one bot cannot overlap;
follow-up lands in the same session. Build the app and StandingBotsTests
sequentially, run StandingBotsTests and the timer and blueprint checks. No push,
merge or installation is authorized by this task.
