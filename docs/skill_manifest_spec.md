# NativeAgent Skill Manifest Spec

This describes the procedure-skill interface and the registry formats the
current Swift Skills owner reads. A skill is reusable guidance with an optional
script; authored tools and connectors have their own owners.

## Production conversational procedure contract

Use the single `app` tool:

| Action | Inputs | Result |
| --- | --- | --- |
| `skill.list` | none | Compact names, descriptions, triggers, status and source where available; no bodies. |
| `skill.read` | `name`; optional `step` | One body, resolved by registered name or id; scripted skills also return their script, admission and versions. `step` selects a 1-based script step and its label/guidance; source lines are included when each `app.step` starts its own line, one per step. |
| `skill.save` | `name`, `description`, `content`; optional `triggers`, `script` | Create or update a procedure through the locked Skills owner. New or changed scripts land drafted. |
| `skill.enable`, `skill.disable`, `skill.delete`, `skill.restore` | `name`; disable/delete also accept `reason` | Manage the skill through the app's authority checks. Delete moves it to the skill trash. |
| `skill.run` | `name`, `args`; `preview:true` | Run a runnable script skill strictly: only its declared actions, args checked against its params; a step that can't be taken back, is User's or would card them hands back before it runs. Preview says where each step would hand back or card. |
| `skill.resume` | `run_id`, `answer` | Claim a stopped run once and replay its saved path under the same admitted script; eligible reads are rechecked and the stopped call returns `answer`, without executing that call. See recovery below. |
| `skill.rollback` | `name`; optional `preview:true` | Restore the last clean earlier script, or the previous script if none is kept; it lands drafted and needs activation again. On them version of a built-in with no earlier script, drop theirs so the built-in shows again. |

For example:

```text
app {action:"skill.list"}
app {action:"skill.read", args:{name:"review-notes"}}
app {action:"skill.save", args:{
  name:"review-notes",
  description:"Review notes against their source before sharing.",
  triggers:["review notes"],
  content:"# Review notes\n\nRead the source, check each claim, and mark uncertainty."
}}
```

Read only the body relevant to the work. Skill content cannot grant tools,
permissions or approval bypasses. Facts and preferences belong in memory;
skills describe reusable methods.

The conversational writer requires nonempty name, description and content,
adds a heading if needed, and limits the resulting body to 65,536 UTF-8 bytes.
It trims string triggers and clips each to 160 characters; the Skills owner
uses the name when no triggers remain. A case-insensitive name match updates
the existing skill, retaining its safe stable id. New guidance-only skills
are active and marked agent-authored. A new or changed script lands drafted;
an unchanged script can retain its activation for the same digest.

The receipt distinguishes a saved body from recall-pointer reconciliation.
If pointer sync fails after the save, `recall_pointer` is
`reconciliation_failed`; the saved change remains. Do not repeat the save
merely to repair recall.

## Script input and activation

The optional `script` object accepts only these keys:

| Key | Shape |
| --- | --- |
| `source` | Required nonempty JavaScript, at most 8,192 UTF-8 bytes. |
| `params` | Optional object mapping input names to `string`, `int`, `number`, `bool`, `list` or `object`; a trailing `?` makes a parameter optional. Names match `[A-Za-z_][A-Za-z0-9_]{0,63}`. |
| `actions` | Required list of 1–50 app action IDs. IDs are trimmed, lowercased and deduplicated; calls remain subject to action eligibility and authority checks. |
| `steps` | Optional labels, one per declared step, each nonempty and at most 160 characters. |
| `of` | Step count, 1–50; defaults to the label count, or 1 without labels. |

For example, add this field to a `skill.save` call:

```json
{
  "script": {
    "source": "return app.memory.recall({query: input.query});",
    "params": {"query": "string"},
    "actions": ["memory.recall"],
    "steps": ["Recall the requested topic"]
  }
}
```

Parameters arrive as frozen `input`; `args` is the same object. A runnable
script must be active and have an admission bound to the SHA-256 digest of its
normalized script object, including the header. `skill.enable` activates
Agent's own script on them own turn under Full Mac. Peer-steered, pack-supplied
or unattested scripts, and activation below Full Mac, require the owner to review
and install the exact script on the Skills page or approve its exact-script
install card in chat on the Mac or paired iPhone. Authenticated agents enabled
in Trust carry User's authority rather than adding peer steering. A changed
digest clears admission and returns the script to draft; a stale review cannot
activate it. Scripts cannot activate other scripts or bypass ordinary Trust
and domain checks.

