# Everyday agent environment

The completion target is a usable supported environment: Agent can find a
place, select what matters, act with its context attached, see the real outcome,
and return or recover without reconstructing routine routing. This implements
the AX goal in [NORTHSTAR.md](NORTHSTAR.md). It does not claim that every external
service is configured or that future protocols work without an adapter.

## Supported journeys

| Place | Complete path | Owner and boundary |
| --- | --- | --- |
| Work | Select a record, part or dependency; follow evidence; read complete notes; update the exact record; return | Canonical Desk; typed views and versioned complete-record windows |
| Find work | Continue current work and historical evidence independently with the same topic/scope | `work_context` over Desk and canonical chat history; recorded claims remain attributed |
| Memory and skills | Find and open evidence/guidance; continue supported pages; carry an explicitly selected excerpt into an agent discussion | Existing recall/skill owners; no personality changes or new memory store |
| Files and creation | Select a folder/file; create or revise with destination attached and complete text prefilled; leave/return/correct; explicitly save; read the result | Ordinary file gates; revision content guard persists; complete UTF-8 up to 64 KiB; four bounded drafts per chat; temporary forms are labeled |
| Research and browser | Search/open/navigate/scroll, then receive the exact current page and selectable controls; select main content when navigation crowds the page | Existing Chrome owner, lease and user-sequence checks; bounded visible-main reading and loading observation; no effect replay |
| Computer | Read the screen, select observed controls or menu items, receive fresh controls and the original outcome | Existing public screen/act owners; exact frame/handle binding, no stale-target retry; pixel-only controls retain a fallback |
| Agents and helpers | Open a continuous conversation, talk with selected context, read replies or inspect a missing result in that same conversation, return to the source | Existing agent/helper sessions, persona/context pipeline and permission owners |
| Saved replies | Read historical answers, follow up from detail with exact rechecked context, return | Canonical shelf and continuous helper session; history is distinct from unread state |
| Human NativeAgent chats | Open the exact session and reply using its actual delivery route | Canonical transcript, last-message guard and delivery lifecycle |
| Mail | Read recent metadata, search bounded sender/subject pages, open the exact message and page its body | Paired native/RFC identifiers; search inspects at most 50 inbox messages per call; operator write-off hides send/reply |
| Messages | Recognize participants, open exact thread details, open the app for history; reply only when operator permits | Participant revalidation; Apple scripting exposes no transcript, so no blank history is fabricated |
| Calendar and reminders | Select exact owner records and edit/complete them; inspect the result | Existing permission and record owners; successful edits return a bounded owner list and exact receipt |
| Connections and other capabilities | Find an available action, fill its current form using fields/choices, submit explicitly | Lazy live catalog; setup, authentication and actual capabilities remain explicit |
| Continuity | This work carries purpose/unfinished requirements and kept sources/discussions; named workspaces, reading positions, arrivals and return | Authored note up to 4 KiB and twelve kept exact references; eight Back positions and four allowlisted drafts; no persisted approvals, executable buttons, credentials or live control handles |

## Readiness and retention

The September 22 work-continuity change joins the destinations around an authored
purpose and kept references. Its [contract and installed acceptance](workspace-work-continuity-2026-09-22.md)
distinguish useful work completion from receipt delivery. A successful review or
save never automatically checks off the requirements. Navigation keeps the
relationships; canonical evidence and Agent's judgment determine completion.
Focused work drops old recent-place clutter and keeps newly opened successful
detail sources automatically. Its dated last-action receipt records the actual
owner result and current readback so saving evidence need not be narrated into
the work note. These are bounded local projections of work already performed.

The subsequent session-desktop change keeps each place's dated last-action
observation separately, so a conversation cannot displace a file's save/readback
result. Named external conversations also provide on-demand scrollback from the
existing conversation owner: both sides, four recent exchanges, earlier-message
navigation and exact exchange opening. Retention is bounded to 32 exchanges and
64 KiB per conversation, with explicit 8 KiB text clipping. Legacy history is
not invented; provider session history remains with the original peer. These
views neither resend effects nor rebuild a model session from the display cache.

The September 21 refinement adds one Find across current work, recorded files,
memory and conversation evidence, with bounded sequential owner reads and exact
result actions. Specialized controls unfold on request. Coding conversations
show retained original answers beside Reply; details carry routing diagnostics.
Arrivals show short attributed previews and restore the current draft on Return.
Invalid fields offer direct correction; read/form refresh never submits work.
Installed acceptance for this refinement is recorded in the current handoff.

Home reports local availability, current browser connection, explicit read-only choices
and unverified external access. It reads one permission snapshot per action and only
one local browser-status snapshot on Home; it launches no apps or remote probes.
Canonical execution owners still enforce permissions.

Drafts survive saved-arrangement switches independently of the open-place list.
Successful owner settlement removes a submitted draft; failures keep editable recovery.
Uncertain outcomes require explicit review before another attempt. Recovery is saved
before dispatch to prevent unsafe replay after restart. Storage failures retry on later
actions, no more often than every five seconds; corrupt bytes remain untouched.
Limits are four drafts/chat, 64 KiB inputs/form, 131 KiB schema/form, 512 KiB saved
desktop/chat and 64 resident chats. Capacity refuses admission instead of deleting
unfinished work. Unsupported forms are explicitly temporary and pin their session.
Current schema and permissions are rechecked on opening/submission after restart.

## Completion checks

Acceptance exercises complete journeys rather than merely opening destination
tiles. Live checks give Agent objectives without prescribing the successful
action sequence. The current dated [handoff](HANDOFF_CURRENT.md) records actual
build identities, observations and limits; this map alone is not proof of an
installed result.

Focused checks cover exact-target binding, stale-source refusal, immutable form
targets, partial-input correction, interruption/return, duplicate-effect
prevention, pagination, restart-safe references, browser ownership and honest
readback failures. External human sends are not used as test fixtures.

The initial installed check exposed a Swift exclusivity crash in new browser
bookmark bookkeeping. That code now edits a local bounded session before one
writeback; subsequent installed checks exercised separate browser places.
Live acceptance also exposed costly cold AppleScriptObjC initialization in the
new human-message readers. Their metadata transport now uses bounded native
AppleScript escaping with strict single-pass decoding and per-event deadlines.
It keeps exact identities without initializing an Objective-C framework bridge.
Open places uses each browser lease's actual page title/URL; resident drafts
report the actual selected view, separately from their restart-safe fallback.

Chrome's loaded unpacked extension must be reloaded after these source changes;
an app reinstall alone cannot reload Chrome. The main-content scope applies to
visible semantic article/main regions, preserves modal/redaction/ownership
checks, and does not claim to extract a whole offscreen article.

The design uses recognition, meaningful feedback and preserved input/return as
engineering hypotheses, guided by [W3C's back-navigation pattern](https://www.w3.org/WAI/WCAG2/supplemental/patterns/o4p02-back-undo/)
and [forms guidance](https://www.w3.org/WAI/tutorials/forms/). Actual NativeAgent
owner contracts and installed observations determine the implementation.
