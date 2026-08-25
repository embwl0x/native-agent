import Foundation
import Testing
@testable import ActivityWatch

// MARK: - What this file guards, and what changed
//
// v0's guarantee was COMPILE-TIME: the root Package.swift never named
// ActivityWatch, so a release build could not contain capture code at all. That
// assertion is FALSE BY DESIGN as of W7/W8 — the app links the module, because
// the feature ships. Deleting the guard would have been the wrong move (the
// properties it protected are still the ones that matter), so it is REPLACED,
// guard for guard, by the runtime equivalents:
//
//   a. capture cannot run with the toggle off  <- was: the app cannot link it
//   b. no path into context assembly / memory promotion            (KEPT + strengthened)
//   c. no CGWindowList / ScreenCaptureKit anywhere                 (KEPT)
//   d. the span table's only title-ish column is `title_redacted`  (KEPT)
//   e. the store is excluded from sync, backup, and export         (NEW)
//
// Every guard below was mutation-tested: the violation was reintroduced, the
// test was observed failing, and the violation was reverted. A guard nobody has
// watched go red is a guard nobody knows works.

/// Walks up from this source file to the repository root (the directory holding
/// the root `Package.swift` next to `Modules/`).
private func repositoryRoot() -> URL? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<12 {
        let manifest = directory.appendingPathComponent("Package.swift")
        let modules = directory.appendingPathComponent("Modules", isDirectory: true)
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: modules.path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { return nil }
        directory = parent
    }
    return nil
}

/// Strips `//` line comments and `/* */` block comments.
///
/// The guards below scan CODE, not prose. Without this, a comment that names a
/// forbidden API in order to say "never use this" trips its own guard — and the
/// fix someone reaches for is deleting the warning, which is precisely backwards.
private func strippingComments(_ source: String) -> String {
    var out = ""
    var index = source.startIndex
    var inBlock = false
    while index < source.endIndex {
        let rest = source[index...]
        if inBlock {
            if rest.hasPrefix("*/") {
                inBlock = false
                index = source.index(index, offsetBy: 2)
            } else {
                index = source.index(after: index)
            }
            continue
        }
        if rest.hasPrefix("/*") {
            inBlock = true
            index = source.index(index, offsetBy: 2)
            continue
        }
        if rest.hasPrefix("//") {
            while index < source.endIndex, source[index] != "\n" {
                index = source.index(after: index)
            }
            continue
        }
        out.append(source[index])
        index = source.index(after: index)
    }
    return out
}

/// Every `.swift` file in the watcher module and its CLI, as (path, code with
/// comments removed).
private func activityWatchSources() throws -> [(path: String, source: String)] {
    let root = try #require(repositoryRoot())
    let directories = [
        root.appendingPathComponent("Modules/NativeAgentCore/Sources/ActivityWatch"),
        root.appendingPathComponent("Modules/NativeAgentCore/Sources/ActivityProbeCLI"),
    ]
    var out: [(String, String)] = []
    for directory in directories {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        for file in contents where file.pathExtension == "swift" {
            let raw = try String(contentsOf: file, encoding: .utf8)
            out.append((file.lastPathComponent, strippingComments(raw)))
        }
    }
    #expect(out.count >= 5, "found only \(out.count) sources — did the guard lose its target?")
    return out
}

/// Every `.swift` file under one of the repo's source trees, recursively.
private func sources(under relativePath: String) throws -> [(path: String, source: String)] {
    let root = try #require(repositoryRoot())
    let directory = root.appendingPathComponent(relativePath)
    guard let walker = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil
    ) else { return [] }
    var out: [(String, String)] = []
    for case let file as URL in walker where file.pathExtension == "swift" {
        let raw = try String(contentsOf: file, encoding: .utf8)
        out.append((file.lastPathComponent, strippingComments(raw)))
    }
    return out
}

// MARK: - (a) THE RUNTIME FENCE: capture cannot run with the toggle off
//
// The replacement for the deleted compile-time guard, and the most important
// test in this file. Driven through the ENGINE and the SIMULATOR — the exact
// code path the live watcher drives — so it runs headlessly with no window
// server, no AX grant, and no human at the keyboard.

/// A script that unambiguously WOULD produce spans: three app switches, focus
/// events, a title change, and a clean close.
private func busyScript(policy: ActivityPolicy) -> ActivityScript {
    ActivityScript(
        version: 1,
        policy: policy,
        events: [
            .activate(bundleId: "com.example.editor", appName: "Editor", at: 1_000),
            .focusEvent(at: 1_010),
            .titleChange(raw: "notes.md — Editor", at: 1_020),
            .focusEvent(at: 1_050),
            .activate(bundleId: "com.example.browser", appName: "Browser", at: 1_100),
            .focusEvent(at: 1_150),
            .activate(bundleId: "com.example.editor", appName: "Editor", at: 1_200),
            .terminate(at: 1_300),
        ],
        tzOffsetMin: 0,
        deterministicIDs: true
    )
}

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityWatchArch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("RUNTIME FENCE: capture disabled produces no spans, through the real engine")
func captureDisabledProducesNoSpans() async throws {
    let root = try temporaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)

    // captureEnabled defaults to FALSE. This is the shipped default, not a
    // test-only construction: `ActivityPolicy()` is what a fresh install gets.
    let spans = try await ActivitySimulator.replay(
        busyScript(policy: ActivityPolicy()), into: store
    )

    #expect(
        spans.isEmpty,
        Comment(rawValue: """
        CAPTURE RAN WITH THE TOGGLE OFF. \(spans.count) span(s) were written from a script \
        driven under `ActivityPolicy(captureEnabled: false)`.

        This is the guarantee that replaced the v0 compile-time fence: the app links this \
        module now, so "it cannot exist in the build" is gone and "it cannot run without \
        explicit consent" is all that is left. Rows written here mean a fresh install \
        records the user before they have agreed to anything.
        """)
    )
}

