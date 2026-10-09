# P11 Senses integration — 2026-10-05

Branch: `wA/senses-int`. Work stayed in this worktree. No NativeAgent launch, quit, installation, bridge call, automated tests, commit or push occurred. The pre-existing `Package.resolved` change was preserved. `docs/HANDOFF_CURRENT.md` is unchanged; its present revision contains no Senses/P3/P5 integration section. The external Agent handoff was not written because it is outside the authorized worktree and sandbox.

## Joined seams

- Assembly now constructs the real helper locator/profile, registry, gated source, ledger and growth lane; installs the exact memory owner; registers native and bundled JS senses; awaits registration before the canonical loop manifest starts. The existing launch and quit hooks call install/shutdown. All integration stubs and the second act dispatcher are gone.
- Runner/helper now use the documented source-code, entry IDs, increasing callIDs, reply fields, state acknowledgements, publish/notify/log/done/failed messages, 24 MiB line limit and 16 MiB base64 material. File bytes become the SDK's Uint8Array; directory documents become bounded, stored ZIP material in memory. Notebook transactions share one serialized owner.
- Helper/native acts use only the requesting turn's SenseActionContext.perform. Reads, growth, change delivery and Work events have no action callback. Private action prefixes, executable indirection and private paths are refused in this one door path; source bytes and growth capture share the sandbox's path exclusions.
- Door/source joins preserve initial native raw payloads, with provenance outside their representation; exact senses precede generic native readers. mac.read retains document routing. Acts re-read under current Trust, use fresh browser/document material, accept package descriptors and invalidate material after actions.
- Successful actual read versions increment once. Shared verbs remain disabled until local use; act outcomes do not unlock them. Served pages stamp turn provenance. wrong:true records the wall, correction and exact cached served-version warning, then queues repair. Rollback marks the withdrawn version.
- Registry switches and growth publication are atomic at its locked owner. Built-ins can be switched off and remain off after restart. CapabilityLifecycle archive joins existing skills/tools upkeep. Sharing is a native Senses page button; only that explicit User action passes userApproved:true.
- Growth obtains the hub's real owners and frozen safe samples, resolves handled ledger revisions, receives canonical quiet opportunities and schedules already-due pending work after gate release. It rejects embedded 32-character/six-word sample runs before running or retaining grown JS; reusable examples require a checked digest. The authoring kit loads only starter/SDK/builders and the relevant bundled example, within its cap.
- NativePage text has lossless UTF-8 windows and more cursors preserving reader arguments/revision. Rendering no longer silently clips away content or continuation addresses. P7's frame and all ten bundled readers accept initial plain file paths.
- ContextFlow already registers SensesContextProjection; assembly explicitly binds the canonical memory sink. Proposal staging/acceptance and content rewrites now preserve sense provenance. Wrong-version index updates re-read surviving canonical rows and enqueue projection changes before suspension, preventing stale deleted rows from reappearing.
- sense.present(view/null) produces sealed Work views; event(request) receives their events for the exact enabled version, without act authority. Views/news from draft growth are suppressed; failed reads cannot present a view.
- The ledger's parent is protected from unlink/rename. Ledger existing-sense selection includes generic readers, and stuck work retains priority over repair.
- XcodeGen embeds NativeAgentSenseHost in Contents/MacOS and Resources/Senses intact. Both development and public signing owners already sign the helper with Config/NativeAgentSenseHost.entitlements (allow-jit). Installer now explicitly refuses missing executable/SDK/manifest before staging an installation.

## Seams not fully available

- Actual growth cost in USD is unavailable from the common provider response/telemetry API. growthCostUSD stays nil when no dollar receipt exists, and P10 displays its existing “not recorded” state. The budget now truthfully says “Daily growth budget (model calls)” and enforces P6's existing integer model-call limit. A dollar budget/cost receipt needs provider-owned accounting; no guessed dollar figures were added.
- Live file/package changes use the existing pooled FileChangeEvents stream, coalesced and delivered between plug entries under fresh background gates. App/site live watches return an explicit unsupported failure: existing AX/Chrome APIs do not expose a trustworthy content-change stream suitable for this adapter. On-call app/site reads and acts are joined.
- Installer/bundle layout and both signing paths were verified by source/generated-project readback, shell parsing and the install preflight. A signed installed artifact and running behavior were not verified because this task expressly forbids installation/launch/quit.

