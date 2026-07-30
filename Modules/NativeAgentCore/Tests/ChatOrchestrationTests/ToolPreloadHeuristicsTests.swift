import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import MacIntegration

// U1 step 7 — predictive tool preload. Covers the brief's required cases:
// pattern→group table, gated-group exclusion (Full Mac off → builder never
// preloads even on match), the Mac Integration policy mirror (a
// policy-denied tool never preloads, 2026-06-10 review fix), the builder
// evidence gate (single ambiguous verbs never preload the big builder
// union), the 2-group cap, no-match → no-op, and the tool.preload trace
// row shape. Automatic preloads are request-scoped: explicit tool_load is the
// only path that persists to ActiveToolsStore.
//
// Every preloadIfConfident call passes a HERMETIC
// MacIntegrationPermissionStore pinned to the test temp root — the default
// `.shared` store reads the developer machine's real permission file.

private func makeTempRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("toolpreload-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func readTraceRows(_ root: URL) -> [[String: JSONValue]] {
    let path = root
        .appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard case .object(let obj)? = try? JSONValue.parse(Data(line.utf8)) else { return nil }
        return obj
    }
}

/// The catalog as the turn context sees it with Full Mac OFF: built-in
/// names only — no shell/bash/git/apply_patch/run_tests/swift_build/swift_test,
/// no Full-Mac file
/// tools. Mirrors listAvailableToolSchemas() under a locked policy.
private let availableFullMacOff: Set<String> = Set(SwiftToolDispatcher.builtInToolNames)

/// Full Mac ON: built-ins plus every Full-Mac list (fileOps + system +
/// builder + restart), the union listAvailableTools() appends when
/// fullMacToolAccess() allows.
private let availableFullMacOn: Set<String> = availableFullMacOff
    .union(SwiftToolDispatcher.fullMacFileToolNames)
    .union(SwiftToolDispatcher.fullMacSystemToolNames)
    .union(SwiftToolDispatcher.fullMacBuilderToolNames)
    .union(SwiftToolDispatcher.fullMacRestartToolNames)

@Suite("ToolPreloadHeuristics")
struct ToolPreloadHeuristicsTests {

    // MARK: pattern → group table

    @Test("file nouns and paths map to the files group")
    func filesGroup() {
        let byNoun = ToolPreloadHeuristics.predict(userMessage: "can you read that file for me")
        #expect(byNoun?.groupNames.contains("files") == true)
        #expect(byNoun?.candidateTools.contains("read_file") == true)
        #expect(byNoun?.candidateTools.contains("list_dir") == true)

        let byPath = ToolPreloadHeuristics.predict(userMessage: "what's in ~/Projects/NativeAgent/README.md")
        #expect(byPath?.groupNames.contains("files") == true)
        // Privacy: signals are generic markers, never the user's token.
        #expect(byPath?.matchedPatterns.contains(ToolPreloadHeuristics.pathSignalMarker) == true)
        #expect(byPath?.matchedPatterns.contains(ToolPreloadHeuristics.extensionSignalMarker) == true)
        #expect(byPath?.matchedPatterns.contains("~/projects/nativeagent/readme.md") != true)
    }

    @Test("resident route hints add only known closed groups")
    func residentRouteHints() {
        let prediction = ToolPreloadHeuristics.predict(
            userMessage: "please take a look",
            residentGroupHints: ["builder", "not-a-real-group"]
        )
        #expect(prediction?.groupNames == ["builder"])
        #expect(prediction?.matchedPatterns == ["resident-route:builder"])
        #expect(prediction?.candidateTools.contains("git_status") == true)

        let index = ToolPreloadHeuristics.groupIndex(
            availableToolNames: ["git_status", "read_file", "browser.navigate"]
        )
        #expect(index["builder"]?.contains("git_status") == true)
        #expect(index["files"]?.contains("read_file") == true)
        #expect(index["browser"] == ["browser.navigate"])
    }

    @Test("every compact catalog group resolves through tool_load")
    func compactGroupsShareLoaderContract() throws {
        let inventory = availableFullMacOn.union([
            "browser.status",
            "browser.open_url",
            "browser.navigate",
            "browser.read_text",
            "browser.read_links",
            "browser.screenshot",
        ])
        let index = ToolPreloadHeuristics.groupIndex(availableToolNames: inventory)
        #expect(!index.isEmpty)
        for (group, advertisedNames) in index {
            let resolved = try #require(
                ToolPreloadHeuristics.loadGroup(forCategory: group),
                "compact catalog advertised an unknown tool_load category: \(group)"
            )
            #expect(resolved.group == group)
            #expect(Set(advertisedNames).isSubset(of: resolved.tools))
        }