@Test("POSITIVE CONTROL: the same script DOES produce spans once capture is on")
func captureEnabledProducesSpans() async throws {
    // Without this, the test above passes just as well against a broken script,
    // a broken simulator, or a store that silently swallows writes — and would
    // keep passing after someone deleted the fence it exists to protect.
    let root = try temporaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let spans = try await ActivitySimulator.replay(
        busyScript(policy: ActivityPolicy(captureEnabled: true, captureTitles: true)),
        into: store
    )
    #expect(
        !spans.isEmpty,
        "the script produced no spans even with capture ON — the negative test above is vacuous"
    )
}

@Test("RUNTIME FENCE: the engine refuses to open a span while the toggle is off")
func engineRefusesToOpenWhileDisabled() {
    var engine = ActivitySpanEngine(policy: ActivityPolicy())
    let commands = engine.process([
        .activate(bundleId: "com.example.editor", appName: "Editor", at: 1_000),
        .focusEvent(at: 1_010),
        .titleChange(raw: "anything at all", at: 1_020),
    ])
    let opens = commands.filter { if case .open = $0 { return true } else { return false } }
    #expect(opens.isEmpty, "engine emitted \(opens.count) open command(s) with capture disabled")
    #expect(engine.openSpan == nil, "engine holds an open span with capture disabled")
}

@Test("RUNTIME FENCE: a policy flipped to false mid-flight closes the span immediately")
func policyFlipToDisabledClosesOpenSpanNow() {
    // "Instant pause" is a UI promise; this is the mechanism behind it. A close
    // that waited for the next tick, the next app switch, or a restart would
    // keep recording for up to a minute after the user said stop.
    var engine = ActivitySpanEngine(policy: ActivityPolicy(captureEnabled: true))
    _ = engine.process(.activate(bundleId: "com.example.editor", appName: "Editor", at: 1_000))
    #expect(engine.openSpan != nil, "precondition: a span should be open")

    var off = ActivityPolicy(captureEnabled: true)
    off.captureEnabled = false
    let commands = engine.updatePolicy(off, at: 1_050)

    let closes = commands.filter { if case .close = $0 { return true } else { return false } }
    #expect(closes.count == 1, "expected exactly one close, got \(commands)")
    #expect(engine.openSpan == nil, "span still open after capture was disabled")
}

#if canImport(AppKit)
@Test("RUNTIME FENCE: ActivityWatcher.start() installs nothing while the toggle is off")
func watcherInstallsNothingWhileDisabled() async throws {
    let root = try temporaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let watcher = ActivityWatcher(store: store, policy: ActivityPolicy())

    // Would hang if start() created a capture thread and then blocked on it;
    // it returns immediately BECAUSE it creates nothing.
    watcher.start()

    #expect(watcher.isCaptureEnabled == false)
    #expect(
        watcher.isCapturing == false,
        """
        ActivityWatcher installed its observers with the Trust Center toggle OFF. \
        start() must return having created no AX observer, no NSWorkspace observer, no lock \
        observer, no capture thread and no pump — there is no later `if` to catch this.
        """
    )

    // And nothing reached the database.
    let spans = try await store.querySpans(from: 0, to: .greatestFiniteMagnitude, limit: 100)
    #expect(spans.isEmpty, "spans were written by a watcher that should not have started")

    await watcher.stop()
}
#endif

// MARK: - (b) EGRESS: no path into context assembly, recall, or memory promotion
//
// KEPT and STRENGTHENED. The v0 version only checked that ActivityWatch imports
// nothing from the cognitive modules — necessary, but it was sufficient only
// while nothing linked ActivityWatch at all. Now that ChatOrchestration does,
// the arrow has to be checked in BOTH directions, and the inbound one has to be
// confined to a single file.

@Test("EGRESS: the watcher module cannot name context assembly, memory, or the dream cycle")
func noContextAssemblyImports() throws {
    let forbiddenImports = [
        "ChatOrchestration", "CognitiveSubstrate", "MemoryV2", "Context",
        "KnowledgeGraph", "DreamREMCycle",
    ]
    for (path, source) in try activityWatchSources() {
        for module in forbiddenImports {
            #expect(
                !source.contains("import \(module)"),
                Comment(rawValue: """
                CONTEXT-ASSEMBLY IMPORT IN \(path): "import \(module)".

                The ambient watcher must be unable to reach context assembly, recall, memory \
                promotion, or the dream cycle. An activity row is answerable ONLY when \
                explicitly asked for — never selected ambiently, never consolidated into \
                long-term memory.
                """)
            )
        }
    }
}

@Test("EGRESS: exactly ONE ChatOrchestration file may import ActivityWatch")
func onlyTheToolImplImportsActivityWatch() throws {
    // The inbound arrow. ChatOrchestration links ActivityWatch so `activity_query`
    // has an implementation; the module must be reachable from THAT and nothing
    // else. Context assembly lives in this same module, so "the tool can read it"
    // and "a turn can absorb it ambiently" are one import apart.
    let importers = try sources(under: "Modules/NativeAgentCore/Sources/ChatOrchestration")
        .filter { $0.source.contains("import ActivityWatch") }
        .map(\.path)
        .sorted()
    #expect(
        importers == ["SwiftToolDispatcher+Sandbox.swift"],
        Comment(rawValue: """
        ACTIVITYWATCH IMPORTERS IN ChatOrchestration: \(importers).

        Exactly one file may import it — the tool implementation. A second importer is how \
        activity data reaches a turn without anyone asking for it: the same module builds the \
        per-turn context, the recall lane, and the tool receipts.
        """)
    )
}

