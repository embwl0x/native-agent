# Craft slice 2 worker handoff

## Reviewer fixes (2026-09-26)

The Finder runner now uses `lstat` on every bound path component and repeats
no-symlink and canonical-path guards in the shell before each move. macOS's
`stat` command already calls `lstat` by default; the missing ancestor guards
were the escape. Creation must succeed, return the exact requested folder path,
and supply a folder identity matching readback before any moves.
Unrecorded creation is never adopted on resume. Verified moves accumulate in
`verifiedFiles`, including across drift and resumed stop receipts.

Reminder correlation now uses only the returned EventKit identifier in the
local journal. A save whose identifier was not recorded stops for manual
inspection; matching visible fields cannot adopt it. Existing reminders are
not rewritten. The changed files are the craft runner, craft evidence/skill
owner, reminder binding, Mac PIM owner, architecture row, and this handoff.

Validation: app build, architecture inventory, timer inventory, and diff check.
No files were added or removed, so XcodeGen was not needed for these fixes.
The worker boundary still forbids installation and the global handoff write.
Post-install checks below remain pending. Finder's pathname checks and Apple
events are not an atomic filesystem transaction.

The exact reminder export text and diagnostics below reflect these fixes.
Removed diagnostic: `Craft journal has no reminder identity.`

## Original slice

Extends the existing procedural lane, `CraftMethod`, journal, gated runner,
lazy skill readers, and relevant one-line hint. TextEdit's existing candidate
filename and default invocation remain compatible. New candidates have separate
method filenames within the same per-agent craft directory.

Changed files:

- `SwiftToolDispatcher+Craft.swift`: dispatch the selected family with fresh owner observations and durable partial progress.
- `MemoryV2+Craft.swift`: add typed methods, per-method candidates, hints, safe exports, and durable journal writes.
- `SwiftToolDispatcher+SkillTools.swift`: expose all verified candidates through existing skill readers.
- `BuiltInToolSchemaFactory+CoreSchemas.swift`: extend `craft_run` inputs in the existing schema pattern.
- `SwiftToolDispatcher+MacIntegration.swift`: refuse integration sub-approvals during craft.
- `FileReadEvidence.swift`: scope exact directory-entry evidence to the current read.
- `FileSystemActions.swift`: supply local, same-volume, no-follow filesystem evidence after normal read authorization.
- `ReminderCraftBinding.swift`: carry current object bindings to the existing Reminders owner.
- `MacPIMConnectorActions.swift`: resolve, create, and read back exact reminders without requesting new OS authority.
- `ARCHITECTURE_BLUEPRINT.md`: document the extended owners.
- `README.md` in `docs/`: index this handoff.
- `craft-slice-2-worker.md`: preserve exact changed text, installed proof steps, and limits.

Worker validation passed: `swift build --disable-keychain -j 6
--only-use-versions-from-resolved-file`, `xcodegen --spec project.yml`,
`swift script/check_architecture_blueprint.swift`,
`swift script/check_timer_inventory.swift`, and `git diff --check`.
No separate tests, live bridge calls, installation, or app launch were performed.
The global Agent handoff is outside this worker's allowed write boundary;
the integrator should carry this report into that handoff after installed proof.

Finder performs named AppleScript operations through the permission-checked
`shell` tool. Every observation uses permission-checked `list_dir` with scoped
filesystem evidence: no-follow directory descriptors, a local volume, same-device
regular files, inode identity, size, and modification time. Creation and each
move are journalled durably before dispatch. Every subsequent move rechecks the
whole binding. No overwrite is requested. A resumed run may continue only moves
that were never issued; it never recreates an uncertain folder or repeats an
uncertain move. Completed bindings are receipts, not permission to reapply.

Reminders uses the existing read/create tools and EventKit owner. Scoped reads
resolve an exact, unique writable list and read beyond the ordinary today-only
filter. Creation rechecks that list and absence before saving. The journal
retains the returned item identifier before readback; the reminder's visible
fields contain only the requested title and due date. Readback
checks list identity, recorded item identity, exact title, due
instant, and incomplete state. Missing, duplicate, or changed evidence stops.

