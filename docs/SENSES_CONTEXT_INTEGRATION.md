# P9: context and memory provenance

The projection is registered in `NativeContextFlowRuntime`. `SenseNewsBoard.post`
dispatches the `sense-news` invalidation after adding news, retaining its existing
method signature. The projection indexes
at most 12 latest items, 512 UTF-8 bytes per item, and 8,192 UTF-8 bytes total.
News stays selectable, private and tagged with the exact sense id and version.

MemoryV2 commits retain `sense_versions` in metadata as objects with `sense_id`
and `version`. Duplicate admission unions the references. A wrong-version marker
is durable in `memory_wrong_sense_versions` in the same memory.sqlite; existing
rows receive `sense_version_later_wrong: true`. Metadata rewrites preserve the
references and existing warning. SQLite insertion/update triggers
also flag later commits referencing a version already marked wrong. This does
not modify the remembered text, lifecycle, confidence or status, and deletes
nothing. Reads and compiled memory context show the warning, as does User's
Memories page. Turn provenance is isolated across turns, shared by parallel tool
calls and bounded to 128 versions; an overflow refuses a commit explicitly.

## Integration calls for the other packages

P4 must call this only after deciding to return a sense-served page, before its
tool reply returns. Do not call it for raw reads, candidates, failed reads, or
background material acquisition:

```swift
SensesHub.shared.didServe(provenance)
```

P4, on `wrong:true`, must report the exact version of the rejected view; P3, on
rollback, must report the version being withdrawn (not the restored version):

```swift
try await SensesHub.shared.markVersionWrong(senseID: record.id, version: record.version)
```

These calls belong in those owners, which are being implemented separately.
There is no runner-side capture: a candidate page that was never served cannot
become memory provenance. A wall's corner alone cannot identify an old rejected
view, so `wall` deliberately does not guess a version. Report a failed flag write
in the owning operation; do not hide it or claim the memories were flagged.
MemoryV2's production backing-store factory installs the sink automatically.
An assembly using an alternate data root must install that root's exact
`MemoryStorage` with `SensesHub.shared.installMemoryProvenanceSink(storage)`.

## Small installed check, after integrating the calls above

1. Have a live sense publish one real change. Confirm that the next relevant
   turn can reach its news with `[sense <id> v<version>]`; unrelated turns should
   not gain an unconditional news block. Inspect the compiled provider's items
   for the documented item and byte bounds if checking a large real summary.
2. In one turn, read a real page through that sense and commit one fact from it.
   Read the saved memory by id and confirm `sense_versions` includes the served
   id and version. Commit the same fact in a turn with another served version;
   confirm the surviving duplicate row retains both references.
3. Mark the original view wrong using the door's `wrong:true` path. Confirm the
   memory still exists with its original text, and exact-id recall, search and
   User's Memories page show `from a sense version later found wrong`. Pin or
   unpin that memory once and confirm the warning survives the metadata update.
4. Roll back a different known version through User's Senses page. Confirm only
   memories referencing the withdrawn version receive the warning. A memory
   based solely on the restored version must stay unflagged.
5. After an ordinary subsequent app restart, read the flagged memory again.
   Confirm the warning persists. In a fresh turn with no sense read, commit a
   different fact and confirm it does not inherit the previous turn's versions.

P9 does not install, launch, quit, call the bridge, or create/run tests. This
check is for the integrator after the full app is installed.

## Worker validation (2026-10-05)

XcodeGen, architecture blueprint, timer inventory and `git diff --check` passed.
No timers/sleeps were added. The requested default-engine `swift build
--disable-keychain -j 6` is blocked by the outer sandbox: first its default
module-cache path, then nested `sandbox-exec`, ultimately CoreML resource
compilation. No source changes were made to bypass CoreML.

The same complete `NativeAgentApp` product built and linked successfully with
the native SwiftPM engine (406.30 seconds; final additive-contract rebuild
24.88 seconds), using cached pinned dependencies:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/nativeagent-p9-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/nativeagent-p9-module-cache \
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=submodule.SQLiteCustom/src.update \
GIT_CONFIG_VALUE_0=none \
swift build --build-system native --disable-sandbox --disable-keychain \
  --skip-update --only-use-versions-from-resolved-file -j 6
```

The Git override skips GRDB's unused optional custom-SQLite submodule; the
package uses its normal system-SQLite target. Four missing repository mirrors
were copied from the existing local SwiftPM cache into this worktree's ignored
`.build/repositories` so no network fetch was needed. The default engine still
needs a build outside this restricted worker sandbox; the installed behavior
has not been checked by P9.