@Test("EGRESS: the cognitive modules cannot import ActivityWatch at all")
func cognitiveModulesCannotImportActivityWatch() throws {
    // Context selection, the substrate, memory promotion and the dream cycle
    // are the four places an activity row could become DURABLE context. None of
    // them may name the module — and none of them declares it as a package
    // dependency either, so this would not even link.
    for module in ["Context", "CognitiveSubstrate", "MemoryV2", "DreamREMCycle"] {
        let importers = try sources(under: "Modules/NativeAgentCore/Sources/\(module)")
            .filter { $0.source.contains("import ActivityWatch") }
            .map(\.path)
        #expect(
            importers.isEmpty,
            Comment(rawValue: """
            \(module) IMPORTS ActivityWatch (in \(importers)).

            The tool answer is allowed to enter the turn that asked for it. It is NOT allowed \
            to persist into the cognitive substrate, be re-read by Fluid Context on a later \
            turn, or be reachable by autonomous tool-planning without a user ask.
            """)
        )
    }
}

@Test("EGRESS: the tool result is not routed into memory promotion")
func toolResultIsNotPromotedIntoMemory() throws {
    // The complement of the import guards: a name check on the promotion side.
    // If `activity_query` is ever added to a promotion/consolidation allowlist,
    // the imports stay clean and the property still dies.
    for module in ["MemoryV2", "CognitiveSubstrate", "DreamREMCycle", "Context"] {
        for (path, source) in try sources(under: "Modules/NativeAgentCore/Sources/\(module)") {
            #expect(
                !source.contains("activity_query"),
                Comment(rawValue: """
                \(module)/\(path) NAMES `activity_query`.

                A tool answer that gets consolidated into long-term memory makes the whole \
                "explicitly asked for, never ambient" argument false six weeks later, quietly.
                """)
            )
        }
    }
}

// MARK: - (c) NO WINDOW-SERVER CAPTURE APIs (kept verbatim)

@Test("CONFORMANCE: the watcher never touches CGWindowList or ScreenCaptureKit")
func noWindowServerCaptureAPIs() throws {
    // The P0 spike found CGWindowList returns TRUE window titles while the
    // screen is locked — reading through macOS's own lock-time redaction, and
    // requiring the Screen Recording grant to do it. NativeAgent may already
    // hold that grant for `mac_view`, so this is a live footgun rather than a
    // theoretical one: the API is right there and it works better.
    let forbidden = [
        "CGWindowListCopyWindowInfo",
        "CGWindowListCreateImage",
        "CGWindowListCreateImageFromArray",
        "ScreenCaptureKit",
        "SCShareableContent",
        "SCStream",
    ]
    for (path, source) in try activityWatchSources() {
        for symbol in forbidden {
            #expect(
                !source.contains(symbol),
                Comment(rawValue: """
                WINDOW-SERVER CAPTURE API IN \(path): "\(symbol)".

                AX-only is the more privacy-preserving path and it is a
                REQUIREMENT, not a preference. CGWindowList reads titles macOS
                deliberately hid from AX while locked, and window names need the
                Screen Recording TCC grant — a second permission prompt this
                feature promised never to raise.
                """)
            )
        }
    }
}

@Test("CONFORMANCE: no AXValue is read, for any element role")
func noAXValueReads() throws {
    // Categorical, not role-conditional. A metadata-only organ has no business
    // reading a field's contents even from a field it believes is harmless.
    for (path, source) in try activityWatchSources() {
        for symbol in ["kAXValueAttribute", "kAXValueChangedNotification", "kAXSelectedTextAttribute"] {
            #expect(
                !source.contains(symbol),
                Comment(rawValue: """
                AX VALUE ACCESS IN \(path): "\(symbol)".

                No AXValue is stored or read anywhere, for any element role —
                that rule is categorical. kAXValueChangedNotification is also
                per-keystroke, which would make this a keylogger by subscription.
                """)
            )
        }
    }
}

@Test("CONFORMANCE: zero LLM calls in capture, rollup, or query")
func noInferenceInTheWatcher() throws {
    // Requirement 3 of User's approval. Deterministic only — the rollup tier
    // exists precisely so this survives contact with a day-scale question.
    let forbidden = [
        "ProviderRouting", "LLMClient", "anthropic", "openai",
        "chatCompletion", "generateText",
    ]
    for (path, source) in try activityWatchSources() {
        for symbol in forbidden {
            #expect(
                !source.lowercased().contains(symbol.lowercased()),
                Comment(rawValue: """
                INFERENCE REACHED \(path): "\(symbol)".

                Zero LLM calls in capture, rollup, or query. The approved
                fallback (a small local note-taker) is a SEPARATE, later,
                explicitly-approved decision — not something that arrives by a
                convenient import.
                """)
            )
        }
    }
}

// MARK: - (d) SCHEMA: one title-ish column, and it says it is redacted (kept)

