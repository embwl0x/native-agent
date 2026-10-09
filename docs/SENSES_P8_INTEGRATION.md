# P8 day-one adapters

P8 adds no launch hook. P2 owns launch assembly; P4 owns sense selection.
There are no temporary stubs and no shared-contract changes.

## Assembly

Import `Senses` and `AppToolRuntime`. Construct
`ExistingCornersSourceProvider(rawRead:)` with the existing gated raw tool
chain. The callback takes a tool name and its input and returns its unchanged
`JSONValue`. It must preserve the invocation's surface, verified session,
file-access task locals, and Trust checks. Its `raw:true` bypasses sense lookup
only; consume that flag before any underlying schema that does not accept it.
Do not route the callback back into a sense-served read or create another tool
dispatcher. Background source reads must use the same permission owners and
must not borrow a chat session.

Install the registry and this source in `SensesHub.shared` before calling
`try await BuiltInSenses.registerAll(dataRoot:)`. Registration is throwing:
missing/corrupt resources, identity collisions and changed version entries
must be surfaced by launch assembly. No readers run during registration.

## Selection and addresses

Specific registry lookups win. After an exact miss, use
`BuiltInSenses.fallbackCorner(for:)` and query the registry again. The five
native records are `builtin-screen` (`app:*`), `builtin-chrome` (`site:*`),
`builtin-files` (`file:*`), `builtin-document` (`stream:mac.read`), and
`builtin-connectors` (`stream:connectors`). An app/file/site wildcard is a
generic raw-reader record, not permission to broaden the requested corner.
When rendering a generic record's page, retain the original request's concrete
corner; the record identifies the generic reader while the page identifies
the app, file kind or site actually requested.

Pass the original read arguments as a JSON object in the request address.
Plain paths and bundle IDs are also accepted for files and apps. Preserve
`part`, `app`, `path`, `lease_id`, `offset`, `max_bytes`, and `version` rather
than rebuilding defaults. A plain site URL does not navigate or acquire a tab;
Chrome uses the existing lease, as its current snapshot route does.

The descriptor-only file source flag is task-local and explicitly carried
across the existing Full Mac connector Dispatch worker, alongside its image
sink. Ordinary reads keep that flag false and follow the unchanged branches.

For `mac.read`, select the document record (including explicit file paths),
or put `document:true` in a file-kind address. This preserves today's
MacDocumentRead route and redaction. Connector addresses are
`{"action":"<existing read action>","args":{<its existing arguments>}}`;
the adapter admits only registered read actions on connector pages. A nil
connector address reads today's connectors page. Native adapters offer no
new act/watch implementation; current app actions remain their action door.

`NativePage.text` is the raw string reply, or the same compact JSON rendering
the existing turn uses for object replies. No new truncation is introduced:
the existing reader limits and tool-result spill pager remain authoritative.
The file window's unchanged `next` arguments also populate `NativePage.more`.
Existing structured screen controls and the Chrome mirror's rows become
things when present; otherwise the source itself is a named thing.

## P7 manifest

`Resources/Senses/builtin.json` may be an array or an object with a `senses`
array. Each row has `corner` (a key such as `file:docx`, or contract Codable),
`entry` (a relative `.js` path), and optional `id`, `version`, `verbs`.
Missing ID becomes `builtin-` plus the corner key with colons changed to
hyphens; version defaults to 1. Records are built-in JavaScript, on-call,
without extra reach. The kit is copied into `<dataRoot>/senses/<id>/v<N>/`
before upsert, including shared JS resources. Saved status, counters and
later repaired versions survive registration. Installed apps resolve only
`Contents/Resources/Senses`; development executables use this checkout's kit.
P7 resources are absent from the P8 worktree and must be merged before launch.

## Bounded installed check (integration owner)

1. Launch the integrated installed revision once. Confirm all five native
   records in Senses and P7's manifest records, with the corresponding version
   entry files present. Confirm there is no resource/registration error.
2. Through the existing app door, read one already-running app with `mac.look`,
   one small approved text file with `files.read`, the same text file with
   `mac.read`, one already-leased Chrome page, and one configured connector's
   existing read action. For each, compare the native page's text with the same
   request using `raw:true`; the payload must match, with sense provenance
   outside it. Do not navigate, launch another app, or send a connector write.
3. On one existing long approved file, continue once using the returned `next`
   arguments / `more` address and confirm offset and version are retained.
4. Turn off one built-in, restart only when the integration owner is authorized
   to do so, and confirm its saved status and usage counters are not reset.
   Restore the original setting. Confirm an exact P7 file-kind record wins
   over the generic file wrapper.

P8 itself never installs, launches, quits, or contacts Agent.

## Worker validation

`xcodegen --spec project.yml`, the architecture blueprint check, the timer
inventory check (256 sites, unchanged), and `git diff --check` passed.
The default `swift build --disable-keychain -j 6` was blocked by writable-cache
and nested-sandbox restrictions. Temporary module caches plus
`--disable-sandbox --force-resolved-versions` let the default build compile
Senses, but its CoreML resource compiler hit the same sandbox
denial. No production build configuration was changed for that restriction.

The complete app built and linked successfully, then the final incremental
build passed with:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/nativeagent-p8-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/nativeagent-p8-swift-cache \
swift build --build-system native --disable-sandbox --force-resolved-versions --disable-keychain -j 6
```

The temporary SwiftPM workspace state was adjusted to use this worktree's
copied Sparkle artifact, replacing its stale absolute cache path. No separate
tests, test targets, harnesses, bridge calls or installed checks were run.
The global Agent handoff is outside this worker's authorized write boundary;
this document is the integration handoff.

Git staging was denied while creating the shared worktree `index.lock`.
No files were staged, committed or pushed; the eight P8 files remain in-tree.
