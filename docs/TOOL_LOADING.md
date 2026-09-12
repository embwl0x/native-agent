# Tool loading: the contract

This is the agreed behaviour for which tool schemas ride on a chat request. It is
short on purpose. A change to any line below is a design change and needs User's
word, not a side effect of a cache fix (2026-09-11: an append-only floor for
prompt-cache stability silently overrode rule 2; User caught it a day later).

1. **Always on (20 names).** `SwiftToolDispatcher.alwaysOnCoreNames`. These are
   the only tools in every request. Agent's working-set ruling of 2026-09-11.
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

Owner: ChatSessionActiveTools.swift (`beginTurn`, `commitTurnStartContract`,
`markUsed`), ChatOrchestrationClient+StructuredChat.swift (`traceFinalToolContract`).