@Test("CONFORMANCE: the span table's only title-ish column is title_redacted")
func schemaCarriesOnlyRedactedTitle() async throws {
    let root = try temporaryRoot()
    let store = try ActivitySpanStore(dataRoot: root)
    let columns = try await store.columnNames()

    let titleish = columns.filter { $0.lowercased().contains("title") }
    #expect(
        titleish == ["title_redacted"],
        Comment(rawValue: """
        SCHEMA GUARD FAILED: title-ish columns are \(titleish).

        Exactly one is permitted, and it must be named `title_redacted`. The
        name is load-bearing: it is what tells the next person writing an INSERT
        that the value has to come out of ActivityTitleRedaction.redact and not
        straight off kAXTitle.
        """)
    )
    #expect(columns.contains("title_redacted"))
}

@Test("CONFORMANCE: exactly one file reads kAXTitle")
func onlyOneTitleReadSite() throws {
    // Redaction at the source only works if there IS one source. Two AX title
    // reads means two chances to forget the redactor.
    let readers = try activityWatchSources()
        .filter { $0.source.contains("kAXTitleAttribute") }
        .map(\.path)
    #expect(
        readers == ["ActivityWatcher.swift"],
        Comment(rawValue: """
        TITLE READ SITES: \(readers).

        Exactly one file may read kAXTitle, and its result must go straight into
        the engine, which redacts before the string can reach a span. A second
        read site is a second place to bypass ActivityTitleRedaction.
        """)
    )
}

@Test("CONFORMANCE: the query result emits no title field other than title_redacted")
func queryResultCarriesOnlyRedactedTitle() throws {
    // The schema guard covers the disk. This covers the WIRE: the tool result is
    // the one place the data leaves the module, and a field named `title` there
    // would be a leak the schema test cannot see.
    let source = try activityWatchSources()
        .first { $0.path == "ActivityQuery.swift" }
        .map(\.source)
    let code = try #require(source, "ActivityQuery.swift not found")

    // Two booleans in `recording_limits` legitimately have "title" in their
    // NAME — `titles_recorded` and `browser_titles_recorded` — and carry no
    // title text at all; they are how the answer states what it could not
    // contain. They are allowlisted BY NAME rather than by a looser pattern, so
    // adding a third title-ish key is a deliberate act that fails this test
    // first.
    let permitted: Set<String> = ["title_redacted", "titles_recorded", "browser_titles_recorded"]
    let titleKeys = Set(
        code
            .components(separatedBy: "\"")
            .filter { $0.lowercased().contains("title") && !$0.contains(" ") }
    )
    let unexpected = titleKeys.subtracting(permitted)
    #expect(
        unexpected.isEmpty,
        Comment(rawValue: """
        THE QUERY ENCODER EMITS TITLE-ISH KEYS \(unexpected.sorted()).

        The tool result is the one place this data leaves the module. `title_redacted` is the \
        only key permitted to carry title TEXT, and its name is what tells the next reader the \
        value came out of ActivityTitleRedaction rather than straight off kAXTitle. A key \
        called `title` here would be a leak the schema guard cannot see, because the schema \
        guard only looks at the database.
        """)
    )
    #expect(titleKeys.contains("title_redacted"), "the encoder no longer emits title_redacted at all")
}

// MARK: - (e) NEW: the store is excluded from sync, backup, and export
//
// The repo has no declarative "local-only" manifest; what it has is a set of
// hand-maintained ALLOWLISTS of relative paths that get copied. So the guard
// reads those allowlists out of the app sources and asserts the watcher's
// directory is absent from every one of them.
//
// This test also documents a real defect it was written to catch: the v0 store
// lived at `<dataRoot>/activity/`, which is an EXISTING directory belonging to
// the app's event feed — a directory that is `exportable: true`, backed up, and
// shipped in support bundles. The watcher would have inherited all three egress
// paths by filename collision. It now lives at `<dataRoot>/activity_watch/`.

@Test("EGRESS: the activity store is in no backup, export, or support-bundle list")
func activityStoreIsExcludedFromSyncAndBackup() throws {
    let root = try #require(repositoryRoot())
    let backupOps = root
        .appendingPathComponent("Sources/NativeAgentApp/NativeClient+TrustBackupOps.swift")
    let code = strippingComments(try String(contentsOf: backupOps, encoding: .utf8))

    // The three copy-lists, extracted by name so the guard fails loudly if one
    // is renamed rather than silently passing over a list that no longer exists.
    for listName in [
        "backupRelativePaths",
        "productionExportRelativePaths",
        "supportBundleRelativePaths",
    ] {
        guard let range = code.range(of: "\(listName): [String] = [") else {
            Issue.record("copy-list `\(listName)` no longer exists — this guard is now blind")
            continue
        }
        let tail = code[range.upperBound...]
        guard let end = tail.range(of: "]") else {
            Issue.record("could not find the end of `\(listName)`")
            continue
        }
        let body = String(tail[..<end.lowerBound])
        #expect(
            !body.contains(ActivityWatchPaths.directoryName),
            Comment(rawValue: """
            `\(listName)` NAMES "\(ActivityWatchPaths.directoryName)".

            The activity store is local-only: no backup, no user export, no support bundle, \
            no iCloud snapshot. A support bundle is the worst of the three — it is the one a \
            user cheerfully emails to a stranger to get help.
            """)
        )
    }

    // And it is not the SAME directory as the app's exported activity feed —
    // the collision that would have re-opened all three paths at once.
    #expect(
        ActivityWatchPaths.directoryName != "activity",
        """
        The activity store shares `<dataRoot>/activity/` with the app's event feed, which is \
        declared exportable, is backed up, and ships in support bundles.
        """
    )
}

