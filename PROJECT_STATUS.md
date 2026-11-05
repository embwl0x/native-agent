# NativeAgent Project Status

Source status: 2026-10-20. This describes the checkout, not a release or
installed-app verification. Release history lives in [CHANGELOG.md](CHANGELOG.md)
and [release notes](docs/release-notes/).

## What it is

One brain, many doors. `NativeAgent.app` hosts the Swift runtime in-process.
The core's `EngineRuntime` composes it and `ChatTurnRuntime` owns resident turn
execution. StandingBots owns helpers' model/tool loops over their own transcripts.
Mac, iPhone, Telegram, Slack and local agent bridges reach that
shared engine.

The Mac has Simple, Advanced and Agent views. Simple presents chat, contacts
and helpers; Advanced exposes the full page rail; Agent draws their Home face
with row actions and keeps the other rooms as read-only text.

## Where things stand

| Area | Current source contract |
|---|---|
| Releases | Mac v0.6.9 is the current public release as of 2026-10-20 (Developer ID signed, notarized, Sparkle). The iPhone companion ships through TestFlight. The [Releases page](https://github.com/embwl0x/native-agent/releases) is authoritative for what has shipped. |
| Agent interface | `app` is the only always-on tool. `app {}` is home; `page`, `item`, `find`, `action` and JavaScriptCore `script` reach capabilities through `AppActionRegistry`. |
| Discovery | Pages and actions arrive in tool results. Retired tool names are refused with a translated `app` call; there is nothing to load or unload. |
| macOS grants | Owned permission remedies automatically file `permissions.request` through the composed tool return; already-allowed access skips the card and an open card for the capability is reused. Results retain the original outcome and name the card for the person. Only the person's foreground Allow tap invokes macOS acquisition. Card and Settings acquisition wait at most three seconds for activation, release observation on every exit, and request no grant if still inactive or cancelled; Settings retains the activation failure. See [the tool contract](docs/TOOL_LOADING.md). |
| Growth and MCP | Authored executable tools and legacy executable skills migrated into `data/abilities/` alongside senses and turns: one current file, optional previous/proposed files and independent run state, with exact admission/proof and explicit lifecycle actions. Built-in skill guidance remains in the persona's `skills/bodies/`, read and never run; the [manifest spec](docs/skill_manifest_spec.md) owns that distinction. An MCP server they wants is an ability they grows; NativeAgent keeps no MCP client. |
| Web search | `web.search` uses the configured SearXNG endpoint; without one it returns `searxng_not_configured`. Discovery/selection is explicit Research setup, never search or Doctor recovery through another endpoint. Checked discovery distinguishes refused listeners from failed probes/inventory: a candidate's failure is a named gap while other candidates proceed, including when a reachable endpoint is selected; required configuration/inventory failures stop discovery. Responses validate current result fields and engine-failure evidence before admission: malformed result and engine-failure rows become named gaps while valid siblings return; required envelope failures still fail the search. The Research view, tool result and Lab evidence retain result gaps. Doctor answering/readiness checks stay unverified when no usable results remain and parse gaps prevent a conclusive empty response. Fetch receipt retention reports its own checked failure independently of completed reads. Research Lab uses the same search route; the editable `research-lab.js` part selects sources and writes the brief from explicit native evidence, while Swift commits locked capped history and receipts and requires the complete current saved run shape. No browser search route or Codex search implementation remains. |
| Web reads and maps | `web.read` returns the whole extracted text, or with `find` the matching paragraphs with surroundings (`full:true` asks for the whole text instead). Source receipts name their retained file and purpose; DNS, connection refusal and timeout keep distinct causes. `maps.search` splits an inline near/in/around location when `near` is absent/empty and reports it; `maps.route` returns every step with segment-distance meaning and `traffic:not_included` ideal-conditions timing. See [tool contract](docs/TOOL_LOADING.md). |
| Memory | MemoryV2 stores durable memories; Fluid Context prepares bounded context. Conversation replay keeps its verbatim tail at the model-default window, deriving whole-turn checkpoints in half-budget jumps from the transcript at the bound; no stored cut pointer, summary, digest or aging pass. See [context history](docs/conversation-context-history.md). |
| REM proposals | The [replacement-evidence contract](docs/COGNITION_WIRING.md#rem-proposal-replacement-evidence) owns displaced-content provenance, review and approval behavior. |
| Work | Desk holds durable work. Helpers run their own model/tool loops with their names, personalities, jobs and transcripts; they follow Chat's Providers settings unless explicitly pinned and reach the resident through the contact path. Following helpers refuse conflicting settings at the submitted field and acknowledge inherited-value no-ops. See [helper settings](docs/USER_GUIDE.md#helpers-standing-bots). |
| Providers | Chat, Work, and Memory and mind are the three routing groups; Work and Memory and mind inherit Chat's model/account unless configured. Think and Fast use effort-only and tier-only group transactions: each changes its field across every member without pinning the resolved model/account or the other control. |
| Trust | Full Mac grants autonomy without a timer. macOS privacy permission resets still ask the owner. A turn an agent you have not trusted started with its message gets one card on its first effect, and the answer covers the rest of that turn; a read steers nothing. Agents enabled in Trust → Connected agents carry the owner's authority on authenticated turns; ordinary Trust and domain checks remain. |
| Arrivals | A message that reaches a conversation while they works joins their turn there at its next step, from any door (`TurnAdmission.run` with a typed `TurnArrival`); that turn's reply answers it and the door that sent it posts nothing. One they never reads runs as its own turn through its own door. There is no send-next queue. Contract: [Anatomy of a turn](docs/ANATOMY_OF_A_TURN.md#1-a-surface-admits-the-turn). |

## Known limits

- Mac permissions, explicit blocks, connector authentication and origin checks
  still apply under Full Mac.
- The iPhone companion needs the Mac awake with NativeAgent open.
- A configured connection or a returned tool result alone does not prove an
  external action completed; inspect the action's receipt and owning service.

## Where to read next

- [README](README.md) — install and first run.
- [User and Agent Guide](docs/USER_GUIDE.md) — pages and everyday operation.
- [Capabilities](docs/CAPABILITIES.md) — source-backed capability map.
- [App tool contract](docs/TOOL_LOADING.md) — the single tool interface.
- [Documentation guide](docs/README.md) — documents and their readers.
- [AGENTS.md](AGENTS.md) — repository working rules.
