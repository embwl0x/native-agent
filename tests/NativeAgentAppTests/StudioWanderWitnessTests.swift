import Testing
import Foundation
@testable import NativeAgentApp
import BackgroundLoops
import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// HER HOUR, the evidence half — personality-depth item 9.
//
// The lane must tell three endings apart, and it must do it from DISPATCHES
// rather than from the reply text: "I looked at it" is a claim, a `web_fetch`
// is evidence. These tests drive the witness directly with a fake inner
// dispatcher, so nothing here calls a provider or touches the network.

private actor FakeWanderTools: ToolDispatchClient {
    /// tool name → what it answers. Anything in `failing` throws instead, which
    /// is how an organ that cannot reach the work is spelled.
    private let results: [String: JSONValue]
    private let failing: Set<String>
    private(set) var calls: [String] = []

    init(results: [String: JSONValue] = [:], failing: Set<String> = []) {
        self.results = results
        self.failing = failing
    }

    nonisolated func dispatch(
        tool: String,
        input: [String: JSONValue],
        surface: String
    ) async throws -> JSONValue {
        try await record(tool)
    }

    private func record(_ tool: String) throws -> JSONValue {
        calls.append(tool)
        guard !failing.contains(tool) else {
            throw NSError(domain: "FakeWanderTools", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "\(tool) could not reach the work",
            ])
        }
        return results[tool] ?? .object(["status": .string("ok")])
    }

    func callLog() -> [String] { calls }

    nonisolated func listAvailableTools() async throws -> [String] { [] }
    nonisolated func listAvailableToolSchemas() async throws -> [LLMToolSchema] { [] }
}

@Test func studioWanderWitnessStopsBeforeToolsAfterForegroundTakeover() async throws {
    let inner = FakeWanderTools()
    let witness = StudioWanderToolWitness(inner: inner, shouldContinue: { false })
    await #expect(throws: CancellationError.self) {
        try await witness.dispatch(tool: "studio_journal", input: [:], surface: "studio_wander")
    }
    #expect(await inner.callLog().isEmpty)
}

// MARK: - She chose, and met the work

@Test func studioWanderWitness_reachingTheWorkIsAChoice() async throws {
    // The app's REAL browser organs: open the page, then take its text.
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "browser.open_url": .object([
                "status": .string("completed"), "dryRun": .bool(false),
                "sourceReceipt": .object(["url": .string("https://example.org/work")]),
            ]),
            "browser.read_text": .object([
                "status": .string("completed"),
                "dryRun": .bool(false),
                "text": .string("<the work>"),
            ]),
        ])
    )
    _ = try await witness.dispatch(
        tool: "browser.open_url",
        input: ["url": .string("https://example.org/work")],
        surface: NativeCognitionRuntime.studioWanderSurface
    )
    _ = try await witness.dispatch(
        tool: "browser.read_text", input: [:], surface: "studio_wander"
    )
    let report = await witness.report()
    #expect(report.attemptedArtifact)
    #expect(report.obtainedArtifact)
    #expect(report.journalEntryID == nil, "an encounter does not owe a journal entry")
}

/// A BARE NAVIGATION IS NOT RECEIVING. Opening a window and returning brought
/// nothing back to her, so the page is not yet a work she has met — that is the
/// reach, and an hour that ends there is `no_artifact`.
@Test func studioWanderWitness_openingAPageWithoutCapturingIsNotMeetingTheWork() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "browser.open_url": .object(["status": .string("completed"), "dryRun": .bool(false)]),
        ])
    )
    _ = try await witness.dispatch(tool: "browser.open_url", input: [:], surface: "studio_wander")
    let report = await witness.report()
    #expect(report.attemptedArtifact)
    #expect(!report.obtainedArtifact)
}

/// …but navigation that CAPTURED did deliver. `sourceReceipt` /
/// `screenshotReceipt` on the browser run receipt is the page actually coming
/// back to her, and that is an encounter without a second call.
@Test func studioWanderWitness_navigationThatCapturesDoesDeliver() async throws {
    for key in ["sourceReceipt", "screenshotReceipt"] {
        let witness = StudioWanderToolWitness(
            inner: FakeWanderTools(results: [
                "browser.open_url": .object([
                    "status": .string("completed"), "dryRun": .bool(false),
                    key: .object(["url": .string("https://example.org/work")]),
                ]),
            ])
        )
        _ = try await witness.dispatch(
            tool: "browser.open_url", input: [:], surface: "studio_wander"
        )
        #expect(await witness.report().obtainedArtifact, "\(key) is the page coming back")
    }
}

