# Settings audit, 2026-09-04 (four GPT-5.6 Sol workers, read-only)

User asked for every switch on the new shell's Settings page to be proven connected. Four
reports in this folder, one per area. What was fixed the same night (commit "Settings audit:
..."): the Everything confirmation applied nothing (flag never passed); restored child
selections lost their tab; a route to a page could land on a remembered tab (multimodal notice
opened Mac integration); the NextGen request never opened its section; Cmd-K could not reach
Cognition or Inspector; the Navigate menu used the raw developer switch; "Use my Mac" was a
switch bound to a constant; dreams did not re-sync on policy change.

For User in the morning, in this order:

1. **Five memory switches change nothing yet.** Nothing reads `consolidation_enabled` (the
   weekly runner never checks it); knowledge graph off does not stop graph production or use;
   `cross_session_recall` cannot be disabled (recall runs regardless); `adaptive_promotion` and
   `auto_promote_consolidated` are not consulted by the promoter or candidate builder;
   `hygiene_enabled` only changes a status label. The switches save the policy faithfully;
   the runtime does not honour it. That is a memory-runtime change, so it is User's call.
2. **Dream composite**: off writes both gates false, so a prior "cycle on, scheduler off"
   cannot be restored. Same on the Dreams page. Either two switches or accept it.
3. **The inner-life master** resets reflection, moods and memory-in-every-reply when turned
   on, and leaves memory-in-every-reply active when turned off (the card now says the first).
4. **Reflection and moods show the requested value, not the effective one** (the
   Observatory shows both). Memory in every reply shows no "forced off until set up" line.
5. **The chat mind picker saves provider and model as two transactions**; use
   `configureSurfaceSelection` for one.
6. **Trust posture presets rewrite more than the picker says** (developer mode, backups,
   Mac-control, remote-iOS). Disclose or narrow.
7. Wording: Telegram "Connected" means a token is saved; iPhone status is a one-shot read.
8. Twelve `SetupRoute` destinations are dead now that Advanced is gone; delete.