## Validation

- `xcodegen --spec project.yml`: passed.
- Exact `swift build --disable-keychain -j 6`: blocked by sandbox-denied default module cache. Cache redirection and disabling SwiftPM's nested sandbox reached CoreMLModelCompile, then hit `sandbox_apply: Operation not permitted`.
- Allowed workaround compiled and linked both NativeAgentApp and NativeAgentSenseHost:
  `CLANG_MODULE_CACHE_PATH=/private/tmp/p11-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/p11-swift-cache swift build --disable-keychain -j 6 --disable-sandbox --skip-update --disable-automatic-resolution --build-system native`.
  Final pass: `Build complete! (4.91s)`.
- Architecture blueprint: passed, 20 families / 990 Swift table rows.
- Timer inventory: passed, 261 sites / 175 ownership rules.
- `git diff --check`: passed.
- Shell syntax for installer, development signing and public release scripts: passed.

## Changed files

`Package.resolved` is pre-existing unrelated dirt. P11 changed the following files, plus this report:

- `Modules/NativeAgentCore/Sources/AppToolRuntime/AppToolExecutor+Senses.swift`
- `Modules/NativeAgentCore/Sources/AppToolRuntime/AppToolExecutor+SkillRun.swift`
- `Modules/NativeAgentCore/Sources/AppToolRuntime/ExistingCornersReaders.swift`
- `Modules/NativeAgentCore/Sources/ChatToolRuntime/SwiftToolDispatcher+Sandbox.swift`
- `Modules/NativeAgentCore/Sources/ChatToolRuntime/SwiftToolDispatcher+ToolImpls.swift`
- `Modules/NativeAgentCore/Sources/ChatTurnRuntime/ChatOrchestrationClient+StructuredChat.swift`
- `Modules/NativeAgentCore/Sources/ChatTurnRuntime/MacChatTurnLifecycleIntake.swift`
- `Modules/NativeAgentCore/Sources/MemoryV2/MemorySenseProvenance.swift`
- `Modules/NativeAgentCore/Sources/MemoryV2/MemoryStorage+Proposals.swift`
- `Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+Proposals.swift`
- `Modules/NativeAgentCore/Sources/MemoryV2/MemoryV2+Storage.swift`
- `Modules/NativeAgentCore/Sources/Senses/BuiltInSenses.swift`
- `Modules/NativeAgentCore/Sources/Senses/ExistingCornersSourceProvider.swift`
- `Modules/NativeAgentCore/Sources/Senses/FileSenseRegistry+Storage.swift`
- `Modules/NativeAgentCore/Sources/Senses/FileSenseRegistry.swift`
- `Modules/NativeAgentCore/Sources/Senses/FileWallLedger.swift`
- `Modules/NativeAgentCore/Sources/Senses/HelperSenseRunner.swift`
- `Modules/NativeAgentCore/Sources/Senses/SenseDoor.swift`
- `Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift`
- `Modules/NativeAgentCore/Sources/Senses/SensesContract.swift`
- `Modules/NativeAgentCore/Sources/ToolExecution/ToolExecution+RunSandbox.swift`
- `Resources/Senses/builtin/canvas-accessibility.js`
- `Resources/Senses/builtin/docx.js`
- `Resources/Senses/builtin/epub.js`
- `Resources/Senses/builtin/key.js`
- `Resources/Senses/builtin/numbers.js`
- `Resources/Senses/builtin/pages.js`
- `Resources/Senses/builtin/pptx.js`
- `Resources/Senses/builtin/rtf.js`
- `Resources/Senses/builtin/rtfd.js`
- `Resources/Senses/builtin/xlsx.js`
- `Resources/Senses/frame.js`
- `Resources/Senses/sense.js`
- `Sources/NativeAgentApp/AppDelegate+Launch.swift`
- `Sources/NativeAgentApp/BackgroundGrowthLane+Grow.swift`
- `Sources/NativeAgentApp/BackgroundGrowthLane.swift`
- `Sources/NativeAgentApp/SenseGrowthAuthoring.swift`
- `Sources/NativeAgentApp/SensesAssembly.swift`
- `Sources/NativeAgentApp/SensesView.swift`
- `Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift`
- `Sources/NativeAgentSenseHost/main.swift`
- `docs/ARCHITECTURE_BLUEPRINT.md`
- `docs/SENSES.md`
- `script/install_app.sh`