// MARK: - The consult read: her own rule about description-only

/// "A description-only consult is never an encounter" — hers, binding. Reading
/// one is still a REACH (she went and looked at what was on the table), but it
/// delivered no work.
@Test func studioWanderWitness_descriptionOnlyConsultIsNeverAnEncounter() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "studio_consult_read": .object([
                "status": .string("ok"),
                "consult": .object([
                    "description_only": .bool(true),
                    "artifact_refs": .array([.string("~/notes/brief.md")]),
                ]),
            ]),
        ])
    )
    _ = try await witness.dispatch(
        tool: "studio_consult_read", input: [:], surface: "studio_wander"
    )
    let report = await witness.report()
    #expect(report.attemptedArtifact, "opening the consult is reaching for the work")
    #expect(!report.obtainedArtifact)
}

@Test func studioWanderWitness_consultWithNoRefsDeliversNothing() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "studio_consult_read": .object([
                "status": .string("ok"),
                "consult": .object([
                    "description_only": .bool(false),
                    "artifact_refs": .array([]),
                ]),
            ]),
        ])
    )
    _ = try await witness.dispatch(
        tool: "studio_consult_read", input: [:], surface: "studio_wander"
    )
    #expect(!(await witness.report().obtainedArtifact))
}

@Test func studioWanderWitness_referencesRequireASubsequentArtifactRead() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "studio_consult_read": .object([
                "status": .string("ok"),
                "consult": .object([
                    "description_only": .bool(false),
                    "artifact_refs": .array([.string("/nonexistent/artifact.jpg")]),
                ]),
            ]),
            "read_file": .object(["status": .string("ok"), "text": .string("Artifact contents")]),
        ])
    )
    _ = try await witness.dispatch(
        tool: "studio_consult_read", input: [:], surface: "studio_wander"
    )
    #expect(!(await witness.report().obtainedArtifact))
    _ = try await witness.dispatch(tool: "read_file", input: [:], surface: "studio_wander")
    #expect(await witness.report().obtainedArtifact)
}

/// A DRY RUN READS NOTHING. The browser organs return a native action receipt
/// whose `status` is "dry_run" (and `dryRun: true`) while having touched no page
/// at all — the exact shape that would otherwise report an encounter she never
/// had.
@Test func studioWanderWitness_aDryRunIsNotAnEncounter() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "browser.read_text": .object([
                "status": .string("dry_run"),
                "dryRun": .bool(true),
            ]),
        ])
    )
    _ = try await witness.dispatch(tool: "browser.read_text", input: [:], surface: "studio_wander")
    let report = await witness.report()
    #expect(report.attemptedArtifact)
    #expect(!report.obtainedArtifact, "a dry run delivered no work")
}

/// The provider-safe underscore spelling is the same organ. This witness sits
/// outside the app dispatcher's canonicalization, so it must recognise both.
@Test func studioWanderWitness_recognisesBothBrowserSpellings() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "browser_read_text": .object([
                "status": .string("completed"), "dryRun": .bool(false),
            ]),
        ])
    )
    _ = try await witness.dispatch(tool: "browser_read_text", input: [:], surface: "studio_wander")
    #expect(await witness.report().obtainedArtifact)
}

/// SHE, AND ONLY SHE, FILES THE ENTRY. The id comes from her own
/// `studio_journal` dispatch; nothing in the lane appends one.
@Test func studioWanderWitness_readsTheEntryIdFromHerOwnJournalCall() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "read_file": .object(["status": .string("ok"), "content": .string("...")]),
            "studio_journal": .object([
                "status": .string("ok"),
                "entry_id": .string("entry-7f3a"),
            ]),
        ])
    )
    _ = try await witness.dispatch(
        tool: "read_file", input: ["path": .string("/tmp/plate.png")], surface: "studio_wander"
    )
    _ = try await witness.dispatch(tool: "studio_journal", input: [:], surface: "studio_wander")

    let report = await witness.report()
    #expect(report.obtainedArtifact)
    #expect(report.journalEntryID == "entry-7f3a")
}

// MARK: - She reached, and could not receive it

