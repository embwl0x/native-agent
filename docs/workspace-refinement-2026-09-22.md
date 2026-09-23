# Workspace refinement — 2026-09-22

User approved five improvements to Agent's agent-facing desktop: conversation
first, quieter controls, unified Find, useful arrivals with exact return, and
safe actionable recovery. This is not a human SwiftUI redesign or a renewed
external-route campaign. No LM Studio model was downloaded or loaded.

## Changes and bounds

- Find composes existing work/history, recorded-artifact and memory readers
  sequentially. It returns at most 12 selectable records, retains exact source
  locators and Back position, and reports each reader's availability/coverage.
  It creates no index, filesystem crawl, provider reasoning or background loop.
  Each source retains its existing relevance ranking; partial-topic matches
  are candidates, not proof that a file supports the searched work.
- Ordinary views have compact navigation and desktop metadata. Show workspace
  controls exposes the remaining navigation. Exact capability names rank ahead
  of incidental description matches; selection still uses owner-bound handles.
- Claude completion formerly cleared the only original answer. Its existing
  job now retains a separate original-answer excerpt, at most 6,000 Unicode
  characters with an explicit truncation flag. Codex's existing delivery record
  retains the same bounded field. Bulk readers keep short heads; exact reads
  supply the retained original. Old erased replies cannot be reconstructed.
  Delivery assessments and diagnostics are never presented as an agent answer.
- Conversation views show that answer and Reply where the canonical owner
  permits it. Details remains available and Back preserves the exact selection.
  Diagnostic receipts are not run through the conversation change comparator;
  their own availability evidence remains visible.
- Arrivals show attributed previews up to 240 characters, truncation, recorded
  status and attention state. Peer text retains taint handling. Opening and
  returning preserve the latest resident draft, without resurrecting completed
  or discarded drafts. Existing event invalidation remains the only refresh
  trigger; no polling or automatic send was introduced.
- Invalid inputs offer exact field correction. Boolean correction says choose
  true or false. Unavailable readers/forms expose read/refresh actions. Prior
  uncertain effects still require outcome review; no navigation replays them.

Human Full Mac settings, Contacts/Mail/Messages write-off preferences, canonical
read/send gates, storage budgets and the 22-tool default floor are preserved.

## Installed evidence

Canonical chat: `codex-workspace-polish-20260921`. These were coached, bounded
mechanism checks in the installed app, not a separate harness or an independent
task-completion benchmark. No file was submitted and no human message was sent.

Initial installed source `b032558c1` passed the signed installer, authenticated
bridge and source/chat readiness. Context pressure was normal with zero
degraded sources. Actual release build: 246.95 seconds, low priority/two jobs.

- Run `0FDA7858-80AE-49B0-AFCA-6BFD5415B94A`: Find `NativeAgent browser`
  returned 2 work records, 3 conversation excerpts, 3 recorded files and
  3 memories. Opening the exact Zero-delta Chrome control record and Back
  restored the same 11 findings. The extra controls were reachable. An unsent
  file draft retained its exact text while invalid `append: maybe` was corrected
  through Correct Append to false. Agent's feedback led to the exact-name
  ranking, clearer boolean wording and explicit Find coverage refinements.
- Fresh Claude message `4468746F-A0C5-4078-84D4-90D6209C5830`, conversation
  `conversation-65d6c84b5485d94b`, completed and delivered. Its original paragraph
  ends “The thought is still here.” The arrival showed Claude, completed,
  finished and a truncated Saved answer preview. Opening the arrival exposed
  the complete paragraph, ending included, `reply_truncated=false`, and Reply
  without needing Details. Details → Back retained the same answer and
  reported unchanged. Return restored `workspace-note.md`, text
  `Keep this note while I read a reply.`, append false, draft_ready.
- Comparable Claude waiting views: 13 controls in the prior installed trace
  (`codex-routes-20260921`, run `046FED81-B7C8-4E1F-B729-C0E9F59E2ED5`),
  9 in this installed check. This establishes less repeated navigation, not
  a general latency or token reduction percentage.
- The Details check exposed an inappropriate comparison-unavailable notice
  despite a successful owner receipt. `d0b7004c2` excludes diagnostic receipts
  from conversation comparison while preserving normal comparison and errors.

Final installed source `d0b7004c2` passed signed install and authenticated
source/chat readiness after an 84.23-second release build. Run
`7650DE6E-31AE-4CCD-9822-140B5D784D4E` confirmed the exact draft survived restart,
the new boolean wording appeared, correction restored append false, Write File
ranked first for `write file`, and Claude Details no longer showed the false
comparison-unavailable notice. Back retained the full answer and unchanged state.

Final arrival cleanup is recorded in the newest `HANDOFF_CURRENT.md` section.
Local bounded receipts are `/tmp/nativeagent-workspace-polish-{navigation,send,arrival}.json`.
Codex message `C434078D-D447-469A-99CA-DFB15D69B40F`, conversation
`codex:01a0c7bf-8bfe-7020-ac56-8423b168f96e`, also returned its original complete
paragraph in the ordinary view with Reply and `reply_truncated=false`, ending
“Nothing was lost.” Run `F1D4C189-FD15-4832-A163-E5D65272D90A` restored the same
draft, then discarded only that unsent draft; unfinished and temporary drafts
were zero and four other open places remained. No file write occurred.

That check found a genuine remaining discovery defect: Codex's arrival appeared
only after opening the conversation. The callback had delivered, but the saved
conversation still held its waiting receipt. `059ec7870` feeds the existing
delegation file-event snapshot into the canonical conversation store. It matches
one exact agent/accepted message ID, absorbs the existing owner receipt, and
writes a single locked batch only for terminal phase transitions. It adds no
watcher, polling, extra reader, provider turn or resend. Incomplete or ambiguous
evidence cannot advance a bookmark. A bounded read-only review checked identity
and self-trigger risks. The final installed arrival discovery check is recorded
in the handoff.

`059ec7870` built in 232.78 seconds and passed signed installation plus
authenticated source/chat readiness. Run `15063272-8923-4D29-AB81-59E0C57C49BB`
sent one follow-up through each existing conversation, then returned Home with
no post-send read/refresh/Details operation. Both bookmarks advanced to ready
from the completion event, with exact original text: Codex
`96EDD36D-BF33-4FBC-BE38-AFA74B8FF0AD` answered “Nothing was lost.”; Claude
`AB777AEC-E07A-4C83-ACFC-3DCD72FC70C3` answered “The thought is still here.”
Agent reported the arrival notices surfacing automatically during navigation.
These follow-ups also demonstrated continuity in the same existing sessions.
Run `3BA99F29-A8C4-412C-AF29-4A7F7DC3F065` opened Arrivals before either
conversation or Details: both exact, attributed previews were already present.
Opening each once showed the original answer, Reply and reply_truncated false;
both Return controls restored Workspace home. Unfinished drafts stayed zero.
The observed discovery defect did not recur. Final health reported normal
pressure, matching context generations, zero degraded sources and ready chat.
Local receipts: `/tmp/nativeagent-workspace-arrival-{followups,acceptance}.json`
and `/tmp/nativeagent-workspace-final-health.json`.

External prerequisites
deferred by User remain in `external-route-verification-2026-09-21.md`.