No learned authority is stored. Every sub-call enters the outer dispatcher;
deferred tool and integration approvals are refused. Reminders and Finder OS
access must already be granted. Export comes only from the enum-only method and
fixed prose, never the local bindings, evidence, or input values.

## Proof after integration and installation

These are bounded checks in the installed app, not an automated suite. The
worker must not install, launch, stop, or contact the live app.

1. In Finder, prepare an empty local scratch directory under an authorized root
   (use its actual absolute path for `SCRATCH_A`), containing `alpha.txt` and
   `beta.txt`. In a current authorized chat call:
   `craft_run {"method":"craft.finder.folder-move.v1","source_directory":"SCRATCH_A","folder_name":"Sorted","file_names":["alpha.txt","beta.txt"],"learn":true}`.
   Expect `verified`, both names in `verified_files`, both original files inside
   `Sorted`, and neither at the source. Inspect Finder and the file system.
2. Prepare a second scratch directory with a different filename; invoke the same
   method with new inputs and omit `learn`. Expect one-call verification. Repeat
   those identical inputs once: expect verification without another move. Move
   that synthetic destination file elsewhere manually and replay: expect
   `stopped`, no recreation and no move, with every previously verified filename
   still in `verified_files` and the journal's `verifiedFiles`.
   In a fresh scratch directory, use an existing destination folder, then a
   symlink as the source directory or named file: each call must stop without
   moving anything. If a folder appears during creation, expect a stopped
   receipt and no moves; do not run a race/load campaign to manufacture it.
3. In a uniquely named writable scratch Reminders list, call:
   `craft_run {"method":"craft.reminders.add-due.v1","list_name":"Craft Scratch","title":"Synthetic craft A","due_date":"2026-10-01T17:00:00Z","learn":true}`.
   Expect `verified` only after Reminders readback. In Reminders, confirm the title,
   exact list, due instant in the local timezone, incomplete state, and an empty
   URL field. Confirm the local journal records the returned `reminder_id`.
4. Use a different synthetic title and due instant, omit `learn`, and expect
   verification. Replay those identical inputs once and confirm only one item
   exists. Change that item's due date manually and replay: expect `stopped`
   without creating another reminder or restoring the old date.
5. For an uncertain effect encountered during an ordinary cancellation or denied
   sub-call, retain its exact original inputs. Replay once. A landed effect with
   a recorded owner identity may verify; an unverified issued effect must stop. Finder's
   `issued_files` and `verified_files` distinguish attempted moves from proven
   destinations. Do not fabricate journals, repeatedly interrupt runs, or run a
   workload campaign to manufacture this case.
6. `list_skills`, then `read_skill` for each new method. The `method` string must
   contain only parameterized vocabulary and fixed prose. Private evidence
   references remain outside that export. A relevant Finder/folder/move request
   or add/create reminder with due request should receive one short hint after
   its candidate exists. The second distinct verified input changes confidence
   to `verified with different inputs`.
7. On an ordinary invocation where a sub-action lacks current authority, expect
   `stopped` and no deferred sub-action approval. Existing files/reminders must
   not be changed. No permission revocation on the live agent is required merely
   to manufacture this check.

The caller must inspect uncertain effects before deciding any manual recovery.
These methods intentionally do not roll back partial progress. Finder bindings
use filesystem identity and metadata, not a byte-content hash. Finder is an
external process: guards and verification bound the operation but do not lock
out arbitrary concurrent filesystem writers. Reminders sync may change an item
identifier; that drift stops a completed binding rather than rebinding it.

## Model-visible text changes, verbatim

`craft_run` description:

```text
Run a supported TextEdit, Finder, or Reminders method. Checks the owning system; stops on drift and reports partial progress without repeating uncertain effects. Uses current authority. First use of each method needs learn:true; a candidate is saved only after verification.
```

New parameter descriptions (`method`, `source_directory`, `folder_name`,
`file_names`, `list_name`, `title`, `due_date`, in order):