@Test("EGRESS: nothing in the iCloud/CloudKit sync surface names the activity store")
func activityStoreIsNotSynced() throws {
    // The sync engine copies an explicit snapshot allowlist into the ubiquity
    // container rather than mirroring the data root, so the assertion is a name
    // check across every file that builds that snapshot.
    let syncFiles = try sources(under: "Sources/NativeAgentApp")
        .filter { $0.path.hasPrefix("MacSyncEngine") || $0.path.hasPrefix("iCloudBridge") }
    #expect(!syncFiles.isEmpty, "found no sync sources — this guard is blind")
    for (path, source) in syncFiles {
        #expect(
            !source.contains(ActivityWatchPaths.directoryName),
            Comment(rawValue: """
            \(path) NAMES "\(ActivityWatchPaths.directoryName)".

            The activity store never leaves this Mac. It is never synced or exposed through a \
            remote surface. A separately consented bounded answer may be sent to the selected \
            chat provider, but syncing the store would bypass that per-use boundary.
            """)
        )
    }
}

@Test("EGRESS: the store lives under the data root, not the iCloud container")
func activityStoreLivesOutsideAnySyncedDirectory() throws {
    // Belt to the name checks' braces: wherever the data root is, the store is
    // inside it and nowhere else. If a future data root were itself relocated
    // into the ubiquity container, that is a decision someone has to make
    // explicitly — this at least pins that the watcher does not do it locally.
    let dataRoot = URL(fileURLWithPath: "/tmp/example-root")
    let dbPath = ActivityWatchPaths.databaseURL(dataRoot: dataRoot).path
    #expect(dbPath.hasPrefix(dataRoot.path + "/\(ActivityWatchPaths.directoryName)/"))
    #expect(!dbPath.contains("Mobile Documents"))
    #expect(!dbPath.contains("com~apple~CloudDocs"))
}

// MARK: - The Mac-local refusal's surface set cannot narrow

@Test("W7: every real dispatch surface in the app is refused unless explicitly local")
func everyRealSurfaceIsRefusedUnlessLocal() throws {
    // THIS REPLACES a guard that was blind (gpt-5.5 IMPORTANT, 2026-08-14).
    //
    // The old test compared the module's DENYLIST against TrustCenter's
    // denylist. Both omitted the app's own local HTTP bridges, so both agreed —
    // and the test passed green while `POST /claude/tool {name:
    // "activity_query"}` happily returned activity rows over HTTP. Two copies of
    // the same blind spot agreeing is not evidence of anything.
    //
    // The refusal is now an ALLOWLIST, so the meaningful assertion is the
    // inverse: scrape the surface names the app actually dispatches under, and
    // require that anything not explicitly local is refused. A new transport
    // added tomorrow fails this test until someone decides, deliberately,
    // whether it may read where the human has been.
    let root = try #require(repositoryRoot())
    var surfaces = Set<String>()
    for relative in [
        "Sources/NativeAgentApp/ClaudeBridge.swift",
        "Modules/NativeAgentCore/Sources/TrustCenter/ConversationSurfaceProfile.swift",
    ] {
        let url = root.appendingPathComponent(relative)
        guard let code = try? String(contentsOf: url, encoding: .utf8) else { continue }
        for line in strippingComments(code).components(separatedBy: .newlines) {
            guard line.contains("SurfaceName") || line.contains("remoteSurfaceIDs") else { continue }
            var rest = Substring(line)
            while let open = rest.range(of: "\""), let close = rest[open.upperBound...].range(of: "\"") {
                let literal = String(rest[open.upperBound..<close.lowerBound])
                if literal.contains("-") || literal.allSatisfy({ $0.isLetter }) {
                    surfaces.insert(literal.lowercased().replacingOccurrences(of: "_", with: "-"))
                }
                rest = rest[close.upperBound...]
            }
        }
    }
    #expect(surfaces.contains("claude-bridge"), "scrape found no bridge surfaces — guard is blind again")

    let answered = surfaces.filter { !ConversationSurfaceProfileShim($0).isRemote }
    let unexpected = answered.subtracting(ConversationSurfaceProfileShim.localSurfaceIDs)
    #expect(
        unexpected.isEmpty,
        Comment(rawValue: """
        SURFACES THAT WOULD ANSWER activity_query BUT ARE NOT DECLARED LOCAL: \(unexpected.sorted()).

        activity_query is Mac-local. Any surface that answers it must be an explicit, \
        deliberate entry in localSurfaceIDs — not an omission from a denylist.
        """)
    )
}

@Test("W7: the app's HTTP bridges are refused")
func httpBridgesAreRefused() throws {
    // The concrete regression. These are in-process on the same Mac, which is
    // exactly why they looked local and slipped through: the data still leaves
    // the app over a socket to whatever asked.
    for surface in ["claude-bridge", "codex-bridge", "telegram", "slack", "ios", "icloud"] {
        #expect(
            ConversationSurfaceProfileShim(surface).isRemote,
            Comment(rawValue: "surface '\(surface)' must be refused by activity_query")
        )
    }
    for surface in ["chat", "mac"] {
        #expect(!ConversationSurfaceProfileShim(surface).isRemote)
    }
}

// MARK: - Source-conformance guards for the surfaces only source can reach
//
// Ledger fence `core.activity`. Each of these covers a surface whose failure is
// invisible at runtime and whose only cheap witness is the source itself —
// exactly the technique already used above for `kAXTitle` and the title-field
// conformance. They live in this file so they reuse `repositoryRoot`,
// `strippingComments`, `activityWatchSources` and `sources(under:)` rather than
// standing up a second copy of a source scanner.