/// THE HONESTY VETO, mechanised. A failed organ is an ATTEMPT with no
/// obtaining, which is exactly `no_artifact` — and the error is rethrown so she
/// sees the failure rather than being handed a silent nothing.
@Test func studioWanderWitness_aFailedOrganIsAttemptedButNotObtained() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(failing: ["browser.read_text"])
    )
    await #expect(throws: (any Error).self) {
        _ = try await witness.dispatch(
            tool: "browser.read_text",
            input: [:],
            surface: "studio_wander"
        )
    }
    let report = await witness.report()
    #expect(report.attemptedArtifact)
    #expect(!report.obtainedArtifact)
    #expect(report.journalEntryID == nil)
}

/// A REFUSAL is not an encounter either. A tool that answers
/// `{"status": "refused"}` returned without throwing, but it did not deliver
/// the work, and treating that as "she met it" is the dishonesty the whole lane
/// exists to prevent.
@Test func studioWanderWitness_aRefusedOrganDoesNotCountAsMeetingTheWork() async throws {
    let witness = StudioWanderToolWitness(
        inner: FakeWanderTools(results: [
            "browser.read_text": .object([
                "status": .string("refused"), "reason": .string("page is not http/https"),
            ]),
        ])
    )
    _ = try await witness.dispatch(
        tool: "browser.read_text", input: [:], surface: "studio_wander"
    )
    let report = await witness.report()
    #expect(report.attemptedArtifact)
    #expect(!report.obtainedArtifact)
}

// MARK: - She declined

@Test func studioWanderWitness_touchingNoOrganIsADecline() async throws {
    let witness = StudioWanderToolWitness(inner: FakeWanderTools())
    _ = try await witness.dispatch(tool: "time_now", input: [:], surface: "studio_wander")
    let report = await witness.report()
    #expect(!report.attemptedArtifact)
    #expect(!report.obtainedArtifact)
    #expect(report.journalEntryID == nil)
}

/// The organ list is a small explicit allowlist on purpose: a tool added
/// tomorrow must not silently start counting as "she met the work".
@Test func studioWanderWitness_organListIsExplicitAndNamesRealTools() {
    for organ in ["browser.read_text", "browser_read_text", "browser.screenshot",
                  "read", "read_file", "file_excerpt", "mac_view", "mac_look"] {
        #expect(StudioWanderToolWitness.deliveringOrgans.contains(organ))
    }
    // Navigation and the consult read reach; whether they deliver is decided
    // per call, from the payload — so neither sits in the unconditional set.
    #expect(StudioWanderToolWitness.artifactOrgans.contains("browser.open_url"))
    #expect(!StudioWanderToolWitness.deliveringOrgans.contains("browser.open_url"))
    #expect(StudioWanderToolWitness.artifactOrgans.contains("studio_consult_read"))
    #expect(!StudioWanderToolWitness.deliveringOrgans.contains("studio_consult_read"))
    // Stale names that never existed in this build's catalog are gone.
    #expect(!StudioWanderToolWitness.artifactOrgans.contains("web_fetch"))
    #expect(!StudioWanderToolWitness.artifactOrgans.contains("web_search"))
    // A glance is not an encounter, and neither is writing or recalling.
    for notAnOrgan in ["screen", "studio_journal", "recall_memory", "time_now"] {
        #expect(!StudioWanderToolWitness.artifactOrgans.contains(notAnOrgan))
    }
}

// MARK: - Her closing line

@Test func studioWanderLine_takesHerLastWordVerbatim() {
    #expect(
        NativeCognitionRuntime.studioWanderLine(
            "I read about the Meuser house but never got the photographs.\n\n"
            + "Left it alone tonight."
        ) == "Left it alone tonight."
    )
    // Never blank, never invented beyond an honest statement of silence.
    #expect(NativeCognitionRuntime.studioWanderLine("   ") == "The hour passed without a word.")
}

// MARK: - The routing row

@Test func studioWander_hasItsOwnPickableRoutingRow() {
    #expect(NativeCognitionRuntime.studioWanderSurface == "studio_wander")
}


// MARK: - THE HOUR CANNOT ACT ON THE WORLD
//
// `runEphemeralToolTurn` inherits the whole catalog and `fileAccess:
// "read_only"` gates only the filesystem. These are the tests that pin the
// actual boundary: an unattended, unwitnessed hour must be unable to speak as
// User, wake another agent, touch his board, move his screen, or change what she
// knows — even if the model asks for exactly that.

private func allowlisted(_ inner: FakeWanderTools) -> StudioWanderToolAllowlist {
    StudioWanderToolAllowlist(inner: inner)
}

