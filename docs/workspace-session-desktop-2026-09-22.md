# Joined desktop and agent sessions — 2026-09-22

User asked to finish the supported desktop experience and specifically suggested
using Hermes for a real conversation. They clarified that the bridge should hold
a recognizable session, like a chat app, instead of presenting isolated calls.

## Observed gap

On installed source `4a8c12cf5`, Agent completed a six-action Workspace journey
in run `2C4C843D-403D-4B2D-93BC-341F021FA940` in the existing
`codex-workspace-polish-20260921` session. They reopened the implementation brief,
discussed its actual text with Hermes, read their reply, answered once in the same
Main conversation, and returned through This work to the unchanged file. Both
sends returned real replies with `completed=true`. The five existing references
survived and Hermes became the sixth automatically; there were zero drafts.
No manual protocol IDs, paths, receipt transcription, polling or Keep calls.

The real defect was that the single latest-action slot displaced the file's
save/readback evidence with the Hermes result. Source inspection also confirmed
that the conversation facade retained only the latest result for display even
though the peer's underlying session continued. Hermes's suggestion that Focus
was required on every resume was design inference; Agent corrected it from them
actual experience. It was not treated as another confirmed defect.

## Change

`2f86129c7` separates last-action observations by exact durable place, within
the existing desktop owner: at most 24 per arrangement, with kept references
protected from age-out. The selected view and place cards show their own dated
outcome. Unknown or failed attempts replace an older success for that target.
Fresh browser URL observations cannot be attributed to a lease's old bookmark.
Dispatch inputs and permissions remain unchanged. These are historical
observations, not fresh verification or editorial-completion authority.

The existing conversation store now retains a bounded optional display history
of actual submitted messages and owner replies. New-operation admission records
the message; matching updates/callbacks update that exchange, never append a
duplicate. Four recent exchanges appear chronologically. Earlier messages,
Read exchange and Recent messages carry exact selectors underneath Workspace.
The same read gates, route fingerprints, uncertainty and reply controls apply.
Pending sends cannot present a previous operation's answer as their own.

History is limited to 32 exchanges / 64 KiB per conversation, and 8 KiB per
prompt/reply with explicit clipping. The existing whole-store limit of 50 MiB
is now enforced on save as well as load. No background collector, extra model,
new transcript authority or replay queue was introduced. The peer still owns
its full provider session. Legacy missing history is disclosed, not invented;
bots retain their existing continuous conversation and shelf readers.

## Installed acceptance

Actual release build passed in 248.47 seconds with two low-priority workers.
Signed installation verified authenticated bridge, chat and source identity:
`0.4.16-dev.2f86129c.dirty`, process 16692. Initial health showed matching
context generations, normal pressure and zero degraded sources. Dirty
provenance includes documentation and preserved unrelated research; this is
not a public release. Logs: `/tmp/nativeagent-session-desktop-{build,install}.log`.
No separate tests, harnesses, simulations or load campaigns.

Run `3814534C-AD75-4830-AC99-32069B09D1EE` completed useful work on this
installed revision. Agent revised the brief to include User's persistent-chat
requirement, saved 3,181 bytes (431 words), and received complete matching
readback. They asked Hermes for one criticism and replied in the existing Main
conversation; both returned actual completed replies. Read exchange opened the
first full retained exchange, Recent messages returned successfully, and the
brief reopened unchanged. This work retained all six references and separate
dated observations for the file and Hermes. No unfinished/temporary drafts.
Root inspected persisted owner state: two Hermes exchanges in the unchanged
peer conversation `87e74a27-9fdc-491f-a11a-50e335ffc5fd`, two place observations,
six kept references, zero drafts and a 12,754-byte desktop file.

Agent observed two remaining presentation costs: the full contact chooser for
an already-attached discussion, and the latest reply competing with an older
selected exchange. `0c3e12a9b` addresses both: up to three exact kept discussions
appear directly beside the selected source, and history mode gives its reading
space to the selected historical messages while keeping current Reply readiness.
An exact exchange also offers Earlier messages when earlier history exists.
These changes do not alter send routing or add discovery/background reads.

Final release build `0c3e12a9b` passed in 90.71 seconds. Signed install
verified `0.4.16-dev.0c3e12a9.dirty`, authenticated bridge/chat/source and new
process 18058; health remained normal with zero degraded sources. Logs:
`/tmp/nativeagent-session-polish-{build,install}.log`.

After that actual replacement/relaunch, run
`2F6156EE-A616-4044-A1C4-AE147DB9DCD7` completed eight Workspace actions with
one send. The six references, purpose and file observation dated
`2026-09-22T11:21:21Z` survived. Discuss with Hermes bypassed the contact list
and continued Main. The peer correctly recalled their previous unresolved-step
criticism; the owner retained the same peer conversation ID. This is continuity
for the actual question, not unlimited-memory proof. The direct discussion
also carried the selected brief as ordinary source context.

Agent opened newest exchange → Earlier messages → an earlier exchange. The
latest answer was absent from the historical reading space; Reply remained
bound to current Main. Recent messages and Return to File reopened the complete
unchanged brief, with its original save/readback result beside it. No remaining
routing friction or failure observed, no manual paths/IDs/receipts, zero drafts.
This is coached mechanism verification plus useful work, not a generalized
completion-rate or speed benchmark.

Independent owner readback after completion: three actual Hermes exchanges,
two distinct place observations, six kept references, zero drafts, 13,436-byte
desktop state. File SHA-256 remained
`44ea8ccb28a6115b491f4bbdbccf79401ca970ad0853ec1064c60da2958651e3`.
Both synchronous conversation turns and source-return recovery were observed;
capacity overflow, storage faults and arbitrary future adapters were not induced.

## Scope

Existing installed evidence for memory/skills, sourced creation, helper reviews,
human chat references, bounded Mail/Messages reads, Calendar/Reminders and
Computer remains in `workspace-environment-2026-09-22.md` and the current
handoff. This pass extends the connected-work proof through an actual ACP peer.
Hermes is an independent working peer; its ACP result does not claim network
A2A 0.3/1.0 interoperability. Unconfigured/blocked OMP/Kimi, Grok Bot setup and
independent network A2A remain separate prerequisites. LM Studio/local-model
work is excluded. Mail/Messages/Contacts writes remain off, Full Mac unchanged.