/// One named file's code, comments stripped.
private func watchSource(_ relativePath: String) throws -> String {
    let root = try #require(repositoryRoot())
    let url = root.appendingPathComponent(relativePath)
    let raw = try String(contentsOf: url, encoding: .utf8)
    return strippingComments(raw)
}

/// The body of `func <name>`, by brace matching from its opening `{`.
private func functionBody(_ source: String, named name: String) -> String? {
    guard let signature = source.range(of: "func \(name)(") else { return nil }
    guard let open = source[signature.upperBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = open
    while index < source.endIndex {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[source.index(after: open)..<index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

// MARK: activity.watcher.commandPump

@Test("PUMP: the command stream is UNBOUNDED — a dropped close leaks an open row")
func commandStreamIsUnbounded() throws {
    // The AsyncStream carrying open/touch/close into the store is deliberately
    // unbounded: these are span CONTROL commands arriving at human app-switch
    // rate, not a firehose. A future switch to `bufferingNewest` would DROP
    // silently — dropping a `.close` leaks an open row whose duration then grows
    // on the next reconcile, dropping an `.open` turns every later touch and
    // close into a no-op. Neither raises anything.
    let source = try watchSource(
        "Modules/NativeAgentCore/Sources/ActivityWatch/ActivityWatcher.swift"
    )
    let makeStream = try #require(
        source.range(of: "AsyncStream<ActivityStoreCommand>.makeStream("),
        "the command stream construction moved — this guard is now blind"
    )
    let tail = source[makeStream.upperBound...].prefix(200)
    #expect(
        tail.contains("bufferingPolicy: .unbounded"),
        Comment(rawValue: """
        THE COMMAND STREAM IS NO LONGER UNBOUNDED. A bounded buffering policy DROPS \
        commands with no error at all: a dropped `.close` leaks an open row, a dropped \
        `.open` makes every later command for that span a silent no-op, and the only \
        witness in either case is one stderr line.
        """)
    )
    for policy in ["bufferingNewest", "bufferingOldest"] {
        #expect(
            !source.contains(policy),
            Comment(rawValue: "ActivityWatcher names `\(policy)` — a dropping buffer policy")
        )
    }
}

// MARK: activity.watcher.axMessagingTimeoutGlobal

@Test("AX TIMEOUT: the process-global retune is set once, bounded, and only here")
func axMessagingTimeoutIsSetOnceAndBounded() throws {
    // A PROCESS-GLOBAL SIDE EFFECT ON A NEIGHBOURING ORGAN. Per AXUIElement.h,
    // passing the SYSTEM-WIDE element sets the messaging timeout for the WHOLE
    // PROCESS — so the capture thread retunes every AX call in NativeAgent,
    // MacControl's perception lane included, and only for users who turned
    // activity capture on. Remove it and the capture thread's AX reads become
    // unbounded, wedging its run loop; raise it and the same wedge arrives
    // slower. Neither is visible at runtime, so the presence, the bound and the
    // uniqueness are pinned here.
    let watcher = try watchSource(
        "Modules/NativeAgentCore/Sources/ActivityWatch/ActivityWatcher.swift"
    )
    #expect(
        watcher.contains("AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide()"),
        "the process-global AX messaging timeout is gone — the capture thread's reads are unbounded"
    )

    // Bounded, and bounded SMALL. An AX read on the capture thread blocks the
    // run loop for exactly this long.
    let call = try #require(
        watcher.range(of: "AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide()")
    )
    let arguments = String(watcher[call.upperBound...].prefix(40))
    let seconds = arguments
        .split(whereSeparator: { !$0.isNumber && $0 != "." })
        .compactMap { Double($0) }
        .first
    let bound = try #require(seconds, "could not read the timeout literal from \(arguments)")
    #expect(
        bound > 0 && bound <= 1.0,
        Comment(rawValue: """
        THE PROCESS-GLOBAL AX TIMEOUT IS \(bound) s. It applies to every AX call in the \
        app, not just this fence's, and it is the only thing bounding a capture-thread \
        read. Anything above a second is a run-loop stall the user experiences as the \
        whole app hitching.
        """)
    )

    // EXACTLY ONE organ may retune the process. A second system-wide call
    // anywhere means two subsystems silently fighting over a global.
    var systemWideCallers: [String] = []
    for tree in [
        "Modules/NativeAgentCore/Sources",
        "Sources/NativeAgentApp",
    ] {
        for file in try sources(under: tree)
        where file.source.contains("AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(") {
            systemWideCallers.append(file.path)
        }
    }
    #expect(
        systemWideCallers == ["ActivityWatcher.swift"],
        Comment(rawValue: """
        MORE THAN ONE SUBSYSTEM SETS THE PROCESS-GLOBAL AX TIMEOUT: \(systemWideCallers.sorted()). \
        Whichever runs last wins, for the whole app, and neither one can tell.
        """)
    )
}

// MARK: activity.watcher.nativeAgentBundleIDs

