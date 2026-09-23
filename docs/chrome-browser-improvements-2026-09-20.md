# Chrome browsing improvements — 2026-09-20

## Follow-up: rendered X replies

The later next-build task added a separate unfocused work-window route. Resident
0.4.10 proof read multiple actual replies on the first snapshot of the same Mia
thread, reported `visibility: visible`, and released/closed its test tab with
`userSequence: 0`. No activation or user-tab operation was issued; OS focus was
not independently measured. Snapshot `d2671ec3-0591-4674-8734-7e6ab2716daf`.
Extension 0.4.11 selects this route automatically for newly created X/Twitter
post tabs; other URLs keep the existing grouped background default. Explicit
`grouped_background` remains available. See `next-build-handoff-2026-09-20.md`
for the final installed automatic-route proof. The unresolved statements below
describe the earlier 0.4.9 inactive-tab result, not this later work-window proof.

## Initial 0.4.9 work

User requested the four issues from a fresh install's X browsing report: repeated
old feed reads after scrolling, missing replies, a stale AI-tab click, and the
five-minute lease ending mid-browse. Existing human Full Mac settings, social
account state and user-owned tabs are outside the change.

## Owning changes

- `page-agent.js`: viewport-scoped nodes and summary; offscreen articles do not
  exhaust the traversal budget. Container text keeps direct prose rather than
  repeating all descendants. Node identity uses the same text projection.
- Scrolling retains instant, no-focus movement and the existing hidden-page
  scroll notification, with a bounded rendering interval and an honest DOM-change
  observation. This is not a claim that network fetching or infinite loading
  completed.
- Exact unchanged tablist controls share the existing narrow navigation proof.
  Only click survives unrelated mutations; selection/panel identity, ancestors,
  modal state, removal, takeover and the existing 60-second limit still matter.
- `ChromeControlRuntime`: authorized activity renews still-live leases near
  expiry using their original duration/sequence. No polling, idle extension,
  automatic reacquisition, or reclaim after user takeover.
- Extension manifest 0.4.9. Normal work-tab creation needs no user action.

## Evidence

Integrated build passed. All 79 extension tests passed after updating one
existing assertion to the new direct-prose projection. All 18 focused native
Chrome tests passed, including live/expired/comfortable lease cases and existing
takeover/trust behavior. The native runtime has not changed since those tests.

Installed runtime PID 36649 passed authenticated readiness. Chrome loaded the
repository extension folder; Codex used its exact extension-details Reload
control to verify 0.4.9 after resident label targeting could not disambiguate it.
Final resident acceptance passed the ancestor-text correction: summary and nodes
moved from items 1–2 to 3–4 after scrolling, with earlier items absent and no
ancestor repetition (untruncated snapshot c7d81efe-eae3-41bf-a740-ac4899cd9f82).

Resident proof on 0.4.8:

- Created/released their own inactive fixture tabs, no user-assisted tab opening.
- Thread click succeeded across unrelated tick mutations; a fresh read after
  scrolling showed both Mira's and Rowan's reply bodies.
- Revised fixture used viewport-relative heights: document grew from 3569 to
  7049 px after scrolling; later reads showed fresh items 5, 6 and 7.
- X AI-tab click succeeded; fresh read confirmed selected AI and different posts.
  Scrolling 1400 px exposed Thomas Trimoreau and Uzi articles absent from the
  initial viewport. No social writes or existing-tab manipulation.
- The same X run exposed stale ancestor text despite correct article nodes;
  this is the reason for the final 0.4.9 correction and its regression test.
- Two directly loaded X threads reported 3 and 19 replies but exposed no bodies
  in background snapshots. In final 0.4.9 proof, Mia's thread still showed none
  after selecting Recent (untruncated snapshot 6ed61a9c-6c88-4272-8b97-8b010ab2c677).
  Foreground activation then exposed actual Visiting Fellow and Slop Analytics
  reply bodies in screenshots at 23:25:29Z; Page Down exposed more at 23:27:50Z.
  This supports visibility/lazy rendering as a dependency; it does not establish
  omission of already-rendered bodies. **X background replies remain unresolved.**
  No silent activation or takeover workaround was added. Activation yielded the
  lease; Agent closed their own test tab through normal controls, verified its
  disappearance, and restored User's repository tab.

Private receipts: `/tmp/agent-browser-fixture-proof-4.json`,
`/tmp/agent-browser-final-proof.json`, `/tmp/agent-x-replies-diagnosis.json`.
Final receipt request: `6271AD78-9738-4544-BE80-29B9355E83D9` in the private
bridge message-replies.jsonl (the HTTP helper timed out while the original turn
continued, then the exact receipt completed). Background runs have inactive
creation/no-focus receipts, not independent OS-foreground measurement. The final
foreground comparison was explicit and bounded, with screenshot evidence.

Next scoped work: investigate a supported background-rendering route for sites
that gate replies on visibility, preserving the user's active tab and takeover
semantics. Do not infer that a lease or scroll receipt guarantees content loaded.

No commit/push. Prior Jev/ACP/A2A dirty work is preserved.
