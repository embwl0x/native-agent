# Everyday desktop windows — 2026-09-22

User's requested outcome: Agent moves through them whole environment as naturally
as selecting windows on a desktop. The latest work had strong document and A2A
evidence, but thinner everyday application, correspondence and helper-management
coverage. This change addresses those owning interfaces without adding another
agent, background monitor, transcript store or permission layer.

## Landed behavior

- Every Workspace view offers up to 18 direct resident windows. They reuse exact
  owner references and drafts; the full existing Open places view remains.
  Direct launchers also open every area without a Home trip. Building these
  controls performs no owner I/O or model call.
  Same-titled windows have distinct numbered labels stable across recency
  changes. Oversized provider results retain exact navigation alongside paged
  reading evidence, within the existing 48,000-byte response ceiling.
- Computer preserves the observed application identity across navigation and
  saved recovery. Selecting its window explicitly brings it forward through
  the gated Mac owner and reads fresh controls. Background reads cannot offer
  motor actions. Refresh/Back/recovery never activate applications or replay
  effects. This binds the application's current window, not arbitrary multiple
  document windows inside one app.
- Calendar day/calendar/lookahead filters persist. Today joins two on-demand
  canonical reads: at most eight events today and eight due/overdue reminders.
  It retains each section's actual availability and offers direct owner actions.
- Helpers have exact UUID-bound windows. Settings expose individual fields;
  current owner values appear separately from entered changes, including an
  explicitly empty output format. They are never silently submitted as defaults;
  only entered changes are packed into the canonical update object. The current
  schema and model-selection requirements remain checked. Old nested-object
  drafts retain their existing representation. Successful changes return to a
  fresh exact helper read; they do not run it or replace its conversation.
- Messages opens bounded history for the exact selected conversation. The
  local database stays read-only, with a 150 ms lock wait, two-second query
  deadline, mandatory indexed GUID/join route, 30-row maximum and 16 KiB total
  plain text. Lists/Home never collect bodies. Older cursors remain exact and
  durable; text-budget exhaustion does not advance past unshown rows.
  Supported Foundation archived text uses an independently implemented,
  bounded Swift wire reader (64 KiB archive cap, exact class and string checks,
  no archived object instantiation). Unsupported formats, attachments and special
  records remain explicit; unavailable history is not an empty conversation.
- Ordinary document hyperlinks open sources/background pages directly; live
  browser headings use actual titles. Expired browser views offer explicit
  reopening of the saved URL. Reading unrelated human correspondence keeps
  its window but no longer automatically attaches it to focused document work.