        #expect(ToolPreloadHeuristics.loadGroup(forCategory: "calendar")?.tools.contains("mac_calendar_list_upcoming") == true)
        #expect(ToolPreloadHeuristics.loadGroup(forCategory: "files")?.tools.contains("read_file") == true)
        #expect(ToolPreloadHeuristics.loadGroup(forCategory: "coding")?.group == "builder")
    }

    @Test("slash-separated prose does not preload local file tools")
    func slashSeparatedProseIsNotAPath() {
        for message in [
            "what does your current inner/body posture feel like?",
            "give me the yes/no answer",
            "this is an and/or question",
        ] {
            let prediction = ToolPreloadHeuristics.predict(userMessage: message)
            #expect(prediction?.groupNames.contains("files") != true, "files matched on: \(message)")
        }

        #expect(ToolPreloadHeuristics.predict(
            userMessage: "read docs/HANDOFF_CURRENT and summarize it"
        )?.groupNames.contains("files") == true)
        #expect(ToolPreloadHeuristics.predict(
            userMessage: "read Sources/NativeAgentApp/AppModel.swift"
        )?.groupNames.contains("files") == true)
    }

    @Test("handoff and docs language maps to local file/search tools")
    func handoffDocsGroup() {
        let p = ToolPreloadHeuristics.predict(
            userMessage: "can you look at the NativeAgent handoff and tell me the next risky thing?"
        )
        #expect(p?.groupNames.contains("files") == true)
        #expect(p?.candidateTools.contains("read_file") == true)
        #expect(p?.candidateTools.contains("grep") == true)
    }

    @Test("domain paths are browser intent, not local file paths")
    func domainPathMapsToBrowser() {
        let p = ToolPreloadHeuristics.predict(
            userMessage: "can you find the newest item on openai.com/news and tell me the headline?"
        )
        #expect(p?.groupNames.contains("browser") == true)
        #expect(p?.groupNames.contains("files") != true)
        #expect(p?.matchedPatterns.contains(ToolPreloadHeuristics.webAddressSignalMarker) == true)
        #expect(p?.matchedPatterns.contains(ToolPreloadHeuristics.pathSignalMarker) != true)
        #expect(p?.candidateTools.contains("browser.navigate") == true)
        #expect(p?.candidateTools.contains("browser.read_text") == true)
    }

    @Test("news research language preloads small research tools, not builder")
    func newsResearchGroup() async throws {
        let p = ToolPreloadHeuristics.predict(
            userMessage: "can you search for OpenAI news and tell me what useful links show up?"
        )
        #expect(p?.groupNames.contains("research") == true)
        #expect(p?.groupNames.contains("builder") != true)
        #expect(p?.candidateTools.contains("x_search") != true)
        #expect(p?.candidateTools.contains("browser.open_url") == true)
        #expect(p?.candidateTools.contains("browser.read_links") == true)

        let root = try makeTempRoot("news-research")
        let sessionId = "news-research-\(UUID().uuidString)"
        let appResearchAvailable = availableFullMacOff.union([
            "browser.status",
            "browser.open_url",
            "browser.navigate",
            "browser.read_text",
            "browser.read_links",
            "browser.screenshot",
        ])
        let active = await ToolPreloadHeuristics.preloadIfConfident(
            prediction: p,
            sessionId: sessionId,
            activeTools: [],
            availableToolNames: appResearchAvailable,
            surface: "chat",
            permissions: MacIntegrationPermissionStore(dataRoot: root),
            dataRoot: root
        )

        #expect(!active.contains("x_search"))
        #expect(active.contains("browser.open_url"))
        #expect(active.contains("browser.read_links"))
        #expect(!active.contains("git_status"))
        #expect(!active.contains("shell"))
    }

    @Test("run/test/build/shell map to the builder group")
    func builderGroup() {
        let p = ToolPreloadHeuristics.predict(userMessage: "run the tests and check git status")
        #expect(p?.groupNames.contains("builder") == true)
        #expect(p?.candidateTools.contains("shell") == true)
        #expect(p?.candidateTools.contains("run_tests") == true)
        #expect(p?.candidateTools.contains("git_status") == true)
    }

    // MARK: builder evidence gate (2026-06-10 review fix)

    @Test("weak token signals never match the builder group on their own")
    func builderWeakSignalsNoMatch() {
        // Weak tokens — alone OR in pairs — must NOT preload the big
        // Full-Mac builder union. The 2-weak-token rule was dropped
        // (gpt-5.5 delta re-review, 2026-06-10): conversational English
        // pairs weak verbs constantly ("run a test in your head"). A URL
        // ending in a script extension is a link, not local script intent.
        for message in [
            "test this idea",
            "run that by me",
            "can you build on that thought",
            "commit to the plan",
            "what a script that movie had",
            "run a test in your head",        // run + test (weak pair)
            "build and test it",              // build + test (weak pair)
            "download https://example.com/deploy.sh",  // URL, not a script
        ] {
            let p = ToolPreloadHeuristics.predict(userMessage: message)
            #expect(p?.groupNames.contains("builder") != true, "builder matched on: \(message)")
        }
    }

    @Test("strong compound phrases match the builder group")
    func builderStrongPhraseMatch() {
        for message in [
            "run the test suite",   // "test suite" strong phrase
            "git commit this",      // "git commit" strong phrase
            "what's changed in the repo since the last commit",
            "Can you check where the NativeAgent repo stands right now? I just need the short version.",
        ] {
            let p = ToolPreloadHeuristics.predict(userMessage: message)
            #expect(p?.groupNames.contains("builder") == true, "builder missed: \(message)")
        }
    }

    @Test("one unambiguous strong signal matches the builder group")
    func builderStrongSignalMatch() {
        // Compound phrase with only ONE weak token.
        let bySwiftBuild = ToolPreloadHeuristics.predict(userMessage: "swift build is failing")
        #expect(bySwiftBuild?.groupNames.contains("builder") == true)
        // xcodebuild token alone.
        let byXcodebuild = ToolPreloadHeuristics.predict(userMessage: "xcodebuild keeps hanging")
        #expect(byXcodebuild?.groupNames.contains("builder") == true)
        // Explicit script-file token alone — recorded as a generic marker,
        // never the user's filename (trace privacy).
        let byScript = ToolPreloadHeuristics.predict(userMessage: "execute deploy.sh for me")
        #expect(byScript?.groupNames.contains("builder") == true)
        #expect(byScript?.matchedPatterns.contains(ToolPreloadHeuristics.builderScriptSignalMarker) == true)
        #expect(byScript?.matchedPatterns.contains("deploy.sh") != true)
    }

    @Test("market vocabulary maps to the markets group")
    func marketsGroup() {
        let p = ToolPreloadHeuristics.predict(userMessage: "what's on my watchlist, any stock movers?")
        #expect(p?.groupNames.contains("markets") == true)
        #expect(p?.candidateTools.contains("market_quote") == true)
    }

    @Test("mail vocabulary maps to the mail group")
    func mailGroup() {
        let p = ToolPreloadHeuristics.predict(userMessage: "any new email in my inbox?")
        #expect(p?.groupNames.contains("mail") == true)
        #expect(p?.candidateTools.contains("mail_list_recent") == true)
    }

    @Test("Slack vocabulary maps to the slack group")
    func slackGroup() {
        let p = ToolPreloadHeuristics.predict(userMessage: "post that to the Slack channel")
        #expect(p?.groupNames.contains("slack") == true)
        #expect(p?.candidateTools.contains("slack_post_message") == true)
    }

    @Test("GitHub project vocabulary preloads the durable tracking surface")
    func githubGroup() {
        let p = ToolPreloadHeuristics.predict(userMessage: "What changed in the Hermes GitHub pull requests, and do I owe a review?")
        #expect(p?.groupNames.contains("github") == true)
        #expect(p?.candidateTools.contains("github_project_digest") == true)
        #expect(p?.candidateTools.contains("github_get_pull_request") == true)
        #expect(p?.candidateTools.contains("github_mutate") == true)
    }

    @Test("bare Hermes agent wording does not imply GitHub")
    func hermesIsNotAlwaysGitHub() {
        let p = ToolPreloadHeuristics.predict(userMessage: "train the Hermes agent memory")
        #expect(p?.groupNames.contains("github") != true)
    }

    @Test("token matching is exact — git does not fire on digital")
    func tokenBoundaries() {
        let p = ToolPreloadHeuristics.predict(userMessage: "I love digital watches")
        #expect(p?.groupNames.contains("builder") != true)
    }

    @Test("inbox does not fire inside path/underscore tokens — agent_inbox regression")
    func inboxStandaloneOnly() {
        // Live false positive 2026-06-10 22:52: 'docs/agent_inbox/...' path
        // tokens fragment into agent+inbox under the alphanumeric tokenizer
        // and preloaded the whole mail group on a repo-file question.
        let path = ToolPreloadHeuristics.predict(
            userMessage: "read docs/agent_inbox/from_claude.md and summarize it"
        )
        #expect(path?.groupNames.contains("mail") != true)
        let underscore = ToolPreloadHeuristics.predict(
            userMessage: "what does agent_inbox hold right now?"
        )
        #expect(underscore?.groupNames.contains("mail") != true)
        // Standalone word (incl. trailing punctuation) must still fire.
        let standalone = ToolPreloadHeuristics.predict(userMessage: "anything new in my inbox?")
        #expect(standalone?.groupNames.contains("mail") == true)
        let punctuated = ToolPreloadHeuristics.predict(userMessage: "go check the inbox.")
        #expect(punctuated?.groupNames.contains("mail") == true)
    }

    @Test("memory group is load-only — recall tools never consume a preload slot")
    func memoryGroupAbsent() {
        // The compatibility category stays accepted by tool_load, but it is
        // intentionally excluded from prediction and compact discovery.
        let p = ToolPreloadHeuristics.predict(userMessage: "remember what I said about memory recall")
        #expect(p == nil || !p!.groupNames.contains("memory"))
        for g in ToolPreloadHeuristics.table where g.preloadable {
            #expect(g.group != "memory")
            #expect(g.tools.isDisjoint(with: SwiftToolDispatcher.alwaysOnCoreNames))
        }
        #expect(ToolPreloadHeuristics.groupIndex(availableToolNames: availableFullMacOn)["memory"] == nil)
        #expect(ToolPreloadHeuristics.loadGroup(forCategory: "recall")?.group == "memory")
    }

    // MARK: cap

    @Test("at most maxGroupsPerTurn groups, ranked; strongest survive the cap")
    func groupCapBindsAndRanks() {
        // Cap raised 2→3 in the 2026-07-19 Continuum incident fix (the old
        // cap evicted the explicitly named github group). Four matching
        // groups prove the cap still BINDS at the new bound: mail
        // (email+inbox), calendar (calendar+meetings), markets (watchlist),
        // music (playlist) — the weakest single-token group past the cap is
        // dropped, strongest two always survive.
        let p = ToolPreloadHeuristics.predict(
            userMessage: "check my email inbox, my calendar meetings, the watchlist, and my playlist"
        )
        #expect(p != nil)
        #expect(p!.groups.count == ToolPreloadHeuristics.maxGroupsPerTurn)
        #expect(p!.groupNames.contains("mail"))
        #expect(p!.groupNames.contains("calendar"))
        let dropped = ["markets", "music"].filter { !p!.groupNames.contains($0) }
        #expect(dropped.count == 1, "exactly one single-token group falls past the cap")
    }

    // MARK: no match → no-op

    @Test("no confident match predicts nothing")
    func noMatchPredictsNil() {
        #expect(ToolPreloadHeuristics.predict(userMessage: "good morning, how are you today?") == nil)
        #expect(ToolPreloadHeuristics.predict(userMessage: "") == nil)
        #expect(ToolPreloadHeuristics.predict(userMessage: "   \n  ") == nil)
    }

    @Test("no match leaves active set, store, and traces untouched")
    func noMatchIsStatusQuo() async throws {
        let root = try makeTempRoot("nomatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = UUID().uuidString
        let active: Set<String> = ["market_quote"]

        let out = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "good morning, how are you today?",
            sessionId: sessionId,
            activeTools: active,
            availableToolNames: availableFullMacOn,
            surface: "chat",
            store: store,
            permissions: MacIntegrationPermissionStore(dataRoot: root),
            dataRoot: root
        )
        #expect(out == active)
        let persisted = await store.load(sessionId: sessionId).activeTools
        #expect(persisted.isEmpty)
        #expect(readTraceRows(root).isEmpty)
    }

    // MARK: gated-group exclusion

    @Test("Full Mac off — builder tools never preload even on a match")
    func gatedBuilderExcluded() async throws {
        let root = try makeTempRoot("gated")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = UUID().uuidString

        let out = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "run the tests with bash and git",
            sessionId: sessionId,
            activeTools: [],
            availableToolNames: availableFullMacOff,
            surface: "chat",
            store: store,
            permissions: MacIntegrationPermissionStore(dataRoot: root),
            dataRoot: root
        )
        for gatedName in SwiftToolDispatcher.fullMacBuilderToolNames
            + SwiftToolDispatcher.fullMacFileToolNames
            + SwiftToolDispatcher.fullMacSystemToolNames
            + SwiftToolDispatcher.fullMacRestartToolNames {
            // write_file appears in both the builder union and the plain
            // built-in catalog — it stays preloadable under the workspace
            // gate. Everything Full-Mac-only must be absent.
            if gatedName == "write_file" { continue }
            #expect(!out.contains(gatedName), "gated tool preloaded: \(gatedName)")
        }
        let persisted = await store.load(sessionId: sessionId).activeTools
        #expect(persisted.isDisjoint(with: Set(SwiftToolDispatcher.fullMacBuilderToolNames)))
    }

    @Test("Full Mac on — same message preloads builder tools for this turn only")
    func builderIncludedWhenPolicyAllowsWithoutPersisting() async throws {
        let root = try makeTempRoot("allowed")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = UUID().uuidString

        let out = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "run the tests with bash and git",
            sessionId: sessionId,
            activeTools: [],
            availableToolNames: availableFullMacOn,
            surface: "chat",
            store: store,
            permissions: MacIntegrationPermissionStore(dataRoot: root),
            dataRoot: root
        )
        #expect(out.contains("run_tests"))
        #expect(out.contains("bash"))
        let persisted = await store.load(sessionId: sessionId).activeTools
        #expect(persisted.isEmpty)
    }

    // MARK: Mac Integration policy mirror (2026-06-10 review fix)

    @Test("Mail write off — 'send an email' never preloads mail write tools")
    func mailWriteDeniedExcludesWriteTools() async throws {
        let root = try makeTempRoot("mailwrite-off")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = UUID().uuidString
        // the user's defaults: mail read ON, mail write OFF. Pin them explicitly
        // so the test doesn't lean on default drift.
        let permissions = MacIntegrationPermissionStore(dataRoot: root)
        try await permissions.set(integrationId: MacIntegrationID.mail, read: true, write: false)

        let out = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "send an email to Dave about the launch",
            sessionId: sessionId,
            activeTools: [],
            availableToolNames: availableFullMacOn,
            surface: "chat",
            store: store,
            permissions: permissions,
            dataRoot: root
        )
        let mailWriteTools: Set<String> = [
            "mail_send", "mail_reply", "mail_mark_read", "mail_archive", "mail_delete",
        ]
        #expect(out.isDisjoint(with: mailWriteTools), "policy-denied mail write tool preloaded: \(out.intersection(mailWriteTools))")
        // Exact dispatch-gate mirror is per-(integration, mode): read is
        // still ON, so the mail READ tools remain preloadable.
        #expect(out.contains("mail_search"))
        let persisted = await store.load(sessionId: sessionId).activeTools
        #expect(persisted.isDisjoint(with: mailWriteTools))
    }

    @Test("Mail read+write off — the mail group can never be preloaded at all")
    func mailFullyDeniedExcludesWholeGroup() async throws {
        let root = try makeTempRoot("mail-all-off")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = UUID().uuidString
        let permissions = MacIntegrationPermissionStore(dataRoot: root)
        try await permissions.set(integrationId: MacIntegrationID.mail, read: false, write: false)

        let out = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "send an email to Dave about the launch",
            sessionId: sessionId,
            activeTools: [],
            availableToolNames: availableFullMacOn,
            surface: "chat",
            store: store,
            permissions: permissions,
            dataRoot: root
        )
        // Whole group policy-denied → status quo: nothing preloaded, no
        // store write, no trace row.
        #expect(out.isEmpty)
        let persisted = await store.load(sessionId: sessionId).activeTools
        #expect(persisted.isEmpty)
        #expect(readTraceRows(root).isEmpty)
    }

    @Test("Corrupt Mac Integration authority denies preload instead of applying defaults")
    func corruptMacIntegrationAuthorityDeniesPreload() async throws {
        let root = try makeTempRoot("mac-permissions-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let permissionPath = root
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("mac_integration_permissions.json")
        try FileManager.default.createDirectory(
            at: permissionPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"mail":{"read":"true","write":false}}"#.utf8)
            .write(to: permissionPath, options: .atomic)

        let out = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "search my email for the launch",
            sessionId: UUID().uuidString,
            activeTools: [],
            availableToolNames: availableFullMacOn,
            surface: "chat",
            store: ActiveToolsStore(dataRoot: root),
            permissions: MacIntegrationPermissionStore(dataRoot: root),
            dataRoot: root
        )

        #expect(out.isEmpty)
        #expect(readTraceRows(root).isEmpty)
    }

    @Test("gate table covers every Mac Integration tool in the group table")
    func macIntegrationGateTableCoversGroupTable() {
        // Lockstep guard: any mail/calendar/messages/notes/contacts/music
        // group member missing from macIntegrationGates would silently skip
        // the policy mirror. (Tool names prefixed mac_/mail_/messages_/
        // notes_/contacts_/music_ are exactly the Mac Integration dispatch
        // cases in ChatOrchestrationClient.)
        let macIntegrationGroups: Set<String> = [
            "mail", "calendar", "messages", "notes", "contacts", "music",
        ]
        for entry in ToolPreloadHeuristics.table where macIntegrationGroups.contains(entry.group) {
            for tool in entry.tools {
                #expect(
                    ToolPreloadHeuristics.macIntegrationGates[tool] != nil,
                    "Mac Integration tool missing from the preload policy gate table: \(tool)"
                )
            }
        }
    }

    @Test("gate table matches every dispatchMacIntegrationTool case exactly")
    func macIntegrationGateTableMatchesDispatchContract() {
        // Completeness contract (gpt-5.5 review, 2026-06-10): the table
        // doubles as the parallel-dispatch write veto, so it must cover
        // EVERY dispatchMacIntegrationTool case in ChatOrchestrationClient
        // with the exact (integration, mode) pair that case passes —
        // including tools in NO preload group (scheduler_list_jobs gates on
        // .write despite its listy name; scheduler has no read axis). When
        // a new dispatch case lands, update BOTH the gates table and this
        // contract — a one-sided edit fails here.
        let dispatchContract: [String: (integration: String, mode: MacIntegrationPermissionMode)] = [
            "mac_calendar_list_upcoming": (MacIntegrationID.calendar, .read),
            "mac_calendar_create_event": (MacIntegrationID.calendar, .write),
            "mac_calendar_modify_event": (MacIntegrationID.calendar, .write),
            "mac_reminders_list_due_today": (MacIntegrationID.reminders, .read),
            "mac_reminders_create": (MacIntegrationID.reminders, .write),
            "mac_reminders_complete": (MacIntegrationID.reminders, .write),
            "mail_list_recent": (MacIntegrationID.mail, .read),
            "mail_search": (MacIntegrationID.mail, .read),
            "mail_send": (MacIntegrationID.mail, .write),
            "mail_mark_read": (MacIntegrationID.mail, .write),
            "mail_archive": (MacIntegrationID.mail, .write),
            "mail_delete": (MacIntegrationID.mail, .write),
            "mail_reply": (MacIntegrationID.mail, .write),
            "messages_recent_threads": (MacIntegrationID.messages, .read),
            "messages_send": (MacIntegrationID.messages, .write),
            "notes_search": (MacIntegrationID.notes, .read),
            "notes_create": (MacIntegrationID.notes, .write),
            "notes_update": (MacIntegrationID.notes, .write),
            "contacts_search": (MacIntegrationID.contacts, .read),
            "contacts_create_or_update": (MacIntegrationID.contacts, .write),
            "contacts_delete": (MacIntegrationID.contacts, .write),
            "music_now_playing": (MacIntegrationID.music, .read),
            "music_search_library": (MacIntegrationID.music, .read),
            "music_list_library": (MacIntegrationID.music, .read),
            "music_list_playlists": (MacIntegrationID.music, .read),
            "music_control": (MacIntegrationID.music, .write),
            "mac_notify": (MacIntegrationID.notifyMac, .write),
            "mac_spotlight_search": (MacIntegrationID.spotlight, .read),
            "scheduler_list_jobs": (MacIntegrationID.scheduler, .write),
            "scheduler_create_job": (MacIntegrationID.scheduler, .write),
        ]
        #expect(Set(ToolPreloadHeuristics.macIntegrationGates.keys) == Set(dispatchContract.keys))
        for (tool, expected) in dispatchContract {
            let gate = ToolPreloadHeuristics.macIntegrationGates[tool]
            #expect(gate?.integration == expected.integration, "integration mismatch @\(tool)")
            #expect(gate?.mode == expected.mode, "mode mismatch @\(tool)")
        }
    }

    // MARK: union-only + always-on hygiene

    @Test("preload unions — never evicts, never re-adds always-on or active")
    func unionOnly() async throws {
        let root = try makeTempRoot("union")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = UUID().uuidString
        let preExisting: Set<String> = ["x_search", "market_quote"]
        _ = try await store.addLoaded(sessionId: sessionId, names: preExisting)
        // Mail write defaults OFF — flip it ON so the full mail group
        // (including mail_send) is policy-clean; this test pins UNION
        // semantics, not the policy mirror (covered below).
        let permissions = MacIntegrationPermissionStore(dataRoot: root)
        try await permissions.set(integrationId: MacIntegrationID.mail, read: true, write: true)

        let out = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "any new email?",
            sessionId: sessionId,
            activeTools: preExisting,
            availableToolNames: availableFullMacOn,
            surface: "chat",
            store: store,
            permissions: permissions,
            dataRoot: root
        )
        #expect(out.isSuperset(of: preExisting))
        #expect(out.contains("mail_list_recent"))
        #expect(out.isDisjoint(with: SwiftToolDispatcher.alwaysOnCoreNames.subtracting(preExisting)))

        let persisted = await store.load(sessionId: sessionId).activeTools
        #expect(persisted == preExisting)
        #expect(!persisted.contains("mail_send"))
    }

    @Test("preloadableNames drops always-on and unavailable candidates")
    func preloadableNamesFilters() {
        let prediction = ToolPreloadHeuristics.Prediction(
            groups: [ToolPreloadHeuristics.GroupMatch(group: "synthetic", matchedPatterns: ["synthetic"])],
            candidateTools: ["recall_memory", "mail_send", "not_in_catalog_tool"]
        )
        let names = ToolPreloadHeuristics.preloadableNames(
            prediction: prediction,
            availableToolNames: availableFullMacOff,
            alreadyActive: []
        )
        #expect(names == ["mail_send"])
    }

    // MARK: trace row shape

    @Test("tool.preload trace row lands with groups/matchedPatterns payload")
    func traceRowShape() async throws {
        let root = try makeTempRoot("trace")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = UUID().uuidString

        _ = await ToolPreloadHeuristics.preloadIfConfident(
            userMessage: "what's on my watchlist?",
            sessionId: sessionId,
            activeTools: [],
            availableToolNames: availableFullMacOn,
            surface: "telegram",
            store: store,
            permissions: MacIntegrationPermissionStore(dataRoot: root),
            dataRoot: root
        )
        let rows = readTraceRows(root)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["kind"] == .string("tool.preload"))
        #expect(row["status"] == .string("ok"))
        #expect(row["title"] == .string("markets"))
        guard case .string(let id)? = row["id"] else { Issue.record("missing id"); return }
        #expect(!id.isEmpty)
        guard case .string(let createdAt)? = row["createdAt"] else { Issue.record("missing createdAt"); return }
        #expect(!createdAt.isEmpty)
        guard case .object(let payload)? = row["payload"] else { Issue.record("missing payload"); return }
        #expect(payload["groups"] == .array([.string("markets")]))
        #expect(payload["surface"] == .string("telegram"))
        guard case .array(let patterns)? = payload["matchedPatterns"] else {
            Issue.record("missing matchedPatterns"); return
        }
        #expect(patterns.contains(.string("watchlist")))
        guard case .array(let tools)? = payload["tools"] else { Issue.record("missing tools"); return }
        #expect(tools.contains(.string("market_quote")))
    }
}

