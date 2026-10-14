# NativeAgent Skill Manifest Spec

Skills are JavaScript routines behind the existing app door. A matching routine
arrives through recall or discovery; its description and signature lead to
`skill.run`. No skill grants authority or adds an always-on tool schema.

## Authoring and review

| Action | Contract |
|---|---|
| `skill.list` | Descriptions, signatures, status, runnable state and run calls. |
| `skill.read` | Metadata by default: digest, admission, selected version and retained versions. `source:true` reads exact code and fixtures for authoring/review; `step` selects a labelled code step. |
| `skill.save` | Stable name, one-line description and script. Optional triggers, fixtures, converts and restrictive overrides:built_in metadata. Stages a candidate; a pending revision leaves the working version selected. |
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
Source is limited to 8,192 bytes; steps and dependencies to 50 each.
Tools and skills are sync-only: define function run(input), use synchronous
host/app calls and return plain JSON. Async functions and Promises are refused.
Ad hoc app scripts keep their function-body contract on the same JS executor.

Omitted fixtures record one bounded validation with supplied input (default {}).
Every app call, including reads and decisions, gets a visible placeholder. Only
tool host.files.list/count/read/info may read live through declared reach and
ordinary admission. The sealed capture is replayed on later validation.
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
