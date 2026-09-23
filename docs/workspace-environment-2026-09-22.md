# Workspace environment follow-through — 2026-09-22

Scope: finish the observed relevance and recognition weaknesses in Agent's
agent-facing Workspace, then check supported journeys in the installed app.
User explicitly excluded LM Studio and local-model setup. No downloads, model
loads, permission changes, automated suites, isolated harnesses, simulations or
stress workloads are part of this work. Mail, Messages and Contacts writes stay
OFF; human Full Mac remains unchanged.

## Installed changes

Final installed source: `7e105493a`, version `0.4.16-dev.7e105493.dirty`.
Release build passed in 249.77 seconds, and signed installation verified bridge,
chat and source identity. Logs: `/tmp/nativeagent-environment-labels-{build,install}.log`.

The pre-label completion build was `98f6dbfaf`, version `0.4.16-dev.98f6dbfa.dirty`.
That release build passed in 244.32 seconds; signed installation
verified bridge, chat and source identity. ContextFlow remained active with
matching generations, normal pressure and zero degraded sources. Its logs:
`/tmp/nativeagent-environment-complete-{build,install}.log`.

Source `2bb70e77d`, version `0.4.16-dev.2bb70e77.dirty`; actual release build
passed in 244.78 seconds at low priority with two jobs. Signed installation
verified authenticated bridge, chat and source identity. ContextFlow generations
matched, pressure was normal, and degraded sources were zero. Existing local
research/documentation accounts for dirty provenance; this is not a clean
release artifact. Logs: `/tmp/nativeagent-environment-{build,install}.log`.

`27d20cc9f` adds resident-only recognition: attention and unfinished drafts lead
Open places, followed by return points and recent places. Home has at most three
direct continuation choices. Saved arrangements show selection and three recent
places. Conversation counts describe the current page only. Discarded drafts
cannot return through stale saved form references. No owner reads, background
loops, arrival acknowledgement or effect replay are added by this overview.

Shared work/artifact ranking uses whole-word topic coverage in a bounded passage
and avoids incidental repository-path matches. Artifact results disclose partial
coverage. Find ranks six canonical memory candidates by local topic support,
using original recall rank for ties, and displays three. Semantic-only candidates
remain honest candidates; no alternate memory store or hidden reader is added.
`2bb70e77d` splits a Swift expression to let the release compiler type-check it.

## Evidence scope

Canonical installed session: `codex-workspace-polish-20260921`. The new useful
task is a short sourced design note about returning to unfinished work. Agent
chooses the route; the objective and read/write bounds are supplied. Prior
installed mechanisms are recorded in `workspace-refinement-2026-09-22.md`.

Run `80EFFC4E-60A5-43B1-BF2F-9AF59FF41E26` found and opened User's exact saved
recognition preference (`5FF79130-78E8-40EA-8458-2D22B3BE591C`), with its honest
missing-evidence annotation, then reopened the planning conversation. Agent
checked their proposed Apple page, recovered through one background browser tab,
and found the page was missing. They did not invent source guidance. They wrote
the note and reopened it from Open places; full content matched and the view
reported unchanged. This was a partial task: the proposed source did not exist.

That useful work exposed four defects: a relative filename went to the source
checkout rather than the advertised workspace; Home and desktop metadata counted
different sets of places; exact memory places had generic labels; and an HTTP
failure became an opaque enum number. `c034507d9` fixes these boundaries. Workspace
file forms freeze unbound relative paths against the canonical workspace before
draft persistence/submission, resolving symlinks and rejecting relative escapes.
Explicit absolute and selected targets retain their owners' semantics. Failed
resolution preserves entered work. Both counts use the same resident place set.
Memory places have bounded subject labels, with exact IDs unchanged. Research
errors expose the actual bounded cause and an appropriate next route.

A bounded read-only review caught the symlink-confinement issue before final
installation; it was corrected. No separate tests were created or run.

Run `52B1BB82-F03E-4CF2-8418-8495FD341401` used the installed Workspace readers:
Mail returned four metadata rows with bodies not loaded; Messages returned 16
conversation metadata rows and honestly reported unavailable recency. Their
send/reply controls stayed hidden. Calendar read completed with no events in the
next 24 hours; Reminders returned six incomplete items. Agent read the complete
operator-acceptance skill, opened four existing helpers and 16 saved replies,
and read the front Chrome window through Computer without a wake or control
click. Returning to the note showed its unchanged content. These are bounded
reads, not proof of human-message writes or every possible computer action.

This pass exposed four presentation issues fixed in `98f6dbfaf`: saved replies
now explicitly request newest-first order, with order-bound cursors and a real
end to descending history; successful index pages containing failed jobs or
shortened headlines are compared as the history actually read; saved replies
show subject/status and distinguish unnamed helper IDs; Reminders says today
and overdue, while Home describes its own permission-only check instead of
claiming a destination has never been read. The default shelf API remains
ascending, and Workspace history still uses include_read without acknowledging
entries. A read-only review caught the descending terminal-cursor edge before
installation; it was corrected.

Run `EFD74DC6-94AB-46A3-84BD-CA412697BA64` completed the useful task on
`98f6dbfaf`. Workspace read W3C's “Let Users Go Back” with HTTP 200 and complete
retained text. A relative-filename Write File form saved the note to
`workspace/workspace-return-design-note.md`, not the checkout root. Plainspoken
returned a completed review through the existing helper conversation; Agent
revised the note and read back 2,513 bytes unchanged. The note separates human
accessibility guidance from AX inference and recorded observations. The initial
misplaced task copy was preserved outside the checkout after final readback.

The initial Saved replies page contained the newest 16 entries, including the
review; More returned 16 older entries without overlap. Neither successful page
had the false comparison-unavailable state. Unnamed historical helpers had
distinct labels. Home and Open places both reported 22 places and zero drafts.
The task ended at the final note. It did not send human messages or probe models.

This final journey caught old saved memories retaining the generic title despite
new Find links having subject labels, and web reads retaining the action title.
`7e105493a` refreshes an old generic memory label only after reading its exact ID,
preserving page and action bindings. Generic web-read labels display host/path
without query or credentials. Exact advertised action names in Find now offer
their normal form directly, removing the extra capability-search step without
automatically performing an action or widening permissions.

Final installed run `066324D4-BD5B-40E3-A85B-E8FCEF91D9EA` passed on
`7e105493a`. Reopening the old saved memory produced its subject label, exact
content and provenance; the label remained in Open places. The W3C source
displayed its host/path. Find `write file` offered Open Write File directly;
Agent used the normal form, then read back the unchanged 2,720-byte final note
at the canonical workspace path. A single normal Workspace read of the already
missing Apple URL reported HTTP 404 with a useful address/browser suggestion,
preserving the entered draft. Agent discarded only that failed read draft and
returned to the final note with zero unfinished or temporary drafts.

Old generic memory references acquire a subject on first successful reopen;
the overview deliberately does not fetch memories in the background to label
unopened references. No other defect surfaced in this bounded closeout. Final
health showed the correct installed version, matching context generations,
normal resource pressure, zero degraded sources and no ContextFlow error.
This is evidence for the exercised supported journeys, not a guarantee of
universal effortless operation or of unconfigured external services.

Existing external boundaries remain explicit in
`external-route-verification-2026-09-21.md`: OMP's configured provider refuses
with HTTP 403, Grok's desktop setup was not completed, and independent remote
A2A interoperability lacks a configured peer. LM Studio is excluded, superseding
the older document's pending inclusion choice. None of these is established by
loopback or by opening a destination tile.