// MARK: - Bridge-sender working-set hint (task #48, 2026-07-25)

@Suite("ToolPreloadHeuristics bridge-sender hint")
struct ToolPreloadBridgeHintTests {
    @Test func bridgePrefixedTurnHintsWorkingGroups() throws {
        // Real shape of a codex completion relay — no builder-strong lexical
        // evidence in the body, which was exactly the 2026-07-25 miss class.
        let prediction = try #require(ToolPreloadHeuristics.predict(
            userMessage: "[from: codex, via bridge] Codex replied to your message. This is an asynchronous completion event."
        ))
        let groups = Set(prediction.groupNames)
        #expect(groups.isSuperset(of: ["builder", "files", "github"]))
        #expect(prediction.matchedPatterns.contains("bridge-sender:builder"))
        // The hint fills schema visibility with the forensic kit.
        #expect(prediction.candidateTools.contains("bash"))
        #expect(prediction.candidateTools.contains("read_file"))
    }

    @Test func ordinaryChatStaysUnpredicted() {
        // The conversational turns that spawn work ad hoc must NOT start
        // matching — the durable ActiveToolsStore covers them per session.
        #expect(ToolPreloadHeuristics.predict(userMessage: "poke him") == nil)
    }

    @Test func bridgeMarkerRequiresPrefixPosition() {
        // Mentioning the bridge mid-sentence is conversation about the
        // bridge, not a bridge turn.
        let prediction = ToolPreloadHeuristics.predict(
            userMessage: "tell me how [from: codex, via bridge] tags work"
        )
        let patterns = prediction?.matchedPatterns ?? []
        #expect(!patterns.contains { $0.hasPrefix("bridge-sender:") })
    }

    @Test func residentMarkerStaysHonestNextToBridgeHint() throws {
        let prediction = try #require(ToolPreloadHeuristics.predict(
            userMessage: "[from: claude, via bridge] verify the store",
            residentGroupHints: ["desk"]
        ))
        let patterns = prediction.matchedPatterns
        #expect(patterns.contains("resident-route:desk"))
        #expect(patterns.contains("bridge-sender:builder"))
        #expect(!patterns.contains("resident-route:builder"))
    }
}

