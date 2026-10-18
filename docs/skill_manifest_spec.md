# NativeAgent Part Header and Skill Manifest Spec

Every `abilities/<id>.js` or `.md` is a part: a JSON header in a
`/* NativeAgent ability … */` or `<!-- NativeAgent ability … -->` comment,
followed by its code or guidance. `kind` is `tool`, `skill`, `sense` or `turn`.
All kinds have the same header and one 524,288-byte (512 KB) source limit.

`turn` is their turn: `abilities/turn.js` exports `step(state, event)` and returns
`{state, do: [effects]}`; it runs no loop of its own. The stem delivers
`message`, `model` (the final text and the calls asked for, each with `id` and
`index`), `result` (one call's `{index, id, name, ok}`), `observation` and
`resumed`, and runs `model.call` (purpose; the first one names `system:
{stable, dynamic}` and `tools`), `app` (one call of the current model round,
named by id or index, run verbatim through the turn's gates, once),
`reply.stream`, `reply.end` (only after a model reply without calls) and
`after`. Its reach is `turn.persona()`, `turn.pins()`, `turn.recall()` and
`turn.context()`. The turn's log keeps the events, the reach answers each step
read, the effects started (by identity: the model call id, or the effect's own
`id`, with a payload digest) and the reply text streamed; resume and heal
rebuild from it, matching starts and results by identity. The version that
runs is the root's `turn.js` if it reads cleanly, else a clean `turn.prev.js`,
else the seed the app ships (installed when the store accepts it). A step that
throws or answers malformed swaps back on the failing version only, and the
same turn replays through what came back. Not yet honoured: a later
`model.call` naming another system, and `messages`, `stream` or `chunks` on it.

| Property | Stored form and meaning |
|---|---|
| **code** | The file body, outside the JSON comment; JavaScript or retained Markdown guidance. |
| **reach** | `{capabilities: string[], readPaths: string[], hosts: string[], apps: string[]}`, all arrays default empty. `capabilities` carries the former tool permissions; paths, hosts and apps carry the former `SenseReach`. Legacy `permissions` and sense reach load into this shape; saves write `reach`. Declarations do not grant authority. |
| **wake** | String array, default `[]` (called only). Accepted names: `schedule:<cron>`, `app.installed`, `file.changed:<path>`, `turn.ended`, `message.arrived:<transport>`; suffixes must be nonempty. While a part is on and the owner's Autonomy switch allows unattended work, each signal reaches it once with input `{signal, at, ...payload}`: a tool or skill runs through the door, a sense hears it as an event in its resident slot. `schedule:` is one TriggerScheduler job per part and schedule (fires that land while a run waits are one); `app.installed` adds `bundle_id`, `name`, `version`, `path`, `scriptable` as plain data (a bundle id at a version not seen since the first scan's baseline, once its Info.plist and declared scripting dictionary have landed); `file.changed:` adds `path` (the senses' own watch, which waits through the file's absence; the part's own writes, exactly as it left them, are not news); `turn.ended` adds `turn_id`, `outcome`, `session_id`, `trace` (its day file under `turn_traces/`; a turn the part's own run started does not wake it); `message.arrived:telegram|slack` adds `text`, `session_id`, `turn_id` and the chat/channel and user ids, once the message was handled. `agent` names whose words the input carries when they are not the owner's (a sender not allowlisted by user, a turn an untrusted agent steered); the run is then tainted as a turn would be. The run's gate chain is their own with no turn behind it: current Trust, a card for an effect that needs one (the run waits), and `home.arrive {line}` for anything it needs from them (one arrival per part, day and line, on the part's own hop-limited thread). A skill's params must take the input's keys. |
| **face** | `{page?: string}`, default `{}`. An authored tool's action lists on this door page, or diagnostics when absent. Unknown pages refuse at save and name the accepted pages. No renderer or new page is added. |
| **state** | Tools and skills use `host.state.get()` → saved JSON (initially `null`) and `host.state.set(value)` → `null`. One durable notebook owner, shared with senses' keyed `state.get/set`, stores it by part id at `senses/<id>/state.json` under key `part`; it survives helper restarts and app relaunch. Values are limited to 16 KiB and the notebook to 64 KiB. Validation and preview use a scratch notebook. Skill resume replays journaled state results without repeating their operations, then reads and writes durable state normally. State calls do not renew stalled execution. `abilities/state.json` remains lifecycle/run accounting only; there is no authored header `state` key. |
| **learned** | Optional arbitrary JSON, preserved verbatim. Reserved for phase 4; no learning behavior. |

`id` and integer `version` retain their existing identity/lifecycle meaning.
`choices` is optional arbitrary JSON, preserved verbatim for phase 4 (for
example `{open_doc:["script","menu","screen"],date_format:[]}`).
`resident` is a Boolean, default `false`: tools and skills keep their isolated
helper and JS context between successful calls. Each call receives fresh frozen
input and its own originating authority; an error, refusal, cut or cancellation
discards the context. Preview, validation and replay use fresh contexts.
Senses retain their existing source-bound context lifecycle.

Reach capability names are `app_data_read`, `app_data_write`,
`network_localhost`, `network_public`, `network`, `shell`, `computer_files`,
`arbitrary_file_write`, `app_read:<bundle_id>` and `app_write:<bundle_id>`.
`model`, `connector:<id>`, `calendar`, `reminders` and `contacts` are also
accepted names, reserved for the primitives lane; they add no behavior here.
Unknown capability names, wake names, header keys and reach/face keys refuse by
name. Existing lifecycle fields (`record`, `candidate`, `proof`, `sourceFiles`)
remain store-owned. Retained sealed legacy candidate descriptors are unchanged,
including their internal permission spelling, so loading does not invalidate
their exact-code admission or proof.

```json
{
  "id": "mail_summary", "kind": "tool", "version": 1,
  "reach": {"capabilities": ["app_read:com.apple.mail"], "readPaths": [], "hosts": [], "apps": []},
  "wake": [], "face": {"page": "mail"}, "resident": true,
  "learned": {}, "choices": {"open_doc": ["script", "menu", "screen"]}
}
```

```json
{"id":"mail_routine","kind":"skill","version":1,"reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":[]},"wake":[],"face":{"page":"skills"},"resident":false,"learned":{},"choices":{}}
```

```json
{"id":"mail_reader","kind":"sense","version":1,"reach":{"capabilities":[],"readPaths":[],"hosts":[],"apps":["com.apple.mail"]},"wake":["file.changed:/tmp/example"],"face":{"page":"mail"},"resident":true,"learned":{},"choices":{}}
```

```json
{"id":"turn","kind":"turn","version":1,"reach":{"capabilities":["model","connector:telegram","calendar","reminders","contacts"],"readPaths":[],"hosts":[],"apps":[]},"wake":["message.arrived:telegram","turn.ended","app.installed","schedule:0 9 * * *"],"face":{"page":"chat"},"resident":false,"learned":{},"choices":{}}
```

These examples show the common header. Existing store-owned `record`,
`candidate`, `proof` and `sourceFiles` fields carry their unchanged lifecycle
payloads alongside it; a header alone is not admission to execute.

`skill.save`, `tool.propose` and `sense.make` accept `reach`, `wake`, `face`,
`resident`, `learned` and `choices` alongside their existing authoring fields.
Legacy tool `permissions` and sense `apps` remain accepted at the door.
The census and existing tools/skills/senses reads expose each part's reach,
wake, face and residency; no new page is needed.

Skills are JavaScript routines behind the existing app door. A matching routine
arrives through recall or discovery; its description and signature lead to
`skill.run`. No skill grants authority or adds an always-on tool schema.

The bundled resident `habit` part wakes on `turn.ended`. `trace.recent
{view:"shapes",turn_id,trace}` reads only the signal's exact trace day file per page and returns model-chosen app action ids,
argument keys/types and call times, in reverse call order, without values;
an explicit model-chosen action batch keeps its constituent call order;
skill runs and their nested calls are excluded. A truncated envelope marks the sequence incomplete; habit skips it. Habit remembers fixed-size
128-bit fingerprints for the last 32 turns in its notebook. A second occurrence thinks once with purpose
`habit`, stages a skill through `skill.save {create_only:true}`, and files one `home.arrive` line.
The save owner refuses names/identities in any retained slot or state; habit
retries with the sequence digest suffixed to the name, without replacing a draft.
Offered signatures remain remembered even when a proposal is dropped. There is
no timer or other model call. Offered fingerprints are never evicted; a full
notebook refuses visibly before another thought or proposal. The older repetition
detector remains pending a scope decision: its skill-follow-up revision notices,
per-agent windows, existing-skill coverage and substring matching are not part
of this whole-sequence rule. Its removal is not behavior-equivalent.

## Authoring and review

| Action | Contract |
|---|---|
| `skill.list` | Descriptions, signatures, status, runnable state and run calls. |
| `skill.read` | Metadata by default: digest, admission, selected version and retained versions. `source:true` reads exact code and fixtures for authoring/review; `step` selects a labelled code step. |
| `skill.save` | Stable name, one-line description and script. Optional create_only refuses an existing name or identity across all retained ability slots/states before staging. Optional triggers, fixtures, converts and restrictive overrides:built_in metadata. Stages a candidate; a pending revision leaves the working version selected. |
| `skill.validate` | Validates the exact candidate using the shared helper with intercepted replies; optional input and capture. Does not admit it or execute live app effects. |
| `skill.enable` | Publishes the validated candidate under existing origin and owner policy. Owner review binds the complete candidate, including code, fixtures and dependency shapes. |
| `skill.run` | Name and args matching its signature. Each call passes the ordinary turn's gates. |
| `skill.resume` | A stopped run_id and bounded answer. Rechecks selection, host revision, admission and prior reads; claims once. |
| `skill.quarantine`, `skill.drop`, `skill.rollback`, `skill.restore` | Explicit lifecycle changes; source remains retained. Rollback proposes retained JS for validation and admission; optional version selects an exact historical conversion. skill.read exposes converted_versions and their rollback calls. |

```javascript
function run(input) {
  app.step("Read");
  const result = app.read("skills", input.name);
  const answer = app.decide("Continue?", {result});
  return {result, answer};
}
```

The script header supplies source, params, actions and optional steps/of.
Params map input names to string, int, number, bool, list or object; a trailing
? marks an optional input. A param may also be `{type, description}` with that
same type spelling and a nonempty description. Save retains these declarations;
find/read expose their descriptions and requiredness in the input schema.
No declared params means read the source before running the routine.
Actions list app action IDs, not helper names.
app.read, find, log, expect, expect_fail, decide and step are built in.
Source is limited to 524,288 bytes; steps and dependencies to 50 each.
Tools and skills are sync-only: define function run(input), use synchronous
host/app calls and return plain JSON. Async functions and Promises are refused.
Ad hoc app scripts keep their function-body contract on the same JS executor.

Omitted fixtures record one bounded validation with supplied input (default {}).
A read (a page read, a find, or an action whose arguments are read-only) runs
live through the ordinary gates and its answer is kept; every effect, every call
of a tool they wrote (a program is a run, not a read) and every decision gets a
visible placeholder. Of the tool host primitives, only
host.files.list/count/read/info read live, through declared reach and ordinary
admission. The sealed capture is replayed on later validation.
Hand-written fixtures use input, calls:[{operation,args,result}], answers and
expected; expected is the complete returned JSON. Validation cannot enable code.

## Execution and ownership

A skill receives frozen input and only its declared action dependencies. A
dependency pin binds the action ID, argument and result schemas (excluding
descriptions and other prose), behavioral flags and revision. Wording changes
do not suspend admitted routines. Contract changes do; result semantics without
a schema change require a revision bump. Frozen exact-contract aliases preserve
admitted pre-cutover pin identities without modifying candidates or admissions.
A write uses the version of its own read. Irreversible actions, owner-only steps
and a step that would need a card hand back before dispatch. app.decide saves
a bounded checkpoint. Resume returns saved receipts for landed writes; it never
repeats them. Changed code, admission, dependency shapes, host revision or reads
close/refuse the old run visibly, preserving its journal and held work.

Origins ratchet across revisions, restores, quarantine and rollback. A peer,
pack or unrecorded origin cannot become the resident's own code by saving it.
Owner off/trash marks remain owner-controlled. Converted persona procedures
retain their stable identities and built-in override protections. The census
requires overrides:built_in for the same-identity persona counterpart; save
ratchets this restrictive marker. Rolling back
an override selects retained JS; it never rediscovers the original markdown.
Unused routines may archive through the existing lifecycle, with explicit
restore. DROP retains selected code; rollback never undoes prior host effects.

## Conversion census and cutover

Read `app {page:"tools", item:"census"}` (also Skills) for registered and loose
authored tools, registered scripts/guidance, persona procedures, orphan
proposals, immutable JS candidates, historical rollback sources and senses.
Each entry names language, status, counterpart and blocks_cutover. complete
means no entries have cutover blockers. Unreadable/corrupt evidence is an error.
Read it on the installed final revision: changed action/discovery shapes require
re-saving, validation and exact review of affected routines before cutover.

Optional converts on skill.save and tool.propose lists original source SHA-256
digests from this census. The common candidate identity and validation seal bind
these links. Current active capabilities require an accepted JS counterpart;
inactive originals need validated counterparts without being activated. A
retained legacy rollback version needs an explicit digest link. Conversion
candidates stay retained with their originals. Native fixed Swift senses remain
native; historical authored Swift senses remain readable but cannot run.

Cutover is a merge decision after the installed census reads complete. There
is no runtime census guard or auto-conversion. Markdown and Swift originals
remain history. Failures never try an original body, another language, another
executor or an earlier version. Version rollback is an explicit action.
Skill-specific persona read/write aliases are removed; ordinary persona
documents retain their owners.

## Storage and package metadata

InstalledSkillInventory reads canonical registry metadata only. SwiftNativeSkillsClient
adapts origin, admission, selection and off ownership to OwnedProgramStore's
immutable candidates, sealed validation and publication. Historical bodies and
history files are census material, not execution or ordinary discovery sources.
Pack skill installs stage JS candidates through this same lifecycle; pack removal
trashes their registry rows while retaining sources. Pack/connector inventories
retain their manifest metadata, permission and OAuth ownership.

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
[AppModel+SkillsIntegrations.swift](../Sources/NativeAgentApp/AppModel+SkillsIntegrations.swift)
and [ConfigProviderDoctorModels.swift](../Sources/NativeAgentApp/Models/ConfigProviderDoctorModels.swift)
own the Mac reader and decoded fields.