@Test("DEAD API: nativeAgentBundleIDs has no callers and is NOT the exclusion authority")
func nativeAgentBundleIDsIsNotTheExclusionAuthority() throws {
    // DEAD PUBLIC API THAT MISREPRESENTS ITS OWN NAME. It is documented as kept
    // for source compatibility and it returns `alwaysExcludedBundleIDs` MINUS
    // loginwindow — so the one obvious future use, "the set of ids we never
    // record", is wrong by exactly the lock signal. A caller who trusted it
    // would start recording loginwindow, which is the P0 case the whole lock
    // gate exists to prevent.
    #expect(
        ActivityWatcher.nativeAgentBundleIDs
            .contains(ActivityWatcher.loginWindowBundleID) == false,
        "the trap this guard describes is gone — re-read the surface before deleting the test"
    )
    #expect(
        ActivityPolicy.alwaysExcludedBundleIDs
            .contains(ActivityWatcher.loginWindowBundleID),
        "loginwindow left the NON-OVERRIDABLE exclusion set — a lock signal can now become a span"
    )
    #expect(
        ActivityWatcher.nativeAgentBundleIDs != ActivityPolicy.alwaysExcludedBundleIDs,
        "the two sets converged — if that is deliberate, delete this surface instead"
    )

    // ZERO CALLERS, repo-wide. The moment one appears, this test names it and
    // whoever added it has to decide which set they actually meant.
    var callers: [String] = []
    for tree in [
        "Modules/NativeAgentCore/Sources",
        "Sources/NativeAgentApp",
        "Modules/NativeAgentShared/Sources",
    ] {
        for file in (try? sources(under: tree)) ?? []
        where file.source.contains("nativeAgentBundleIDs")
            && !file.source.contains("public static var nativeAgentBundleIDs") {
            callers.append(file.path)
        }
    }
    #expect(
        callers.isEmpty,
        Comment(rawValue: """
        SOMETHING NOW CALLS ActivityWatcher.nativeAgentBundleIDs: \(callers.sorted()).

        It is NOT the exclusion authority — it is alwaysExcludedBundleIDs minus \
        com.apple.loginwindow, so using it as "the ids we never record" starts \
        recording the lock screen. Use ActivityPolicy.alwaysExcludedBundleIDs, or \
        delete this surface.
        """)
    )
}

// MARK: activity.watcher.unknownFrontmostAndSelfPidGap + activity.watcher.motorEpochGate

@Test("ANTI-MISATTRIBUTION: no path out of handleActivation leaves the engine untold")
func handleActivationAlwaysFeedsBeforeReturning() throws {
    // THE FIX, UNPINNED. Four branches inside `handleActivation` synthesize a
    // feed rather than returning early: the motor-epoch gate, the lock signal,
    // an unknown frontmost (nil bundle id or pid), and our own pid. The comment
    // records why — an early `return` left the prior span OPEN, so a transient
    // bundle-less process silently donated its dwell time to whatever the human
    // was in before it. Delete any one of those feeds and the misattribution
    // comes back as a perfectly well-formed LONGER row: no error, no
    // zero-length artefact, nothing an existing guard would catch. The method
    // is private, so source is the cheap witness.
    let watcher = try watchSource(
        "Modules/NativeAgentCore/Sources/ActivityWatch/ActivityWatcher.swift"
    )
    let body = try #require(
        functionBody(watcher, named: "handleActivation"),
        "handleActivation was renamed or restructured — this guard is now blind"
    )

    // The three capture GATES at the top return without feeding, correctly:
    // capture is off, or we are stopping, or paused. Everything after the
    // motor-epoch gate is a real activation the engine has to hear about.
    let gateEnd = try #require(
        body.range(of: "motorEpochIsAgentDriven()"),
        "the motor-epoch gate moved — re-anchor this guard before trusting it"
    )
    let guarded = String(body[gateEnd.upperBound...])

    var feedsSinceLastReturn = 0
    var returnsWithoutFeed: [String] = []
    var returnSites = 0
    for rawLine in guarded.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.contains("feed(") { feedsSinceLastReturn += 1 }
        guard line == "return" || line.hasPrefix("return ") else { continue }
        returnSites += 1
        if feedsSinceLastReturn == 0 { returnsWithoutFeed.append(line) }
        feedsSinceLastReturn = 0
    }

    #expect(
        returnSites >= 5,
        "found only \(returnSites) return sites after the gates — the guard lost its target"
    )
    #expect(
        returnsWithoutFeed.isEmpty,
        Comment(rawValue: """
        \(returnsWithoutFeed.count) EARLY RETURN(S) IN handleActivation TELL THE ENGINE NOTHING. \
        An activation that returns without a feed leaves the previous span OPEN, so the \
        next process to take the foreground donates its dwell time to whatever the human \
        was in before it — one longer, perfectly well-formed row that no guard catches.
        """)
    )

    // The two named synthesis sites, by their payloads. A rename that made
    // either of them feed the REAL bundle id would put the agent's own browsing
    // (or a bundle-less process's time) into the human's top_apps.
    let flattened = guarded
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    for marker in [
        "bundleId: ActivityPolicy.selfProcessBundleID, appName: \"unknown\"",
        "bundleId: ActivityPolicy.selfProcessBundleID, appName: \"self\"",
    ] {
        #expect(
            flattened.contains(marker),
            Comment(rawValue: "handleActivation no longer synthesizes `\(marker)`")
        )
    }
    // The motor-epoch branch feeds the SENTINEL, never the app the agent drove.
    #expect(
        String(guarded.prefix(500)).contains("ActivityPolicy.selfProcessBundleID"),
        """
        the agent-driven branch no longer attributes to the self sentinel. Apps the \
        AGENT opened would be recorded as the human choosing them, inflating his time \
        in whatever NativeAgent browsed on his behalf.
        """
    )
}

// MARK: activity.watcher.pauseResume (the dead-control half)

