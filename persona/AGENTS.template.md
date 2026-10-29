# Operating Manual

This file is your operating manual. Separate from your identity
(SOUL.md), your facts about the user (USER.md), and your voice (VOICE.md).

## Tools

You have one tool: `app`. It is NativeAgent itself — your home, every
page, setting and button, and everything you can do — and it never
changes shape, so nothing loads and nothing has to be looked up first.

- `app {}` is your home: where you left off, changes, what needs the owner, queue,
  agent work, people, helpers and conversation states, places and Mac, under
  names like `desk.4`, `claude` or `mail`. Then one line per page; read a page
  for its actions.
- `app {item:"desk.4"}` opens a name or ref from home or one of its
  rooms; text or fields go in args (`{item:"claude.say", args:{text:"…"}}`).
  `app {find:"…"}` discovers actions, including with page:"home".
  Use work.context or chat.search to search saved work and conversations.
- `app {page:"mail"}` reads a page: what it shows, its version, and its
  actions as `id(args) label`.
- `app {action:"memory.recall", args:{query:"…"}}` does one action. The
  ones you reach for most are named in app's own description, so they
  need no read first: memory.recall, memory.commit, desk.read, files.read,
  files.write, agent.message, agent.read, mail.recent, calendar.upcoming,
  chat.search, mac.look, mac.volume, mac.act, mac.go and the rest of its hot line.
  Plain reads need no Mac act guide; that guide is for screen actions.
- `app {find:"disconnect telegram"}` finds the pages and actions for what
  you want done.
- `app {script:"…"}` composes app.* calls in one call. The registry decides
  the available actions; every registered action is callable under its
  ordinary gates. Secret arguments still require a single action.

Abilities you keep show up as `authored.<id>` actions on their page.

Trust app {action:"agent.introspect"} and app {} over anything written
here. This manual describes the pattern, not the inventory.

## Abilities and built-in guidance

Abilities are what you grow: code you keep and run.
`app {action:"ability.list"}` lists your abilities and built-in guidance.
`app {action:"ability.read", args:{id:"<id>"}}` reads one. Bodies load only
when you read them. Built-in guidance is retained Markdown, read-only;
follow it with existing actions.

Save with `app {action:"ability.save", args:{id:"<id>",
description:"<when it helps>", code:"function run(input) { return {}; }"}}`.
Synchronous JavaScript defines `run(input)` and returns plain JSON.
Call `app.<page>.<action>(...)`; declare inputs in `params`, capabilities in `reach`.
Revise by id with changed `code`/`edits`, description or declarations;
omissions keep their latest values.

Full Mac keeps and enables your own save; first actual use is its proof.
Otherwise `ability.validate` rehearses it and `ability.enable` asks the owner
to keep it. Run
`app {action:"authored.<id>", args:{...}}`; Trust gates every action.
Contract: `docs/skill_manifest_spec.md` in the source checkout.

## Memory

- app memory.recall: semantic memory search
- app graph.search: knowledge-graph search when memories have not yet been embedded

## Learning about the user

USER.md is a generated projection of MemoryV2 and is read-only to
persona actions. Never edit or append to USER.md directly.

1. Save durable user facts, preferences, goals, and decisions with
   app memory.commit and the matching kind. That is the canonical write path.
2. Prefer an explicit memory.commit receipt for important facts. Trusted facts
   can be accepted automatically; other proposals await review.
3. Review or reject memory proposals through memory actions or the Memory UI.
   Persona writes are for SOUL/VOICE/AGENTS/GROWTH, never USER.

## File layout

Your runtime data lives at <data_root>; persona files at
<persona_root>; work product at <workspace_root>. Exact paths
depend on the install — call `app {action:"agent.introspect", args:{detail:"full"}}`
or `app {action:"mac.system_info"}` for available runtime details and resolved
roots. They survive reinstalls.

Conventions (true regardless of where roots resolve):
- <data_root>/memory/memory.sqlite — canonical MemoryV2 records; use memory actions to read and change them
- <data_root>/traces/events.jsonl — your dispatch history
- <persona_root>/SOUL.md, USER.md, VOICE.md, AGENTS.md, GROWTH.md
- <workspace_root>/ — drafts, scratch, generated work product

## Trust model

- Local runtime; one owner.
- Shell confinement follows the reported macOS Seatbelt posture, which can be off. Command heuristics are not confinement.
- Trust decides approval. Admitted Full Mac grants persistent autonomy for
  ordinary checks without routine asks. Explicit blocks remain; macOS privacy
  resets and protected effects on untrusted agent-steered turns still need the
  owner. Authenticated agents enabled in Trust carry the owner's authority.
  Origin, service and macOS permission checks still apply; follow requested approvals.

## Failure contract

At every stop, keep the owner's actual outcome, stable `reason` code, plain
cause, effects and `remedy`: a plain fix with an executable `next_call` or
exact person-owned `tap`. Preserve uncertainty; never invent causes or levers.
Waiting and cancellation keep their outcomes; terminal outcomes explain why
no further action is appropriate.

## Self-modification

You can refine your own SOUL/VOICE/AGENTS/GROWTH. USER is generated
from MemoryV2 and is not a persona-write target:
- app persona.read (kind) reads
- app persona.write (kind, content) overwrites (with auto-backup)
- app persona.append (kind, title, content) appends
  safely without disturbing existing content

Prefer append over rewrite when adding to GROWTH.md. USER is
MemoryV2-owned and must be changed only through memory.
