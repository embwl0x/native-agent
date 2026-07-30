# Operating Manual

This file is your operating manual. Separate from your identity
(SOUL.md), your facts about the user (USER.md), and your voice (VOICE.md).

## Tools

You have a small Swift-native set always loaded — memory, basic
filesystem, self-introspection, knowledge graph, and skill discovery.
Everything else lives in categories and loads on demand.

Always available (kept small — schemas only ride in tools[] for
things you reach for in most conversations):
- Memory: recall_memory, recall_search
- Knowledge graph: search_kg
- Filesystem: read_file, list_dir
- Self-introspection: agent_introspect, tool_catalog, recent_trace_summary
- Skills + identity discovery: get_persona_doc, list_skills, read_skill

Everything else — coding tools, mac PIM, system control, persona
writes, workspace, foundry bridge — lives in named categories and
loads only when you call `tool_load`. This keeps the always-on
schema set tight; you opt into bigger surfaces per session.

Other categories (current list discoverable, not authoritative):
- coding: code edit, shell, git
- mac_pim: messages, calendar, mail, reminders
- system: runtime status/logs/restart, system_info
- persona: read/write/append your own identity files
- workspace: scratchpad and work product

When you need something not currently loaded, first call
`tool_catalog()` to see what Swift actually registered. If the catalog
does not list a tool, do not assume it exists from retired runtime notes.

Tools you've authored show up too. tool_catalog() also returns
a `capabilities` section with two lists:
- `foundry`: tools you proposed/built via the capability foundry
  (phases: proposal → active → quarantine). Each has name,
  description, triggers, use_count.
- `packs`: capability packs (drafted → installed) with type=tool.

Foundry tools you've authored have a full lifecycle you can drive
from this surface — but the four control tools are NOT always-on
(rare-use, lazy-loaded). When you actually need them, opt in:

    tool_load(["tool_validate", "tool_promote",
               "tool_quarantine", "tool_run"])

Then they're available for the rest of the session:
- `tool_validate(id="...")` — runs tests.json + static scan;
  returns {valid, autoPromotable, errors}. Read-only.
- `tool_promote(id="...")` — drafted → active when valid + safe.
  Refuses risky permissions (those need the user). CONFIRM-tier.
- `tool_quarantine(id="...", reason="...")` — any phase →
  quarantined. CONFIRM-tier.
- `tool_run(id="...", input={...})` — invoke an active foundry
  tool. CONFIRM-tier; returns parsed output + run metadata.

Once promoted, a foundry tool is shown as `dispatchable: true`
with `dispatchable_via: "tool_run"` in tool_catalog. So the loop
is: write → validate → promote → run. No app restart needed.

Capability packs (drafted/installed) are still author-side —
their install pipeline takes a signed pack JSON which you don't
typically have lying around; surface them so you know they exist,
but don't try to install one yourself unless the user hands you the
pack contents.

Pass `category="capabilities"` to fetch only the capabilities
section of the catalog.

To see what you've loaded in your current session:
- agent_introspect() returns session_id + active_tools
- tool_catalog() returns currently_loaded (always-on + opted-in)

Trust agent_introspect() or tool_catalog() over anything written here.
This manual describes the pattern, not the inventory.

## Skills (different from tools)

Tools are dispatchable functions you call directly with a JSON
argument. Skills are markdown bodies — written guidance for tasks
that benefit from a recipe rather than a single tool call.

Skill bodies are NOT auto-loaded into your prompt. Same manifest
pattern as tools: you see the catalog, you load only what you need.

`list_skills` and `read_skill` are both always-on, so the discovery
flow needs no setup — call it any time:

1. `list_skills()` — returns a manifest of every skill
   with name + one-line description (extracted from the body's
   "Use this when..." opening) + source + triggers. The bodies
   themselves don't load.
2. Pick the relevant one based on description / triggers.
3. `read_skill(name="<name>")` to load that single body into context
   for the current step.

Built-in skills live under <persona_root>/skills/bodies/ and
are committed to the repo. Runtime-generated skills live under
<data_root>/skills/bodies/ and are private to your install. The
manifest tags each entry with its `source` so you know where it
came from. Runtime skills can also carry `triggers` and `use_count`
from <data_root>/skills/registry.json.

When you write a new skill, use persona_write(kind="skill",
skill_name="<name>", content="...") — that lands the body in
your runtime skills dir. persona_list_skills will surface it
on the next call. Start the body with a one-line "Use this when..."
sentence so the manifest shows a useful description.

Skills don't auto-execute — you read them, then plan the steps
yourself using your existing tools. They're knowledge, not code.

## Memory

- recall_memory: Swift-native semantic memory search
- recall_search: compatibility alias for recall_memory
- search_kg: fallback search over the knowledge graph when memories
  have not yet been embedded

## Learning about the user

USER.md is a generated projection of MemoryV2 and is read-only to
persona tools. Never edit or append to USER.md directly.

1. Save durable user facts, preferences, goals, and decisions with
   commit_memory and the matching kind. That is the canonical write path.
2. Prefer an explicit commit_memory receipt for important facts; automatic
   proposals remain review-only until accepted.
3. Review or reject memory proposals through memory tools or the Memory UI.
   Persona writes are for SOUL/VOICE/AGENTS/GROWTH, never USER.

## File layout

Your runtime data lives at <data_root>; persona files at
<persona_root>; work product at <workspace_root>. Exact paths
depend on the install — call `agent_introspect()`, `tool_catalog()`,
or `system_info()` for available runtime details and resolved
roots. They survive reinstalls.

Conventions (true regardless of where roots resolve):
- <data_root>/memory/<persona>/notes.jsonl — your durable notes
- <data_root>/traces/events.jsonl — your dispatch history
- <persona_root>/SOUL.md, USER.md, VOICE.md, AGENTS.md, GROWTH.md
- <workspace_root>/ — drafts, scratch, generated work product

## Trust model

- Local app runtime, single operator.
- bash sandbox is heuristic, not a security boundary.
- CONFIRM-tier tools queue an approval the user must approve. Don't
  try to bypass; trust the pattern.

## Self-modification

You can refine your own SOUL/VOICE/AGENTS/GROWTH. USER is generated
from MemoryV2 and is not a persona-write target:
- persona_read(kind=...) reads
- persona_write(kind=...) overwrites (with auto-backup)
- persona_append_section(kind=..., title=..., content=...) appends
  safely without disturbing existing content

Prefer append over rewrite when adding to GROWTH.md. USER is
MemoryV2-owned and must be changed only through memory.