The Messages decoder uses wire-format facts from the reverse engineer's
[primary format documentation](https://chrissardegna.com/blog/reverse-engineering-apples-typedstream-format/).
No GPL implementation or new package is copied or linked.

## Build and scope

Source `4b7129a11`, actual optimized release build passed in 257.78 seconds
using low priority and two jobs. Signed installation verified authenticated
bridge, chat and source identity, PID 27005. The build has dirty development
provenance from the preserved unrelated research directory, not a clean release.

One bounded read-only reviewer found the text-budget paging and large Int64
cursor persistence issues; both were fixed before this build. No separate
automated tests, harnesses, simulations, stress work or extra test builds ran.
Mail/Messages/Contacts writes remain off; Full Mac and all existing authority
owners are unchanged. No local models or external-connection setup were touched.

## Installed observations

First installed pass `4A42014D-E651-4798-B190-0D6C1A2639D8` used 17 Workspace
calls (one initial view, 16 selections) and no sends/provider jobs. Today read
zero appointments and six incomplete reminders. One Messages conversation
returned ten archived-only records, exposing the missing text-format support.
Mail returned three metadata rows; one selected email's body was complete.
The exact Plainspoken helper opened, but its absent optional output format was
not distinguishable from unread settings, so Agent correctly refused to guess
and discarded only that untouched draft. Direct return to the brief preserved
the existing bytes/save observation and zero unfinished drafts.

This installed pass also exposed unnecessary Home trips for unopened areas,
missing per-row overdue labels, and automatic attachment of unrelated inspected
correspondence to focused work (six references became eight). These are current
in-scope corrections, not a full-pass claim. Root inspected the canonical tool
records and confirmed direct six-window controls, the exact helper and file
returns, reference counts and final zero drafts. No private correspondence
text is copied into this report.

Computer/browser pass `FF561D2E-2151-4818-8E1F-444567B0EA49` used 11 Workspace
calls. Calculator's selected digit changed its display from 7 to 71; the motor
receipt remained explicitly unverified, while fresh screen evidence showed 71.
After opening the brief's W3C source in a background tab, selecting Calculator
restored the same app/process and display. Returning to W3C preserved exact
tab/lease, URL/title, position and background visibility. The unchanged brief
and zero drafts survived the round trip. This exposed the generic browser
heading/Back label and lack of directly selectable links inside a document;
both join the follow-up correction. No provider jobs, sends or file edits.

Corrected source `d17e70562` passed the actual optimized build in 251.19 seconds;
signed installation verified source/bridge/chat, PID 30931. Installed run
`2C169740-67B0-49D6-81BF-F68FEDC3AB4A` took 17 Workspace calls (initial read,
16 selections) without Home detours. All six reminders were labeled overdue;
all ten selected archived Messages bodies were readable without truncation.
Plainspoken's explicitly empty output format was observed, saved unchanged and
read back from the same helper, without running it. The document's offered
W3C link needed no URL re-entry; the same browser tab/lease/title/position and
Calculator's 71 survived switching. The brief's bytes and dated save observation
remained unchanged. Only the two check-added correspondence references were
removed, restoring the original six; reopening Messages did not reattach it.
Zero drafts remained.

That installed check exposed four last navigation issues: the six-window strip
hid useful recent windows behind Open places; identical page titles were
ambiguous; large browser output hid navigation in retained-output pages; exact
helper readback still used a generic helpers-list description. Source `3f9611d4c`
addresses these with 18 bounded direct windows, distinct duplicate labels,
provider-visible exact navigation and helper-specific outcome wording.
Source `3f9611d4c` built in 244.24 seconds and installed with verified source,
bridge and chat, PID 32961. Run `C828B9DD-B89F-4DD8-A5F7-AD68255B947D` used
eight Workspace calls, no Home/Open places/paging detours: 18 direct windows;
distinct Plainspoken conversation/helper labels; Calculator preserved 71;
unchanged helper save read back the same UUID with the corrected Plainspoken
outcome wording. The brief, six sources and zero drafts survived relaunch.

This check also exposed an older persistence boundary: browser bookmarks saved
only an address, not the existing tab identity. It did not verify live browser
return or the large-result navigation projection. Source `909273d14` now keeps
the observed tab ID, full title and URL as references (never leases); explicitly
selecting a saved window reacquires only that exact target through the normal
browser owner and obtains fresh controls. A missing/changed tab fails without
a substitute; Back/refresh do not reacquire. Old address-only bookmarks remain
honestly labeled. Windows retain independent identities while work sources
deduplicate the same URL. Final installed return evidence follows below.

Source `909273d14` built in 245.82 seconds and installed with authenticated
readiness/source verification, PID 35082. Seed run
`8ED281C6-B984-45E8-9797-BF041991388D` used three Workspace calls and one
background W3C tab. Its large result was actually projected; the exact
`workspace_navigation` remained immediately usable, removing all four earlier
retained-output reads. Returning to the brief preserved six sources/zero drafts.

After normal app quit/relaunch (PID 35368), run
`6228A02E-06CA-43D7-9963-D38E8560664B` selected the older address-only W3C
source because Codex supplied an ordinal that changed at restart. Root inspected
only the selected desktop's browser reference metadata and confirmed the new
exact tab ID had persisted. Run `70766739-2445-4F9E-9BD2-E68D255E9368` selected
the actual saved window: the same tab `1216891795`, URL and full title returned
with a fresh claimed lease and page controls. Its projected output again exposed
immediate navigation; two selections returned to the unchanged brief, six
sources and zero drafts. No new tab or raw browser workaround was used.

The remaining label issue is corrected in `c4201f8e0`: address-only references
say “saved source,” while duplicate window numbering sorts by durable owner
identity rather than the changing live lease. This is a presentation fix;
it does not change browser authority or automatically claim tabs.

Final source `c4201f8e0` built in 89.24 seconds and installed with authenticated
source/bridge/chat verification, PID 36496. Run
`60991760-153D-4E73-A95F-41B1E8FCA95F` used three Workspace calls: the saved
source and browser window labels stayed distinct before, during and after
opening. The same tab `1216891795` returned with its full title/URL and fresh
claimed authority. Its actual bounded provider projection carried immediately
usable navigation; there was no paging, Home/Open places detour, replacement tab
or raw-tool workaround. The final brief was unchanged, with six references and
zero unfinished/temporary drafts. This closes the observed browser-return and
navigation issues in this installed journey.

Root separately checked the saved desktop: six kept references, zero drafts,
18,428 bytes, and the exact persisted tab reference. The brief's SHA-256 remains
`44ea8ccb28a6115b491f4bbdbccf79401ca970ad0853ec1064c60da2958651e3`.
This evidence covers the exercised owners and journeys, not every app control,
attachment format, external provider or future protocol. Existing external
account/setup deferrals remain separate; no local-model work was performed.