// MARK: - ActiveToolsStore LRU cap (task #48, 2026-07-25)

@Suite("ActiveToolsStore cap")
struct ActiveToolsStoreCapTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-tools-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func accretionAcrossLoadsEvictsOldestFirst() async throws {
        let root = try makeRoot()
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = "11111111-1111-1111-1111-111111111111"
        let old = (0..<ActiveToolsStore.maxPersistedTools).map { "old_tool_\(String(format: "%02d", $0))" }
        _ = try await store.addLoaded(sessionId: sessionId, names: Set(old))
        // Second load pushes past the cap — the new names must all survive,
        // the bound must hold, and the evicted entries must be old ones.
        let fresh: Set<String> = ["fresh_a", "fresh_b", "fresh_c"]
        let state = try await store.addLoaded(sessionId: sessionId, names: fresh)
        #expect(state.activeTools.count == ActiveToolsStore.maxPersistedTools)
        #expect(state.activeTools.isSuperset(of: fresh))
        #expect(state.activeTools.count(where: { $0.hasPrefix("old_tool_") })
            == ActiveToolsStore.maxPersistedTools - fresh.count)
        // loadedAt bookkeeping stays in lockstep with membership.
        #expect(Set(state.loadedAt.keys) == state.activeTools)
        // Reload from disk agrees (the capped set is what persisted).
        let reloaded = await store.load(sessionId: sessionId)
        #expect(reloaded.activeTools == state.activeTools)
    }

    @Test func singleOversizedLoadIsKeptWhole() async throws {
        let root = try makeRoot()
        let store = ActiveToolsStore(dataRoot: root)
        let sessionId = "22222222-2222-2222-2222-222222222222"
        let big = Set((0..<(ActiveToolsStore.maxPersistedTools + 6)).map { "big_\($0)" })
        let state = try await store.addLoaded(sessionId: sessionId, names: big)
        // The cap bounds accretion ACROSS loads; it never vetoes the load the
        // model just made and believes succeeded.
        #expect(state.activeTools == big)
    }

    @Test func capEvictionIsDeterministicOnEqualStamps() {
        var state = ChatSessionActiveTools(sessionId: "S")
        let names = (0..<(ActiveToolsStore.maxPersistedTools + 2)).map { "t\(String(format: "%02d", $0))" }
        for n in names {
            state.activeTools.insert(n)
            state.loadedAt[n] = "2026-07-25T00:00:00.000Z"
        }
        ActiveToolsStore.enforceCapInPlace(&state, protected: ["t25", "t24"])
        #expect(state.activeTools.count == ActiveToolsStore.maxPersistedTools)
        // Equal stamps break by name: t00/t01 go first, protected names stay.
        #expect(!state.activeTools.contains("t00"))
        #expect(!state.activeTools.contains("t01"))
        #expect(state.activeTools.contains("t25"))
    }
}