/// The named hole, closed. Every one of these is reachable in an ordinary
/// ephemeral turn and none of them is blocked by `read_only`.
@Test func studioWanderAllowlist_refusesEveryWorldReachingTool() async throws {
    let blocked = [
        // Moves what is on User's screen.
        "act", "go", "wait", "mac_click", "mac_keystroke", "mac_ax_act", "mac_focus_app",
        // Drives a real browser session as the user. She may LOOK at a page in
        // her own hour; she may not use one.
        "browser.chrome_click", "browser.chrome_fill", "browser.chrome_type",
        "browser.chrome_keypress", "browser.chrome_scroll", "browser.navigate",
        "browser_chrome_click",
        // Speaks as him.
        "mail_send", "messages_send", "slack_post_message", "agentmail_send", "mac_notify",
        "mobile_notify",
        // Wakes other agents.
        "claude_message", "codex_message", "omp_message", "invoke_codex", "invoke_claude",
        "agent_swarm",
        // Changes what she knows, or what he is looking at.
        "commit_memory", "persona_write", "persona_append_section", "save_skill",
        "desk_add_item", "desk_close", "desk_note", "desk_set_status", "desk_open_pursuit",
        "workshop_submit", "scheduler_create_job",
        // Writes, shells, builds.
        "write_file", "shell", "bash", "git", "apply_patch", "restart_app", "self_install",
        // Her seat, which a background lane may never hold.
        "studio_canon_resolve",
        // FILES a consult envelope into data/studio/consults/. An unattended
        // hour reads what is on the table; it does not put things there.
        "studio_consult",
        // External MCP: unknowable side effects, and not named, so not admitted.
        "mcp__anything__do_something",
    ]
    let tools = FakeWanderTools()
    let gate = allowlisted(tools)
    for tool in blocked {
        await #expect(throws: (any Error).self, "\(tool) must not be reachable in her hour") {
            _ = try await gate.dispatch(tool: tool, input: [:], surface: "studio_wander")
        }
    }
    // Refused means NOT DISPATCHED — the inner body never saw any of them.
    #expect(await tools.callLog().isEmpty)
}

/// The refusal is spoken, not silent: she can read what happened and what she
/// does have, rather than guessing at her own edges.
@Test func studioWanderAllowlist_refusalNamesWhatSheDoesHave() {
    let reason = StudioWanderToolAllowlist.refusal("mail_send")
    #expect(reason.contains("'mail_send' is not available in your own hour"))
    #expect(reason.contains("studio_journal"))
    #expect(reason.contains("Nothing was done."))
}

/// LOOK, AND WRITE IN HER OWN JOURNAL. That is the whole capability.
@Test func studioWanderAllowlist_admitsExactlyLookingAndHerOwnJournal() async throws {
    let tools = FakeWanderTools()
    let gate = allowlisted(tools)
    let admitted = ["screen", "read", "read_file", "file_excerpt", "mac_view",
                    "browser.open_url", "browser.read_text", "browser_read_text",
                    "browser.screenshot",
                    "studio_journal", "studio_recall", "studio_consult_read",
                    "recall_memory", "time_now"]
    for tool in admitted {
        _ = try await gate.dispatch(tool: tool, input: [:], surface: "studio_wander")
    }
    #expect(await tools.callLog().count == admitted.count)

    // studio_journal is the ONLY write admitted. Nothing else in the list
    // mutates anything she or User can see.
    let writes = StudioWanderToolAllowlist.admitted.filter {
        $0 == "studio_journal" || $0 == "studio_consult"
    }
    #expect(writes == ["studio_journal"])
}

/// A blocked tool is never ADVERTISED either. `runEphemeralToolTurn` derives
/// `turnActiveTools` from this walk, so an unadmitted tool is not put in front
/// of her as an option she has to decline — the schema simply is not there.
@Test func studioWanderAllowlist_doesNotAdvertiseWhatItWillRefuse() async throws {
    let gate = allowlisted(FakeWanderTools())
    let names = try await gate.listAvailableTools()
    #expect(names.isEmpty, "the fake body advertises nothing, so the filter yields nothing")

    // And the admission set itself carries none of the world-reaching families.
    for banned in ["act", "go", "commit_memory", "mail_send", "claude_message",
                   "workshop_submit", "write_file", "shell", "studio_canon_resolve"] {
        #expect(!StudioWanderToolAllowlist.admitted.contains(banned))
    }
}