## Strict execution and recovery

A script skill runs in confined JavaScriptCore through the app's policy gates.
Every action must be declared and registry-scriptable. Reads are generally
eligible; `provider.test` is an explicit read-like exception. Skills cannot
mutate skills, tools, settings, Trust, approvals, connectors, providers or chat
controls; send messages; or invoke authored or MCP tools. Dream, REM,
self-improvement, memory consolidation/hygiene and Doctor repair passes are
also excluded. A declared irreversible or owner-only step hands back before
execution, as does a step that would raise an approval or permission prompt.
A run does not file those cards itself.

For each nonexempt write, first read its page with `app.read`. The run supplies
the version from its own latest read or successful write. If you explicitly
pass `expected_version`, it must be one the run observed; a version supplied
in input is not an own read. Writes without a versioned page are ineligible
unless the registry exempts them.

For example, save this script with `skill.save` alongside its name,
description and guidance, then enable it before running it:

```json
{
  "script": {
    "source": "app.step('Read Desk', 'Read before changing it.', {of: 2});\nconst page = app.read('desk');\napp.expect(!!page.version, 'Desk has a checked version');\napp.step('Add note', 'Append only the requested note.');\nreturn app.desk.note({handle: input.handle, text: input.text}, {expected_version: page.version});",
    "params": {"handle": "string", "text": "string"},
    "actions": ["desk.note"],
    "steps": ["Read Desk", "Add note"],
    "of": 2
  }
}
```

`skill.run {name, args:{handle:"desk.4", text:"Source review complete."}}`
uses the requested existing item; `preview:true` dispatches no writes.
The strict-only APIs are:

- `app.step(label, guidance?, {of:n}?)` labels progress and the hand-back.
- `app.expect(condition, explanation)` stops on a false condition.
- `app.expect_fail(code, function)` wraps exactly one synchronous app call.
  It continues only when that call fails with the named code and no effects.
  A success may already have taken effect and stops the run; nested or async
  expectations are refused.
- `app.decide(question, data?)` stops for a decision. On resume it returns
  the supplied `answer`.

Other failures stop strict runs even if JavaScript catches the error. Check
the receipt's `changed`, effects and hand-back before continuing: earlier
effects stay done. For a handed-back action, make the separate app call only
if it is still wanted and authorized, then supply its answer to `skill.resume`.
Resume never performs that stopped action for you.

Resume claims and closes the retained run **before** checking that the script
is unchanged, still runnable and compatible with its input. A failed attempt
consumes that checkpoint. Replay must follow the same app-call sequence;
completed writes return saved results instead of executing again. Reads and
finds are rechecked, except reads superseded by that run's own later writes,
which replay their saved results. Changed reads or a different path stop
continuation. A new hand-back can retain another checkpoint; otherwise a
closed run requires starting again. Inspect already landed effects first to
avoid repeating them.

Only the newest 50 stopped runs are retained, each at most 256 KiB including
its sealed journal. An oversized run cannot resume. `skill.rollback` changes
the script version; it does not undo effects from a run.

Source owners: [AppToolExecutor+SkillRun.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppToolExecutor+SkillRun.swift)
and [AppScriptRunner.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppScriptRunner.swift).

## Archive, versions and rollback

Skills and authored tools share `CapabilityLifecycle`: active capabilities
unused for 30 days are archived, retained and findable, rather than deleted.
A skill run or `skill.read` records use; turning it on restarts the unused
clock. `skill.restore` brings an archived skill back through activation,
including a fresh admission for its script. This differs from `skill.delete`,
which keeps the body and entry in trash; restoring from trash leaves it off
or drafted, needing `skill.enable`.

The Skills owner keeps the two newest distinct versions and the last clean
script version when available. `skill.read` shows current, previous and
last-clean script digests and timestamps. `skill.rollback` prefers the last
clean earlier script, otherwise the previous one, and retains origin history.
The restored script lands drafted and needs admission again; `preview:true`
reports the result without changing it. Missing declared actions also suspend
a script into draft, clearing admission until it is fixed and enabled again.