## Model-visible text, verbatim

No persona, system growth prompt or app tool-schema text changed. Native object replies add `sense_provenance`; native string replies append the existing SenseProvenance.line output. The following added/changed diagnostic and feedback source lines preserve their literal templates verbatim (including interpolations). Wire API code is shown separately.

### Modules/NativeAgentCore/Sources/AppToolRuntime/AppToolExecutor+Senses.swift

```swift
            guard let source = SensesHub.shared.source else { throw SenseFailure(code: "source_unavailable", message: "The source provider is unavailable.") }
        if refused { throw SenseFailure(code: "private_store", message: "A sense cannot reach private app stores, persona, memories, credentials, approvals or sense notebooks through an action.") }
        guard corner == self.corner else { throw SenseFailure(code: "source_unavailable", message: "That corner is outside this act.") }
```

### Modules/NativeAgentCore/Sources/AppToolRuntime/ExistingCornersReaders.swift

```swift
                    throw SenseFailure(code: "source_unavailable", message: "The original document reader refused this read under the current policy.")
                    throw SenseFailure(code: "source_unavailable", message: "Background growth needs an already-running app.")
                throw SenseFailure(code: "source_unavailable", message: "Background growth needs a concrete app, file or leased site.")
                        throw SenseFailure(code: "source_unavailable", message: "The file changed while its growth material was captured.")
                        throw SenseFailure(code: "source_unavailable", message: "The file changed while its independent view was read.")
            case .file: throw SenseFailure(code: "source_unavailable", message: "The file snapshot is unavailable.")
            throw SenseFailure(code: "source_unavailable", message: "Growth material cannot contain symbolic links.")
                throw SenseFailure(code: "source_unavailable", message: "The document package could not be captured.")
                guard paths.count < 8000 else { throw SenseFailure(code: "material_too_large", message: "The document package has too many members.") }
                guard values.isSymbolicLink != true else { throw SenseFailure(code: "source_unavailable", message: "Growth material cannot contain symbolic links.") }
            throw SenseFailure(code: "source_unavailable", message: "Growth material must be a regular file or document package.")
            guard size >= 0, size <= 16 * 1024 * 1024 - total else { throw SenseFailure(code: "material_too_large", message: "Growth file material exceeds 16 MiB.") }
            guard total <= 16 * 1024 * 1024 else { throw SenseFailure(code: "material_too_large", message: "Growth file material exceeds 16 MiB.") }
            throw SenseFailure(code: "source_unavailable", message: "The original reader refused this read.")
```

### Modules/NativeAgentCore/Sources/Senses/ExistingCornersSourceProvider.swift

```swift
            throw SenseFailure(code: "unsupported", message: "This corner has no event-backed source watch.")
                guard members <= 8000 else { throw SenseFailure(code: "material_too_large", message: "The document package has too many watched members.") }
            throw SenseFailure(code: "source_unavailable", message: "No safe background material is available for this corner.")
            throw SenseFailure(code: "invalid_address", message: "The native page cursor is invalid.")
            result.folded.append("Remaining raw view")
```

### Modules/NativeAgentCore/Sources/Senses/FileSenseRegistry.swift

```swift
                throw Self.failure("This sense changed. Refresh the page before switching it.")
```

### Modules/NativeAgentCore/Sources/Senses/HelperSenseRunner.swift