```text
craft.textedit.replace-save.v1 (default), craft.finder.folder-move.v1, or craft.reminders.add-due.v1.
Finder: absolute local source directory; no symlinks.
Finder: new child folder name; must not already exist.
Finder: 1–16 distinct regular file names in source_directory; no paths or symlinks.
Reminders: exact, unambiguous writable list name.
Reminders: nonempty title.
Reminders: ISO-8601 timestamp with explicit timezone and whole seconds.
```

The schema's unconditional required list becomes empty; the runner validates
the selected family's fields. Existing field descriptions remain unchanged.

New hint lines (the interpolated confidence is exactly one of the two lines
following them; the existing TextEdit hint renders identically):

```text
Craft: craft.finder.folder-move.v1 — new local folder, 1–16 named regular files; \(confidence). read_skill for limits; craft_run if it fits.
Craft: craft.reminders.add-due.v1 — exact list and explicit due timestamp; \(confidence). read_skill for limits; craft_run if it fits.
one verified input; transfer unproven
verified with different inputs
```

New skill summaries and export prose:

```text
Make a new folder in a local source directory with Finder and move 1–16 named regular files into it. Requires current shell and file-read authority plus Finder automation access; no symlinks, overwrites, or cross-volume moves.
Add one reminder to an exactly named writable list with an explicit ISO-8601 due timestamp. Requires current Reminders read and write authority; ambiguous lists and existing matching reminders stop the run.
Inspect the owning system after every uncertain effect. Never automatically repeat an issued effect; stop on drift, denial, or unavailable evidence.
Journal folder creation and each file move before issuing them. Verify original file identities at destination and absence at source; continue only untouched moves.
Journal creation before saving and retain the returned reminder identifier locally. Read back the exact list, title, due timestamp, and incomplete state through Reminders; a receipt alone cannot verify creation.
```

New or generalized runner/owner diagnostics and success reasons (runtime values
remain interpolated; the existing TextEdit diagnostics are unchanged):

```text
Unsupported craft method.
No verified method yet. Use learn:true to try this supported route.
Another craft call is running. No action was performed.
Supply an exact list, a nonempty title, and an ISO-8601 due timestamp with timezone and whole seconds.
The exact reminder could not be read with current authority.
A matching reminder already exists or its list changed. Nothing was created.
Reminder creation is not verified. Inspect it manually; it will not be repeated.
The exact reminder, list, and due timestamp were read back; candidate retained locally.
Use an absolute local directory, a new child folder name, and 1–16 regular file names.
Use file names without paths or control characters.
File and folder names must be distinct.
Exact filesystem evidence is unavailable; paths must be local and contain no symlinks.
Incomplete filesystem evidence.
A bound path changed or contains a symlink.
A bound path cannot be resolved.
A bound path changed or escaped the allowed directory.
New folder creation failed or drifted. An existing folder will not be adopted.
Craft requires existing Finder automation access; no permission prompt was opened.
Finder craft requires macOS.
The destination already exists. Nothing was moved.
A named source is missing or is not a regular file.
Folder creation is unverified or the source changed. Creation will not be repeated.
The destination folder changed or its creation was not recorded.
A bound directory changed.
Missing original file evidence.
A named file changed, disappeared, or collided with its destination.
An issued move is not verified. Inspect it manually; it will not be repeated.
The move is not verified. Inspect it manually; it will not be repeated.
Not all files were verified at destination.
Every original file exists in the new folder and is absent from source; candidate retained locally.
Craft stopped because current integration authority is missing. No sub-action approval was filed.
Invalid craft file names
Local directory evidence unavailable
Entry evidence unavailable
Craft supports regular files and directories without symlinks
Directory evidence unavailable: \(error)
Craft file evidence requires macOS
The exact writable reminder list is missing, ambiguous, or changed.
Reminders readback is unavailable.
```

The enum-only export adds the two intents, their typed inputs, steps,
preconditions, owner checks, and reasons in `MemoryV2+Craft.swift`. Runtime
receipts add `verified_files`/`issued_files` for Finder and `reminder` state for
Reminders, using the same `verified`/`stopped` envelope and local evidence refs.
No always-on tool list or unrelated prompt text changed.
