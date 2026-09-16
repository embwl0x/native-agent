# Tool loading: the contract

This is the agreed behaviour for which tool schemas ride on a chat request. It is
short on purpose. A change to any line below is a design change and needs User's
word, not a side effect of a cache fix (2026-09-11: an append-only floor for
prompt-cache stability silently overrode rule 2; User caught it a day later).

Agent Experience selection clarification (2026-09-14, User-authorized): category,
`name` and `names` are additive, including app/core mixed selections. Unknown
names report unavailable/partial, never loaded. A sessionless call is an
availability preview with empty `loaded`; it does not establish a session
contract. Explicit promotion markers apply only to persisted active tools;
turn-only availability must not create an empty session file.

1. **Always on (20 names).** `SwiftToolDispatcher.alwaysOnCoreNames`. These are
   the only tools in every request. Agent's working-set ruling of 2026-09-11.
   Four of the twenty are the Mac verbs (`screen`, `act`, `go`, `wait`), whose
   schemas are emitted only while Full Mac accessibility is active
   (`BuiltInToolSchemaFactory+MacSchemas.swift`, `SwiftToolDispatcher+Sandbox.swift`),
   so an install without it rides sixteen.
   The one addition: while an MCP server is mounted, its tool schemas ride the
   session contract automatically, without a `tool_load` or a preload
   (`ChatSessionActiveTools.swift`,
   `ChatOrchestrationClient+StructuredChat.swift`).
2. **Everything else is lazy.** A tool joins the request only by `tool_load`,
   a confident route preload for this turn, or a turn-start promotion; it
   **unloads after `idleTurnsBeforeDrop` (2) turns without a gated call**, from
   the active set and from the offer floor alike. Evidence is a real dispatch
   (`lastDispatchedTurn`, written only by `markUsed`) or the turn it joined
   (`floorJoinedTurn`); a promotion stamp is a guess and never counts as use.
   A name idle-dropped is not re-promoted for `promotionCooldownTurns` (12)
   turns; a real call or an explicit `tool_load` clears the cooldown.
   App-owned tools are lazy like every other name, and the app shim runs the
   same gate over its own set before delegating
   (`AppChatToolDispatcher.appOwnedLazyLoadingRefusal`). Its set is the notify
   pair, the browser/Chrome group, `doctor_status` / `telegram_status`,
   `reflex_review`, and — since 0.4.14 — the six quiet self-administration
   tools: `app_page_read`, `app_page_screenshot`, `app_settings_list`,
   `app_setting_set`, `interaction_act`, `voice_render` (category `app`). None
   of them is always-on.
3. **Only the core is exempt from rule 2.** An explicit `tool_load` is protected
   from LRU eviction and from the idle-boundary rebuild while it is in use, but
   it too unloads after two unused turns; `tool_load` brings it back in one
   call. `tool_unload` (by name or `all`) drops it at once.
4. **The offer floor** (`offerFloor`) exists so the array is byte-stable *within
   a conversation burst* on stable-array providers (ChatGPT OAuth). It is
   append-only during a burst, capped at 40 with LRU eviction of unprotected
   entries, and it shrinks only by rule 2. There is no time-based rule: the
   30-minute rebuild trial of 2026-09-12 was withdrawn the same day (User:
   "what does a timestamp have to do with the turn count"). One missed cache
   read after an unload is the accepted price; the within-burst reuse is what
   the floor protects.
5. **Retired is not removed.** Every unloaded tool stays in `tool_catalog` and
   loadable. Removing a tool from the catalog is a separate, owner-level call.
6. **Receipts.** `tools.contract` per turn carries the real wire count, floor
   and appended counts and bytes, and whether the turn followed a rebuild.
7. **Installed schema upgrades (2026-09-15, User-authorized).** At the accepted turn boundary,
   `ActiveToolsStore.commitTurnStartContract` refreshes changed descriptors for
   code-owned tools already pinned in the session. The app dispatcher supplies
   its own names through `ActiveToolsStoreProviding.codeOwnedToolNames` alongside
   the core registry. A changed declaration receives one generation bump;
   unchanged schemas cause none. The captured contract stays immutable during
   the turn, dynamic/MCP descriptors remain pinned, and missing/readiness-gated
   tools keep their previous descriptors without gaining dispatch authority.
   An upgrade never requires Agent to unload and reload a native tool manually.

The tool list itself is code, not this page: `SwiftToolDispatcher.alwaysOnCoreNames`
is the twenty of rule 1, and `SwiftToolDispatcher.builtInToolNames` is the
catalog everything else is loaded from. A new tool joins the latter and nothing
else — most recently `studio_journal_amend` and `dream_diary_read` (0.4.14),
both lazy: the first like the rest of the studio lane, the second because
reading a night back out of the dream diary is a deliberate pull and has no
business costing prompt bytes on every turn.

Owner: ChatSessionActiveTools.swift (`beginTurn`, `commitTurnStartContract`,
`markUsed`), ChatOrchestrationClient+StructuredChat.swift (`traceFinalToolContract`).