```swift
            return .failed(SenseFailure(code: "act_denied", message: "Sense actions require enabled verbs and an active app door.", provenance: provenance))
                return await complete(.failed(SenseFailure(code: "bad_output", message: "Sense page exceeds the text ceiling; fold it and offer more.")), record: record, request: request)
            throw SenseFailure(code: "view_unavailable", message: "Sense view is no longer enabled or its event is too large.")
                throw SenseFailure(code: "bad_entry", message: "Sense source must be UTF-8 and at most 512 KiB.")
                                    throw SenseFailure(code: "bad_output", message: "Sense API requires increasing callIDs and at most 256 calls.")
                                    throw SenseFailure(code: "bad_output", message: "Sense logs exceed 2 KiB or are malformed.")
                                    throw SenseFailure(code: "bad_output", message: "Sense read finished without a page.")
                            throw SenseFailure(code: "bad_output", message: "Sense helper sent a message outside its request.")
            throw SenseFailure(code: "bad_output", message: "Sense view requires title and at most 256 KiB of HTML.")
                    throw SenseFailure(code: "source_unavailable", message: "Sense file material must be a regular file or document package.")
        guard fd >= 0 else { throw SenseFailure(code: "source_unavailable", message: "Sense file material is unavailable.") }
            throw SenseFailure(code: "source_denied", message: "Sense file material must remain a regular file.")
            throw SenseFailure(code: "input_limit", message: "Sense file material exceeds 16 MiB.")
            throw SenseFailure(code: "source_unavailable", message: "Sense document package is unavailable.")
                throw SenseFailure(code: "source_denied", message: "Sense document packages cannot contain symbolic links.")
                throw SenseFailure(code: "source_denied", message: "Sense document package contains unsupported members.")
                throw SenseFailure(code: "input_limit", message: "Sense document package exceeds its member limit.")
            throw SenseFailure(code: "source_unavailable", message: "Sense document package could not be read completely.")
                throw SenseFailure(code: "source_denied", message: "Sense document package member changed while reading.")
                throw SenseFailure(code: "input_limit", message: "Sense document package exceeds 16 MiB of ZIP material.")
            throw SenseFailure(code: "bad_state", message: "Sense notebook cannot be a symbolic link.")
                throw SenseFailure(code: "bad_state", message: "Sense notebook is malformed or too large.")
                throw SenseFailure(code: "state_limit", message: "Sense notebook values must be at most 16 KiB.")
            guard data.count <= 65_536 else { throw SenseFailure(code: "state_limit", message: "Sense notebook exceeds 64 KiB.") }
        guard data.count <= 24 * 1_024 * 1_024 else { throw SenseFailure(code: "input_limit", message: "Sense material exceeds the helper input limit.") }
            if line.count > 24 * 1_024 * 1_024 { sink.yield(.ended("Sense helper exceeded its output line limit.")); stopLocked(); return }
        if buffered.count > 24 * 1_024 * 1_024 { sink.yield(.ended("Sense helper exceeded its output line limit.")); stopLocked() }
```

### Modules/NativeAgentCore/Sources/Senses/SenseDoor.swift

```swift
            throw SenseFailure(code: "unsupported", message: "This corner has no event-backed source watch.")
```

### Modules/NativeAgentCore/Sources/Senses/SenseSandboxProfile.swift

```swift
            throw SenseFailure(code: "source_denied", message: "Sense material cannot come from private app stores, persona or credentials.")
```

### Sources/NativeAgentApp/BackgroundGrowthLane+Grow.swift

```swift
                throw SenseFailure(code: "registry_unavailable", message: "Sense growth needs atomic registry publication.")
                    feedback = "Code embeds private input. Read the material at runtime; do not copy any 32-character run or six consecutive source words into code."
                        return .completed(result: "Sense is switched off.")
                    return .completed(result: "Grew \(id) v\(record.version) in \(round) round(s).")
```

### Sources/NativeAgentApp/SensesAssembly.swift

```swift
            throw SenseFailure(code: "source_unavailable", message: "Sense source has an unknown turn surface.")
```

### Sources/NativeAgentSenseHost/JavaScriptSenseRuntime.swift

```swift
                        throw failure("bad_output", "Sense view requires title and at most 256 KiB of HTML.")
```


Removed refusal/render strings:

```text
Built-in senses cannot be archived.
View clipped; read More or a thing's address for detail.
```

Additive SDK API, verbatim:

```javascript
        present: view => invoke("present", {view: view == null ? null : view}),
```

Surface text changes, verbatim:

```text
Share sense
Share sense…
I couldn't share this sense: \(error.localizedDescription)
Daily growth budget (model calls)
Enter 0 or a positive whole number. The budget has not changed.
0 means unlimited. Each background model call counts, including failed calls; immediate stuck work bypasses this limit.
```