/// A deny list fails open the day someone adds a tool. This pins the direction:
/// the set is closed, and it is small.
/// A deny list fails open the day someone adds a tool. This pins the direction:
/// the set is closed, and every organ the witness can credit is inside it — a
/// witness that could never observe its own organ would be theatre.
@Test func studioWanderAllowlist_isAClosedSetCoveringEveryOrgan() {
    for organ in StudioWanderToolWitness.artifactOrgans {
        #expect(
            StudioWanderToolAllowlist.admitted.contains(organ),
            "\(organ) is credited as an organ but cannot be dispatched"
        )
    }
    // The browser READ half only.
    #expect(StudioWanderToolAllowlist.admitted.contains("browser.read_links"))
    #expect(!StudioWanderToolAllowlist.admitted.contains("browser.chrome_click"))
    #expect(!StudioWanderToolAllowlist.admitted.contains("browser.navigate"))
    // The consult lane: read half in, write half out.
    #expect(StudioWanderToolAllowlist.admitted.contains("studio_consult_read"))
    #expect(!StudioWanderToolAllowlist.admitted.contains("studio_consult"))
}

// MARK: - Discovery must not advertise what dispatch will refuse

/// `tool_catalog` answers from the WHOLE app surface — `browser_tools`,
/// `organism_tools`, `notification_tools`, `tool_groups`, capability rows —
/// none of which went through the schema filter. Unscrubbed it hands her a menu
/// of tools this wrapper then refuses, which is "ignored is worse than absent"
/// in its most literal form.
@Test func studioWanderAllowlist_scrubsTheCatalogDownToWhatSheActuallyHas() async throws {
    let catalog = JSONValue.object([
        "status": .string("ok"),
        "available_tools": .array([
            .string("read"), .string("browser.navigate"), .string("mail_send"),
            .string("browser.read_text"), .string("act"),
        ]),
        "browser_tools": .array([
            .string("browser.open_url"), .string("browser.chrome_click"),
            .string("browser.navigate"),
        ]),
        "organism_tools": .array([.string("mac_nudge"), .string("mac_attention")]),
        "tools": .array([
            .object(["name": .string("read"), "description": .string("read a document")]),
            .object(["name": .string("go"), "description": .string("open an app")]),
        ]),
        "tool_groups": .object([
            "browser": .array([.string("browser.read_text"), .string("browser.chrome_type")]),
        ]),
    ])
    let gate = allowlisted(FakeWanderTools(results: ["tool_catalog": catalog]))
    let scrubbed = try await gate.dispatch(
        tool: "tool_catalog", input: [:], surface: "studio_wander"
    )
    guard case .object(let object) = scrubbed else {
        Issue.record("catalog must stay an object")
        return
    }
    func names(_ key: String) -> [String] {
        guard case .array(let rows)? = object[key] else { return [] }
        return rows.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }
    #expect(names("available_tools") == ["read", "browser.read_text"])
    #expect(names("browser_tools") == ["browser.open_url"])
    #expect(names("organism_tools").isEmpty)
    // Row objects naming a refused tool are dropped whole.
    guard case .array(let rows)? = object["tools"] else {
        Issue.record("tools rows must survive as an array")
        return
    }
    #expect(rows.count == 1)
    // Nested groups are scrubbed by the same structural rule.
    guard case .object(let groups)? = object["tool_groups"],
          case .array(let browserGroup)? = groups["browser"] else {
        Issue.record("tool_groups must survive")
        return
    }
    #expect(browserGroup.count == 1)
}

/// The tool itself stays available — she needs discovery. Only its ANSWER is
/// trimmed.
@Test func studioWanderAllowlist_keepsDiscoveryAvailable() async throws {
    let gate = allowlisted(FakeWanderTools())
    for tool in StudioWanderToolAllowlist.catalogTools {
        #expect(StudioWanderToolAllowlist.admitted.contains(tool))
        _ = try await gate.dispatch(tool: tool, input: [:], surface: "studio_wander")
    }
}

/// Prose is not a tool list. A scrub that blanked descriptions would make the
/// catalog useless in a different way.
@Test func studioWanderAllowlist_leavesProseAlone() {
    let prose = JSONValue.object([
        "notes": .array([.string("Read a document end to end."), .string("Nothing expires.")]),
    ])
    guard case .object(let out) = StudioWanderToolAllowlist.scrubCatalog(prose),
          case .array(let kept)? = out["notes"] else {
        Issue.record("prose array must survive")
        return
    }
    #expect(kept.count == 2)
}