@Test("DEAD CONTROL: pause()/resume() are still uncalled, so the indicator path is unproven")
func pauseAndResumeCallerInventory() throws {
    // Recorded as an inventory, not a prohibition. `pause()` and `resume()` are
    // public and have no caller in the app: the capture indicator's paused state
    // is therefore only ever exercised by tests. If a caller appears, that is
    // the moment the live detach/re-seed path starts mattering and this fence
    // needs a real lifecycle eval, not just the flag assertions in
    // ActivityWatcherContractTests.
    //
    // The receiver has to be watcher-shaped or this counts every DispatchSource
    // in the tree: `activity-probe run` calls `.resume()` on three of them, and
    // a scan that matched those would be a guard that is always red and
    // therefore always ignored.
    var callers: [String] = []
    for tree in ["Sources/NativeAgentApp", "Modules/NativeAgentCore/Sources"] {
        for file in (try? sources(under: tree)) ?? [] {
            guard file.path != "ActivityWatcher.swift" else { continue }
            guard file.source.contains("ActivityWatcher") else { continue }
            for call in [".pause()", ".resume()"] {
                var cursor = Substring(file.source)
                while let hit = cursor.range(of: call) {
                    let receiver = cursor[..<hit.lowerBound]
                        .suffix(40)
                        .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
                        .last
                        .map(String.init) ?? ""
                    if receiver.lowercased().contains("watcher") {
                        callers.append("\(file.path) (\(receiver)\(call))")
                    }
                    cursor = cursor[hit.upperBound...]
                }
            }
        }
    }
    #expect(
        callers.isEmpty,
        Comment(rawValue: """
        ActivityWatcher.pause()/resume() now has a caller: \(callers.sorted()).

        That is fine — but the detach-on-pause and re-seed-on-resume behaviour has never \
        been proven against a running capture thread. Add a lifecycle eval before relying \
        on the indicator these calls drive.
        """)
    )
}

// MARK: activity.cli.simulateScratchRootGuard + activity.cli.destructive

@Test("PROBE CLI: the scratch-root diversion is decided BEFORE the subcommand dispatch")
func simulateScratchRootGuardIsDecidedBeforeDispatch() throws {
    // THE GUARD BETWEEN A DEV COMMAND AND THE REAL RECORD. `simulate` writes
    // synthetic spans, runs startup reconciliation, then PRINTS EVERY SPAN IN
    // THE STORE to stdout. Without --data-root it diverts to a scratch temp
    // store. If that diversion ever regresses — `isExplicitDataRoot` computed
    // after the option is consumed, a default value slipping into
    // `extractOption`, a `var` someone reassigns — a bare
    // `activity-probe simulate --script foo.json` both corrupts the live store
    // with fabricated rows AND dumps days of the human's real window titles to a
    // terminal, in one command, exiting 0. Today the guard is held up entirely
    // by a code comment.
    let cli = try watchSource("Modules/NativeAgentCore/Sources/ActivityProbeCLI/main.swift")

    let extract = try #require(
        cli.range(of: "extractOption(\"--data-root\", from: &arguments)"),
        "the --data-root extraction moved — this ordering guard is blind"
    )
    let flag = try #require(
        cli.range(of: "let isExplicitDataRoot = probeDataRootOption != nil"),
        Comment(rawValue: """
        `isExplicitDataRoot` is no longer derived directly from the presence of the \
        --data-root option. Whatever replaced it decides whether `simulate` writes into \
        the user's real activity history.
        """)
    )
    let commandLet = try #require(cli.range(of: "let command = arguments.first"))
    let dispatch = try #require(
        cli.range(of: "switch command {"), "the subcommand dispatch moved"
    )

    #expect(
        extract.upperBound <= flag.lowerBound,
        "isExplicitDataRoot is computed BEFORE --data-root is read — it can only be wrong"
    )
    #expect(
        flag.upperBound < commandLet.lowerBound && commandLet.upperBound < dispatch.lowerBound,
        """
        THE SCRATCH-ROOT DECISION NOW HAPPENS AT OR AFTER SUBCOMMAND DISPATCH. It must be \
        settled from the raw argument list before any command can run, or `simulate` \
        reaches the live store first and asks afterwards.
        """
    )
    // A `let`, so nothing downstream can flip it.
    #expect(
        !cli.contains("var isExplicitDataRoot"),
        "isExplicitDataRoot became mutable — a later reassignment fails the guard OPEN"
    )

    // The diversion itself: the non-explicit branch must build a temp path, not
    // fall through to the resolved data root.
    let simulateBody = try #require(functionBody(cli, named: "commandSimulate"))
    #expect(simulateBody.contains("if isExplicitDataRoot"))
    #expect(
        simulateBody.contains("FileManager.default.temporaryDirectory"),
        "commandSimulate no longer builds a scratch store — synthetic spans land in the real one"
    )
    #expect(
        simulateBody.contains("standardError"),
        "the scratch-root diversion no longer says so on stderr — a silent redirect is its own trap"
    )

    // And the one destructive command that is guarded stays guarded: `wipe`
    // must refuse before it opens a store, not after.
    let wipeBody = try #require(functionBody(cli, named: "commandWipe"))
    let yesGuard = try #require(
        wipeBody.range(of: "extractFlag(\"--yes\""),
        "`wipe` no longer requires --yes — a bare `activity-probe wipe` now destroys real history"
    )
    let opensStore = try #require(wipeBody.range(of: "ActivitySpanStore(dataRoot:"))
    #expect(
        yesGuard.upperBound < opensStore.lowerBound,
        "`wipe` opens the store before checking --yes"
    )
    #expect(wipeBody.contains("return 64"), "`wipe` without --yes no longer exits non-zero")
}