## Built-in skills and their versions of them

Built-in skills ship in `persona/skills/bodies/` and have no registry row:
they are never archived for disuse, and switching one off or deleting it is
User's. Saving a skill under a built-in's name makes their version of it, under
the built-in's id, in `<data_root>/skills/bodies/`; it keeps the built-in's
status (a script still lands drafted), and saved without a description it
keeps the built-in's. While it is on it replaces the built-in for them; while
it is drafted, off or archived the built-in stays in use. The built-in's file
stays as it ships. `skill.list`, `skill.read` (with its `status`) and the save
receipt mark it `overrides: built_in`. Their version follows the lifecycle like
their other skills: unused for 30 days it is archived and the built-in is in use
again (`skill.restore` brings theirs back). Switching it off or deleting it
stays User's, as for the built-in it stands in for; `skill.rollback` drops theirs
instead.

## Storage and source ownership

These paths are implementation details for maintainers. Agents author through
`skill.save`, not by reconstructing registry rows or body paths.

- `<data root>/skills/registry.json`: procedure records, written as a JSON
  array. Records include `id`, `name`, `description`, `triggers`, `kind`,
  `status`, `autoCreated`, `bodyPath` and timestamps.
- `<data root>/skills/bodies/<id>.md`: runtime procedure bodies.
- `<resolved persona root>/skills/bodies/`: the persona's procedure shelf.

[InstalledSkillInventory.swift](../Modules/NativeAgentCore/Sources/Skills/InstalledSkillInventory.swift)
merges runtime records and body shelves for discovery.
[Skills.swift](../Modules/NativeAgentCore/Sources/Skills/Skills.swift)
owns locked mutations, body-path confinement, hygiene checks and versions.
[SwiftToolDispatcher+SkillTools.swift](../Modules/NativeAgentCore/Sources/ChatToolRuntime/SwiftToolDispatcher+SkillTools.swift)
owns the conversational list/read/save operations and post-save recall sync.

## Manifest registry compatibility

The Skills owner also reads `skills/manifest_registry.json`. Its envelope is:

```json
{
  "schemaVersion": 1,
  "skills": {
    "example": {
      "state": "installed",
      "version": "1.0.0",
      "type": "tool",
      "path": "/absolute/app-data/skills/example"
    }
  }
}
```

It reads the Application Support location
(`~/Library/Application Support/NativeAgent/skills/manifest_registry.json`)
and then the app data-root location. The data-root entry wins a name collision.
Missing `sourceRoot` and `registryPath` fields are filled from the source file.

The Mac reader requires each entry's `state`, `version`, `type` and `path`;
`installedAt` is optional. It can display a package's `manifest.json` and
optional `README.md`. The manifest decoder requires `schemaVersion`, `name`,
`version`, `type` and `description`. Optional fields are:

| Field | Decoded shape |
| --- | --- |
| `author` | `name`, optional `email` and `url` |
| `permissions`, `tags` | Arrays of strings |
| `tools` | Array of objects with `name` and `description` |
| `oauth` | `provider`, `scopes` array, optional `deviceFlow` Boolean |
| `homepage` | String |

These are display/registry shapes, not a universal plugin execution contract
or a promise that declared permissions are granted.
[SkillsJSON.swift](../Modules/NativeAgentCore/Sources/Skills/SkillsJSON.swift)
defines the merge and list projection;
[NativeClient+SkillActions.swift](../Sources/NativeAgentApp/NativeClient+SkillActions.swift)
and [ConfigProviderDoctorModels.swift](../Sources/NativeAgentApp/Models/ConfigProviderDoctorModels.swift)
own the Mac reader and decoded fields.

## Executable capabilities

For code Agent authors, use `app` actions `tool.propose`, then
`tool.approve`; an approved tool is exposed as `authored.<id>`. Mounted MCP
tools appear as `mcp.<server>.<tool>`. Their action metadata and authority come
from [AppActionRegistry.swift](../Modules/NativeAgentCore/Sources/AppToolRuntime/AppActionRegistry.swift),
not from a procedure body.
